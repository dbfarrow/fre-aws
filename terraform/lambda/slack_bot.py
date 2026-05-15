"""
slack_bot.py — Slack slash command bot for EC2 lifecycle management.

Entry points:
  handle_command(event, context)  — sync handler for Slack slash command (POST /slack)
  handle_notify(event, context)   — async notifier (waits for EC2 state change, POSTs result)

Commands (via /fre <subcommand>):
  list            — list all project EC2 instances with state
  start <user>    — start a user's stopped EC2 instance
  stop <user>     — stop a user's running EC2 instance

Auth: caller's Slack user_id is looked up in the S3 user registry (users.json).
      Only users with role=="admin" are authorised.

Environment variables (handle_command):
  PROJECT_NAME          — used to filter EC2 instances by ProjectName tag
  SLACK_COMMAND_NAME    — slash command name shown in usage text (e.g. "fre")
  TF_BACKEND_BUCKET     — S3 bucket containing the user registry
  TF_BACKEND_REGION     — AWS region of the S3 bucket (may differ from Lambda region)
  NOTIFIER_FUNCTION_NAME — Lambda function name to invoke for async notifications

Environment variables (handle_notify — shares PROJECT_NAME):
  PROJECT_NAME          — used to find the EC2 instance
"""

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
_sm_client = None
_s3_client = None
_signing_secret = None


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


def _sm():
    global _sm_client
    if _sm_client is None:
        _sm_client = boto3.client("secretsmanager")
    return _sm_client


def _s3(region: str):
    """S3 client targeting the backend region (may differ from Lambda region)."""
    global _s3_client
    if _s3_client is None:
        _s3_client = boto3.client("s3", region_name=region)
    return _s3_client


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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
    raw_body = event.get("body", "") or ""

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


def _get_signing_secret() -> bytes:
    """Read Slack signing secret from Secrets Manager (cached per container)."""
    global _signing_secret
    if _signing_secret is None:
        project = os.environ["PROJECT_NAME"]
        secret_id = f"{project}/slack/signing-secret"
        value = _sm().get_secret_value(SecretId=secret_id)["SecretString"]
        _signing_secret = value.encode()
    return _signing_secret


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
    """Return (instance_id, state) for the user, or (None, None)."""
    project = os.environ["PROJECT_NAME"]
    resp = _ec2().describe_instances(
        Filters=[
            {"Name": "tag:ProjectName", "Values": [project]},
            {"Name": "tag:Username", "Values": [username]},
        ]
    )
    for reservation in resp.get("Reservations", []):
        for inst in reservation.get("Instances", []):
            return inst["InstanceId"], inst["State"]["Name"]
    return None, None


# ---------------------------------------------------------------------------
# Command handlers
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


def _cmd_start(target_user: str, response_url: str) -> str:
    instance_id, state = _find_instance_for_user(target_user)
    if not instance_id:
        return f"No instance found for user *{target_user}*."
    if state != "stopped":
        return f"*{target_user}*'s instance is *{state}* — can only start a stopped instance."

    _ec2().start_instances(InstanceIds=[instance_id])

    # Fire-and-forget async notifier
    notifier = os.environ["NOTIFIER_FUNCTION_NAME"]
    payload = json.dumps({
        "action": "start",
        "username": target_user,
        "instance_id": instance_id,
        "response_url": response_url,
    })
    _lam().invoke(
        FunctionName=notifier,
        InvocationType="Event",
        Payload=payload.encode(),
    )
    return f"Starting *{target_user}*'s instance (`{instance_id}`)… I'll let you know when it's up."


def _cmd_stop(target_user: str, response_url: str) -> str:
    instance_id, state = _find_instance_for_user(target_user)
    if not instance_id:
        return f"No instance found for user *{target_user}*."
    if state != "running":
        return f"*{target_user}*'s instance is *{state}* — can only stop a running instance."

    _ec2().stop_instances(InstanceIds=[instance_id])

    notifier = os.environ["NOTIFIER_FUNCTION_NAME"]
    payload = json.dumps({
        "action": "stop",
        "username": target_user,
        "instance_id": instance_id,
        "response_url": response_url,
    })
    _lam().invoke(
        FunctionName=notifier,
        InvocationType="Event",
        Payload=payload.encode(),
    )
    return f"Stopping *{target_user}*'s instance (`{instance_id}`)… I'll let you know when it's stopped."


