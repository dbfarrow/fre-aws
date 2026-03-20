"""
app_api.py — Browser app Lambda handler.

Endpoints:
  POST /login     — verify magic link token, issue 30-day JWT
  GET  /status    — EC2 + SSM state for the authenticated user
  POST /start     — start the user's EC2 instance
  POST /stop      — stop the user's EC2 instance
  GET  /terminal  — return a federated AWS console URL for SSM Session Manager
  OPTIONS *       — CORS preflight

Environment variables:
  PROJECT_NAME       — used to filter EC2 instances by tag
  HMAC_PARAM_PATH    — SSM parameter path for the HMAC signing secret
  FEDERATION_ROLE_ARN — ARN of the IAM role to assume for console federation
  AWS_REGION_NAME    — AWS region (can't use reserved AWS_REGION)
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

# ---------------------------------------------------------------------------
# Client caching — initialised once per Lambda container (cold start)
# ---------------------------------------------------------------------------
_region = None
_ssm_param_client = None
_ec2_client = None
_ssm_mgr_client = None
_sts_client = None
_hmac_secret = None  # cached after first SSM fetch


def _init_clients():
    global _region, _ssm_param_client, _ec2_client, _ssm_mgr_client, _sts_client
    if _ssm_param_client is not None:
        return
    _region = os.environ["AWS_REGION_NAME"]
    _ssm_param_client = boto3.client("ssm", region_name=_region)
    _ec2_client = boto3.client("ec2", region_name=_region)
    _ssm_mgr_client = boto3.client("ssm", region_name=_region)
    _sts_client = boto3.client("sts", region_name=_region)


def _get_secret() -> bytes:
    global _hmac_secret
    if _hmac_secret is None:
        _init_clients()
        _hmac_secret = _ssm_param_client.get_parameter(
            Name=os.environ["HMAC_PARAM_PATH"], WithDecryption=True
        )["Parameter"]["Value"].encode()
    return _hmac_secret


# ---------------------------------------------------------------------------
# Token helpers
# ---------------------------------------------------------------------------

def _b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _b64url_decode(s: str) -> bytes:
    # Restore padding
    s += "=" * (4 - len(s) % 4)
    return base64.urlsafe_b64decode(s)


def _make_jwt(username: str, secret: bytes) -> str:
    now = int(time.time())
    exp = now + 30 * 24 * 3600  # 30 days
    header = _b64url_encode(
        json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode()
    )
    payload = _b64url_encode(
        json.dumps(
            {"sub": username, "exp": exp, "iat": now}, separators=(",", ":")
        ).encode()
    )
    signing_input = f"{header}.{payload}"
    sig = hmac.new(secret, signing_input.encode(), hashlib.sha256).digest()
    return f"{signing_input}.{_b64url_encode(sig)}"


def _verify_jwt(token: str, secret: bytes):
    """Returns username if JWT is valid and not expired; None otherwise."""
    try:
        parts = token.split(".")
        if len(parts) != 3:
            return None
        header, payload_b64, sig_b64 = parts
        signing_input = f"{header}.{payload_b64}"
        expected_sig = hmac.new(secret, signing_input.encode(), hashlib.sha256).digest()
        provided_sig = _b64url_decode(sig_b64)
        if not hmac.compare_digest(expected_sig, provided_sig):
            return None
        payload_data = json.loads(_b64url_decode(payload_b64).decode())
        if payload_data.get("exp", 0) < time.time():
            return None
        return payload_data.get("sub")
    except Exception:
        return None


def _verify_magic_token(token: str, secret: bytes):
    """
    Verify a magic link token (format: base64url("{username}:{expiry}:{hmac_hex}")).
    Returns username if valid; None otherwise.
    """
    try:
        decoded = _b64url_decode(token).decode()
        # Split on last two colons to handle usernames that might not contain colons
        parts = decoded.split(":", 2)
        if len(parts) != 3:
            return None
        username, expiry_str, token_hmac = parts
        if int(expiry_str) < int(time.time()):
            return None
        payload = f"{username}:{expiry_str}"
        expected_hmac = hmac.new(secret, payload.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected_hmac, token_hmac):
            return None
        return username
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Request helpers
# ---------------------------------------------------------------------------

def _get_username_from_jwt(event: dict, secret: bytes):
    """Extract and verify JWT from Authorization header. Returns username or None."""
    headers = event.get("headers", {}) or {}
    auth = headers.get("authorization", "") or headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return None
    return _verify_jwt(auth[7:], secret)


def _cors_headers() -> dict:
    return {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "Content-Type,Authorization",
        "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
    }


def _response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json", **_cors_headers()},
        "body": json.dumps(body),
    }


# ---------------------------------------------------------------------------
# EC2 / SSM helpers
# ---------------------------------------------------------------------------

def _find_instance(username: str):
    """
    Returns (instance_id, state, launch_time_iso) for the user's EC2 instance.
    Returns (None, None, None) if no instance is found.
    """
    _init_clients()
    project = os.environ["PROJECT_NAME"]
    resp = _ec2_client.describe_instances(
        Filters=[
            {"Name": "tag:ProjectName", "Values": [project]},
            {"Name": "tag:Username", "Values": [username]},
        ]
    )
    for reservation in resp.get("Reservations", []):
        for instance in reservation.get("Instances", []):
            state = instance["State"]["Name"]
            launch_time = instance.get("LaunchTime")
            launch_time_iso = launch_time.isoformat() if launch_time else None
            return instance["InstanceId"], state, launch_time_iso
    return None, None, None


def _check_ssm_ready(instance_id: str) -> bool:
    """Returns True if the SSM agent is registered and online for the instance."""
    resp = _ssm_mgr_client.describe_instance_information(
        Filters=[{"Key": "InstanceIds", "Values": [instance_id]}]
    )
    return len(resp.get("InstanceInformationList", [])) > 0


# ---------------------------------------------------------------------------
# Endpoint handlers
# ---------------------------------------------------------------------------

def handle_login(event: dict) -> dict:
    """POST /login — verify magic link token, issue 30-day JWT."""
    try:
        body = json.loads(event.get("body") or "{}")
        token = body.get("token", "")
        if not token:
            return _response(400, {"error": "token required"})
        secret = _get_secret()
        username = _verify_magic_token(token, secret)
        if not username:
            return _response(401, {"error": "invalid or expired token"})
        jwt = _make_jwt(username, secret)
        return _response(200, {"jwt": jwt, "username": username})
    except Exception as exc:
        print(f"ERROR /login: {exc}")
        return _response(500, {"error": "internal error"})


def handle_status(event: dict) -> dict:
    """GET /status — EC2 + SSM state for the authenticated user."""
    secret = _get_secret()
    username = _get_username_from_jwt(event, secret)
    if not username:
        return _response(401, {"error": "unauthorized"})
    try:
        instance_id, state, launch_time = _find_instance(username)
        if not instance_id:
            return _response(200, {"ec2_state": "not_found", "ssm_ready": False, "uptime": None})
        ssm_ready = _check_ssm_ready(instance_id) if state == "running" else False
        return _response(200, {
            "ec2_state": state,
            "ssm_ready": ssm_ready,
            "uptime": launch_time,
            "instance_id": instance_id,
        })
    except Exception as exc:
        print(f"ERROR /status: {exc}")
        return _response(500, {"error": "internal error"})


def handle_start(event: dict) -> dict:
    """POST /start — start the user's EC2 instance."""
    secret = _get_secret()
    username = _get_username_from_jwt(event, secret)
    if not username:
        return _response(401, {"error": "unauthorized"})
    try:
        instance_id, _state, _lt = _find_instance(username)
        if not instance_id:
            return _response(404, {"error": "instance not found"})
        _ec2_client.start_instances(InstanceIds=[instance_id])
        return _response(200, {"ok": True})
    except Exception as exc:
        print(f"ERROR /start: {exc}")
        return _response(500, {"error": "internal error"})


