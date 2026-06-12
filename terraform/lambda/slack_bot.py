"""
slack_bot.py — Slack slash command bot for EC2 lifecycle management.

Entry points:
  handle_command(event, context)  — sync handler for Slack slash command (POST /slack)
  handle_notify(event, context)   — async worker: auth + command execution + Slack notification

Commands (via /fre <subcommand>):
  list                     — list all project EC2 instances with state
  start <project>          — start your instance and launch Claude in ~/repos/<project>
  start <user> <project>   — (admin) start a user's instance and launch Claude in ~/repos/<project>
  stop <user>              — stop a user's running EC2 instance

Auth: list and stop require role=="admin" in the S3 user registry.
      "start <project>" (self-start) requires only a registered slack_user_id.
      "start <user> <project>" requires admin.

Architecture:
  handle_command  — verify HMAC-SHA256 → parse body → invoke handle_notify async → return 200 ack
  handle_notify   — auth check (S3) → EC2 command → POST result to response_url

  The signing secret is loaded eagerly at module init so the Secrets Manager
  latency is absorbed by the Lambda Init phase rather than counting against
  Slack's 3-second response deadline.

Environment variables (handle_command):
  PROJECT_NAME           — used to filter EC2 instances by ProjectName tag
  SLACK_COMMAND_NAME     — slash command name shown in usage text (e.g. "fre")
  NOTIFIER_FUNCTION_NAME — Lambda function name to invoke for async work

Environment variables (handle_notify):
  PROJECT_NAME       — used to find EC2 instances
  TF_BACKEND_BUCKET  — S3 bucket containing the user registry
  TF_BACKEND_REGION  — AWS region of the S3 bucket (may differ from Lambda region)
"""

import base64
import hashlib
import hmac
import json
import os
import time
import urllib.parse
import urllib.request

import boto3
from botocore.exceptions import WaiterError

# ---------------------------------------------------------------------------
# Client caching — initialised once per Lambda container (cold start)
# ---------------------------------------------------------------------------
_ec2_client = None
_lambda_client = None
_s3_client = None
_ssm_client = None


def _ec2():
    global _ec2_client
    if _ec2_client is None:
        _ec2_client = boto3.client("ec2")
    return _ec2_client


def _lam():
    global _lambda_client
    if _lambda_client is None:
        _lambda_client = boto3.client("lambda")
    return _lambda_client


def _s3(region: str):
    """S3 client targeting the backend region (may differ from Lambda region)."""
    global _s3_client
    if _s3_client is None:
        _s3_client = boto3.client("s3", region_name=region)
    return _s3_client


def _ssm():
    global _ssm_client
    if _ssm_client is None:
        _ssm_client = boto3.client("ssm")
    return _ssm_client


# ---------------------------------------------------------------------------
# Signing secret — loaded eagerly at module init so the Secrets Manager
# latency is absorbed during the Lambda Init phase, before Slack's 3-second
# response clock starts.
# ---------------------------------------------------------------------------

def _load_signing_secret() -> bytes | None:
    """Read Slack signing secret from Secrets Manager at module load time."""
    try:
        project = os.environ.get("PROJECT_NAME", "")
        if not project:
            return None
        return boto3.client("secretsmanager").get_secret_value(
            SecretId=f"{project}/slack/signing-secret"
        )["SecretString"].encode()
    except Exception as exc:
        print(f"ERROR: module init: could not load signing secret: {exc}")
        return None


_signing_secret: bytes | None = _load_signing_secret()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _decode_body(event: dict) -> str:
    """Return the request body, base64-decoding it when API Gateway sets isBase64Encoded=True."""
    body = event.get("body", "") or ""
    if event.get("isBase64Encoded", False) and body:
        body = base64.b64decode(body).decode("utf-8")
    return body


def _ephemeral(text: str) -> dict:
    """Return an ephemeral Slack response (visible only to the caller)."""
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"response_type": "ephemeral", "text": text}),
    }