def _usage() -> str:
    cmd = os.environ.get("SLACK_COMMAND_NAME", "fre")
    return (
        f"Usage:\n"
        f"  `/{cmd} list` — list all instances\n"
        f"  `/{cmd} start <user>` — start a user's instance\n"
        f"  `/{cmd} stop <user>` — stop a user's instance"
    )


# ---------------------------------------------------------------------------
# Lambda entry points
# ---------------------------------------------------------------------------

def handle_command(event, context):
    """
    Sync handler: verify Slack signature → auth → dispatch → return ephemeral reply.
    Must return within 3 seconds (Slack requirement).
    """
    try:
        signing_secret = _get_signing_secret()
    except Exception as exc:
        print(f"ERROR: could not fetch signing secret: {exc}")
        return {"statusCode": 500, "body": "configuration error"}

    if not _verify_slack_signature(event, signing_secret):
        return {"statusCode": 401, "body": "invalid signature"}

    # Parse URL-encoded body from Slack
    raw_body = event.get("body", "") or ""
    params = dict(urllib.parse.parse_qsl(raw_body))
    slack_user_id = params.get("user_id", "")
    text = params.get("text", "").strip()
    response_url = params.get("response_url", "")

    # Auth check
    try:
        registry = _get_user_registry()
    except Exception as exc:
        print(f"ERROR: could not read user registry: {exc}")
        return _ephemeral("Internal error — could not read user registry.")

    caller = _find_admin_by_slack_id(registry, slack_user_id)
    if not caller:
        return _ephemeral("You are not authorised to use this command. Ask an admin to add your Slack user ID to the registry.")

    # Dispatch
    parts = text.split(None, 1)
    subcommand = parts[0].lower() if parts else ""
    arg = parts[1].strip() if len(parts) > 1 else ""

    try:
        if subcommand == "list":
            msg = _cmd_list()
        elif subcommand == "start":
            if not arg:
                return _ephemeral(_usage())
            msg = _cmd_start(arg, response_url)
        elif subcommand == "stop":
            if not arg:
                return _ephemeral(_usage())
            msg = _cmd_stop(arg, response_url)
        else:
            return _ephemeral(_usage())
    except Exception as exc:
        print(f"ERROR dispatching '{subcommand}': {exc}")
        return _ephemeral(f"Error: {exc}")

    return _ephemeral(msg)


def handle_notify(event, context):
    """
    Async notifier: waits for EC2 waiter, then POSTs result to Slack response_url.
    Receives: {action, username, instance_id, response_url}
    """
    action = event.get("action", "")
    username = event.get("username", "unknown")
    instance_id = event.get("instance_id", "")
    response_url = event.get("response_url", "")

    if not instance_id or not response_url:
        print(f"ERROR: missing instance_id or response_url in event: {event}")
        return

    try:
        if action == "start":
            waiter = _ec2().get_waiter("instance_running")
            waiter.wait(
                InstanceIds=[instance_id],
                WaiterConfig={"MaxAttempts": 7, "Delay": 15},
            )
            _post_to_slack(response_url, f":large_green_circle: *{username}*'s instance is running (`{instance_id}`).")
        elif action == "stop":
            waiter = _ec2().get_waiter("instance_stopped")
            waiter.wait(
                InstanceIds=[instance_id],
                WaiterConfig={"MaxAttempts": 7, "Delay": 15},
            )
            _post_to_slack(response_url, f":red_circle: *{username}*'s instance has stopped (`{instance_id}`).")
        else:
            print(f"ERROR: unknown action '{action}'")
    except WaiterError as exc:
        print(f"ERROR: waiter timed out for {action}/{instance_id}: {exc}")
        _post_to_slack(
            response_url,
            f":warning: Timed out waiting for *{username}*'s instance to {action}. Check the AWS console.",
        )
    except Exception as exc:
        print(f"ERROR: handle_notify failed: {exc}")
        _post_to_slack(
            response_url,
            f":warning: Error while {action}ing *{username}*'s instance: {exc}",
        )