def handle_stop(event: dict) -> dict:
    """POST /stop — stop the user's EC2 instance."""
    secret = _get_secret()
    username = _get_username_from_jwt(event, secret)
    if not username:
        return _response(401, {"error": "unauthorized"})
    try:
        instance_id, _state, _lt = _find_instance(username)
        if not instance_id:
            return _response(404, {"error": "instance not found"})
        _ec2_client.stop_instances(InstanceIds=[instance_id])
        return _response(200, {"ok": True})
    except Exception as exc:
        print(f"ERROR /stop: {exc}")
        return _response(500, {"error": "internal error"})


def handle_terminal(event: dict) -> dict:
    """
    GET /terminal — assume the federation role (with Username session tag) and
    return a one-time AWS console sign-in URL pointing at SSM Session Manager.
    """
    secret = _get_secret()
    username = _get_username_from_jwt(event, secret)
    if not username:
        return _response(401, {"error": "unauthorized"})
    try:
        instance_id, state, _lt = _find_instance(username)
        if not instance_id:
            return _response(404, {"error": "instance not found"})
        if state != "running":
            return _response(409, {"error": "instance is not running"})
        if not _check_ssm_ready(instance_id):
            return _response(409, {"error": "SSM agent not ready"})

        region = os.environ["AWS_REGION_NAME"]

        # Scope-down policy restricts the assumed session to this specific instance.
        # This avoids sts:TagSession (blocked in this account) while providing the
        # same per-user isolation that ABAC session tags would give.
        session_policy = json.dumps({
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Action": "ssm:StartSession",
                    "Resource": [
                        f"arn:aws:ec2:{region}:*:instance/{instance_id}",
                        f"arn:aws:ssm:{region}:*:document/SSM-SessionManagerRunShell",
                    ],
                }
            ],
        })

        assumed = _sts_client.assume_role(
            RoleArn=os.environ["FEDERATION_ROLE_ARN"],
            RoleSessionName=username[:64],
            DurationSeconds=3600,
            Policy=session_policy,
        )
        creds = assumed["Credentials"]
        session_json = json.dumps({
            "sessionId": creds["AccessKeyId"],
            "sessionKey": creds["SecretAccessKey"],
            "sessionToken": creds["SessionToken"],
        })

        # Exchange temporary credentials for a federation sign-in token
        federation_endpoint = "https://signin.aws.amazon.com/federation"
        get_token_url = (
            f"{federation_endpoint}?Action=getSigninToken"
            f"&Session={urllib.parse.quote(session_json)}"
        )
        with urllib.request.urlopen(get_token_url) as resp:
            token_data = json.loads(resp.read().decode())
        signin_token = token_data["SigninToken"]

        # SSM Session Manager console URL for the user's instance
        ssm_console_url = (
            f"https://console.aws.amazon.com/systems-manager/session-manager"
            f"/{instance_id}?region={region}"
        )

        # Final sign-in URL — redirects to SSM console after federated login
        login_url = (
            f"{federation_endpoint}?Action=login"
            f"&Issuer="
            f"&Destination={urllib.parse.quote(ssm_console_url)}"
            f"&SigninToken={signin_token}"
        )
        return _response(200, {"url": login_url})
    except Exception as exc:
        print(f"ERROR /terminal: {exc}")
        return _response(500, {"error": "internal error"})


# ---------------------------------------------------------------------------
# Lambda function URL entry point
# ---------------------------------------------------------------------------

def handler(event, context):
    path = event.get("rawPath", "/")
    method = (
        event.get("requestContext", {})
        .get("http", {})
        .get("method", "GET")
        .upper()
    )

    # CORS preflight
    if method == "OPTIONS":
        return {"statusCode": 204, "headers": _cors_headers(), "body": ""}

    if path == "/login" and method == "POST":
        return handle_login(event)
    if path == "/status" and method == "GET":
        return handle_status(event)
    if path == "/start" and method == "POST":
        return handle_start(event)
    if path == "/stop" and method == "POST":
        return handle_stop(event)
    if path == "/terminal" and method == "GET":
        return handle_terminal(event)

    return _response(404, {"error": "not found"})