def _post_to_slack(response_url: str, text: str) -> None:
    """POST an ephemeral follow-up message to Slack via response_url."""
    payload = json.dumps({"response_type": "ephemeral", "text": text}).encode()
    req = urllib.request.Request(
        response_url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        resp.read()


def _verify_slack_signature(event: dict, secret: bytes) -> bool:
    """
    Verify Slack HMAC-SHA256 request signature.
    Returns True if valid and timestamp is within 5 minutes.
    """
    headers = event.get("headers", {}) or {}
    # API Gateway v2 lowercases header names
    timestamp = headers.get("x-slack-request-timestamp", "")
    sig_header = headers.get("x-slack-signature", "")
    raw_body = _decode_body(event)

    if not timestamp or not sig_header:
        return False

    # Reject requests older than 5 minutes (replay protection)
    try:
        if abs(time.time() - float(timestamp)) > 300:
            return False
    except (ValueError, TypeError):
        return False

    base = f"v0:{timestamp}:{raw_body}"
    expected = "v0=" + hmac.new(secret, base.encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, sig_header)


def _get_user_registry() -> dict:
    """Read users.json from S3 (not cached — always fresh)."""
    bucket = os.environ["TF_BACKEND_BUCKET"]
    region = os.environ["TF_BACKEND_REGION"]
    project = os.environ["PROJECT_NAME"]
    obj = _s3(region).get_object(Bucket=bucket, Key=f"{project}/users.json")
    return json.loads(obj["Body"].read().decode())


def _find_admin_by_slack_id(registry: dict, slack_user_id: str):
    """
    Return the username of the admin whose slack_user_id matches.
    Returns None if not found or not an admin.
    """
    for username, entry in registry.items():
        if entry.get("slack_user_id") == slack_user_id and entry.get("role") == "admin":
            return username
    return None


def _find_user_by_slack_id(registry: dict, slack_user_id: str):
    """Return the username of any registered user whose slack_user_id matches."""
    for username, entry in registry.items():
        if entry.get("slack_user_id") == slack_user_id:
            return username
    return None


def _describe_project_instances():
    """
    Return list of {username, instance_id, state} for all project instances.
    """
    project = os.environ["PROJECT_NAME"]
    resp = _ec2().describe_instances(
        Filters=[{"Name": "tag:ProjectName", "Values": [project]}]
    )
    results = []
    for reservation in resp.get("Reservations", []):
        for inst in reservation.get("Instances", []):
            username = next(
                (t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Username"),
                "unknown",
            )
            results.append({
                "username": username,
                "instance_id": inst["InstanceId"],
                "state": inst["State"]["Name"],
            })
    results.sort(key=lambda x: x["username"])
    return results


def _find_instance_for_user(username: str):
    """Return (instance_id, state, hibernation_configured) for the user, or (None, None, False)."""
    project = os.environ["PROJECT_NAME"]
    resp = _ec2().describe_instances(
        Filters=[
            {"Name": "tag:ProjectName", "Values": [project]},
            {"Name": "tag:Username", "Values": [username]},
        ]
    )
    for reservation in resp.get("Reservations", []):
        for inst in reservation.get("Instances", []):
            hibernation = inst.get("HibernationOptions", {}).get("Configured", False)
            return inst["InstanceId"], inst["State"]["Name"], hibernation
    return None, None, False


def _wait_for_ssm_ready(instance_id: str) -> bool:
    """Poll SSM until the agent reports Online, up to 2 minutes."""
    for _ in range(24):
        resp = _ssm().describe_instance_information(
            Filters=[{"Key": "InstanceIds", "Values": [instance_id]}]
        )
        info = resp.get("InstanceInformationList", [])
        if info and info[0].get("PingStatus") == "Online":
            return True
        time.sleep(5)
    return False


def _launch_remote_claude(instance_id: str, username: str, project: str) -> str:
    """
    Send an SSM RunShellScript command to start a Claude remote-control session
    in ~/repos/<project> on the instance. Skips launch if a session with the
    same name is already running. Returns "already_running" or "started".
    """
    session_name = f"{username}-remote"
    project_dir = f"/home/developer/repos/{project}"

    # Values are interpolated directly so no nested shell variable expansion is needed.
    # tmux new-session -d allocates a pty, which claude --remote-control requires.
    script = "\n".join([
        "#!/bin/bash",
        "set -e",
        f"if ! test -d '{project_dir}'; then",
        f"  echo 'error: {project_dir} does not exist'; exit 1",
        "fi",
        f"if runuser -l developer -c \"tmux has-session -t '{session_name}' 2>/dev/null\"; then",
        "  echo 'already_running'; exit 0",
        "fi",
        f"runuser -l developer -c \"tmux new-session -d -s '{session_name}' -c '{project_dir}' 'claude --remote-control {session_name}'\"",
        "echo 'started'",
    ])

    resp = _ssm().send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": [script]},
        TimeoutSeconds=30,
    )
    command_id = resp["Command"]["CommandId"]

    for _ in range(12):
        time.sleep(5)
        inv = _ssm().get_command_invocation(
            CommandId=command_id,
            InstanceId=instance_id,
        )
        status = inv["Status"]
        if status == "Success":
            return inv.get("StandardOutputContent", "").strip()
        if status in ("Failed", "TimedOut", "Cancelled"):
            err = (inv.get("StandardErrorContent") or inv.get("StandardOutputContent") or "").strip()
            raise RuntimeError(f"SSM command {status}: {err}")

    raise RuntimeError("SSM command did not complete within 60 seconds")


# ---------------------------------------------------------------------------
# Command formatting
# ---------------------------------------------------------------------------

_STATE_ICON = {
    "running": ":large_green_circle:",
    "stopped": ":red_circle:",
    "stopping": ":large_yellow_circle:",
    "pending": ":large_yellow_circle:",
    "shutting-down": ":large_yellow_circle:",
    "terminated": ":black_circle:",
}


def _cmd_list() -> str:
    instances = _describe_project_instances()
    if not instances:
        return "No instances found for this project."
    lines = []
    for inst in instances:
        icon = _STATE_ICON.get(inst["state"], ":white_circle:")
        lines.append(f"{icon} *{inst['username']}* — {inst['state']} (`{inst['instance_id']}`)")
    return "\n".join(lines)


def _usage() -> str:
    cmd = os.environ.get("SLACK_COMMAND_NAME", "fre")
    return (
        f"Usage:\n"
        f"  `/{cmd} list` — list all instances\n"
        f"  `/{cmd} start <project>` — start your instance and launch Claude in <project>\n"
        f"  `/{cmd} start <user> <project>` — (admin) start a user's instance and launch Claude in <project>\n"
        f"  `/{cmd} stop <user>` — stop a user's instance"
    )


# ---------------------------------------------------------------------------
# Lambda entry points
# ---------------------------------------------------------------------------

def handle_command(event, context):
    """
    Sync handler: verify Slack signature → parse → invoke notifier async → return 200 ack.

    All auth and command execution are delegated to handle_notify so this handler
    always returns within Slack's 3-second deadline. The signing secret is loaded at
    module init time so even cold starts complete well under 3 seconds.
    """
    if _signing_secret is None:
        print("ERROR: signing secret not loaded at module init")
        return {"statusCode": 500, "body": "configuration error"}

    if not _verify_slack_signature(event, _signing_secret):
        return {"statusCode": 401, "body": "invalid signature"}

    # Parse URL-encoded body from Slack
    raw_body = _decode_body(event)
    params = dict(urllib.parse.parse_qsl(raw_body))
    slack_user_id = params.get("user_id", "")
    text = params.get("text", "").strip()
    response_url = params.get("response_url", "")

    parts = text.split()
    subcommand = parts[0].lower() if parts else ""

    if subcommand not in ("list", "start", "stop"):
        return _ephemeral(_usage())

    # Parse "start <project>" or "start <user> <project>"
    start_user = None
    start_project = None
    if subcommand == "start":
        start_args = parts[1:]
        if len(start_args) == 1:
            start_project = start_args[0]
        elif len(start_args) == 2:
            start_user = start_args[0]
            start_project = start_args[1]
        else:
            return _ephemeral(_usage())

    # Parse "stop <user>"
    arg = parts[1] if subcommand == "stop" and len(parts) > 1 else ""
    if subcommand == "stop" and not arg:
        return _ephemeral(_usage())

    # Fire-and-forget: notifier does auth + EC2 work + posts result to Slack
    notifier = os.environ["NOTIFIER_FUNCTION_NAME"]
    payload = json.dumps({
        "slack_user_id": slack_user_id,
        "subcommand": subcommand,
        "arg": arg,
        "start_user": start_user,
        "start_project": start_project,
        "response_url": response_url,
    })
    _lam().invoke(
        FunctionName=notifier,
        InvocationType="Event",
        Payload=payload.encode(),
    )

    if subcommand == "start":
        if start_user:
            ack_text = f"Starting *{start_user}*'s instance and launching Claude in `{start_project}`... I'll let you know when it's ready."
        else:
            ack_text = f"Starting your instance and launching Claude in `{start_project}`... I'll let you know when it's ready."
    else:
        ack_text = {
            "list": "Checking instances...",
            "stop": f"Stopping *{arg}*'s instance... I'll let you know when it's stopped.",
        }[subcommand]

    return _ephemeral(ack_text)


def handle_notify(event, context):
    """
    Async worker: auth check → execute command → POST result to Slack response_url.
    Receives: {slack_user_id, subcommand, arg, start_user, start_project, response_url}
    """
    slack_user_id = event.get("slack_user_id", "")
    subcommand = event.get("subcommand", "")
    arg = event.get("arg", "")
    response_url = event.get("response_url", "")

    if not response_url:
        print(f"ERROR: missing response_url in event: {event}")
        return

    try:
        registry = _get_user_registry()
    except Exception as exc:
        print(f"ERROR: could not read user registry: {exc}")
        _post_to_slack(response_url, "Internal error — could not read user registry.")
        return

    caller = _find_admin_by_slack_id(registry, slack_user_id)

    try:
        if subcommand == "list":
            if not caller:
                _post_to_slack(response_url, "You are not authorised to use this command. Ask an admin to add your Slack user ID to the registry.")
                return
            _post_to_slack(response_url, _cmd_list())

        elif subcommand == "start":
            start_user = event.get("start_user")
            start_project = event.get("start_project", "")

            if start_user:
                if not caller:
                    _post_to_slack(response_url, "Only admins can start another user's instance.")
                    return
                target_username = start_user
            else:
                target_username = _find_user_by_slack_id(registry, slack_user_id)
                if not target_username:
                    _post_to_slack(
                        response_url,
                        "Your Slack user ID is not in the registry. Ask an admin to add you.",
                    )
                    return

            instance_id, state, _ = _find_instance_for_user(target_username)
            if not instance_id:
                _post_to_slack(response_url, f"No instance found for user *{target_username}*.")
                return
            if state == "stopping":
                _post_to_slack(response_url, f"*{target_username}*'s instance is currently stopping. Try again in a moment.")
                return
            if state in ("shutting-down", "terminated"):
                _post_to_slack(response_url, f"*{target_username}*'s instance is *{state}* — cannot start.")
                return

            if state == "stopped":
                _ec2().start_instances(InstanceIds=[instance_id])
                waiter = _ec2().get_waiter("instance_running")
                waiter.wait(InstanceIds=[instance_id], WaiterConfig={"MaxAttempts": 7, "Delay": 15})
            elif state == "pending":
                waiter = _ec2().get_waiter("instance_running")
                waiter.wait(InstanceIds=[instance_id], WaiterConfig={"MaxAttempts": 7, "Delay": 15})
            # state == "running": fall through to SSM

            if not _wait_for_ssm_ready(instance_id):
                _post_to_slack(
                    response_url,
                    f":warning: *{target_username}*'s instance is running but the SSM agent is not responding. Try again in a moment.",
                )
                return

            result = _launch_remote_claude(instance_id, target_username, start_project)
            if result == "already_running":
                _post_to_slack(
                    response_url,
                    f":large_green_circle: *{target_username}*'s instance is running. Claude remote session `{target_username}-remote` in `{start_project}` is already active.",
                )
            else:
                _post_to_slack(
                    response_url,
                    f":large_green_circle: *{target_username}*'s instance is running. Claude remote session `{target_username}-remote` is starting in `{start_project}` — check the Claude mobile app.",
                )

        elif subcommand == "stop":
            if not caller:
                _post_to_slack(response_url, "You are not authorised to use this command. Ask an admin to add your Slack user ID to the registry.")
                return
            instance_id, state, hibernation_configured = _find_instance_for_user(arg)
            if not instance_id:
                _post_to_slack(response_url, f"No instance found for user *{arg}*.")
                return
            if state != "running":
                _post_to_slack(
                    response_url,
                    f"*{arg}*'s instance is *{state}* — can only stop a running instance.",
                )
                return
            stop_kwargs = {"Hibernate": True} if hibernation_configured else {}
            _ec2().stop_instances(InstanceIds=[instance_id], **stop_kwargs)
            waiter = _ec2().get_waiter("instance_stopped")
            waiter.wait(
                InstanceIds=[instance_id],
                WaiterConfig={"MaxAttempts": 7, "Delay": 15},
            )
            verb = "hibernated" if hibernation_configured else "stopped"
            _post_to_slack(
                response_url,
                f":red_circle: *{arg}*'s instance has {verb} (`{instance_id}`).",
            )

        else:
            print(f"ERROR: unknown subcommand '{subcommand}'")
            _post_to_slack(response_url, f":warning: Unknown command: {subcommand}")

    except WaiterError as exc:
        print(f"ERROR: waiter timed out for {subcommand}: {exc}")
        _post_to_slack(
            response_url,
            f":warning: Timed out waiting for the instance to {subcommand}. Check the AWS console.",
        )
    except Exception as exc:
        print(f"ERROR: handle_notify failed for {subcommand}: {exc}")
        _post_to_slack(
            response_url,
            f":warning: Error while executing {subcommand}: {exc}",
        )
