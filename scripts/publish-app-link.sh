#!/usr/bin/env bash
# publish-app-link.sh — Generate a signed magic link for the browser app and
# optionally send it via email.
#
# Usage (via admin.sh):
#   ./admin.sh publish-app-link <username>
#
# Environment variable required:
#   DEV_USERNAME — the target username
#
# admin.env must have WEB_APP_URL set (from: terraform output -raw app_url).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
if [[ ! -f "${SCRIPT_DIR}/../config/admin.env" ]]; then
  echo "ERROR: config/admin.env not found." >&2
  exit 1
fi
source "${SCRIPT_DIR}/../config/admin.env"

if [[ ! -f "${SCRIPT_DIR}/../config/backend.env" ]]; then
  echo "ERROR: config/backend.env not found. Run './admin.sh bootstrap' first." >&2
  exit 1
fi
source "${SCRIPT_DIR}/../config/backend.env"

# shellcheck source=scripts/users-s3.sh
source "${SCRIPT_DIR}/users-s3.sh"

: "${PROJECT_NAME:?}" "${AWS_PROFILE:?}" "${AWS_REGION:?}" "${TF_BACKEND_BUCKET:?}" "${TF_BACKEND_REGION:?}"

# ---------------------------------------------------------------------------
# Validate username
# ---------------------------------------------------------------------------
: "${DEV_USERNAME:?DEV_USERNAME must be set (use: ./admin.sh publish-app-link <username>)}"
USERNAME="${DEV_USERNAME}"

# ---------------------------------------------------------------------------
# Validate WEB_APP_URL is configured
# ---------------------------------------------------------------------------
if [[ -z "${WEB_APP_URL:-}" ]]; then
  echo "ERROR: WEB_APP_URL is not set in config/admin.env." >&2
  echo "       After deploying with ENABLE_WEB_APP=true, run:" >&2
  echo "         terraform -chdir=terraform output -raw app_url" >&2
  echo "       Then add to config/admin.env:" >&2
  echo "         WEB_APP_URL=<value from above>" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Look up user email from S3 registry
# ---------------------------------------------------------------------------
USERS_JSON=$(mktemp)
trap 'rm -f "${USERS_JSON}"' EXIT

users_s3_download "${USERS_JSON}"

if ! jq -e --arg u "${USERNAME}" '.[$u] != null' "${USERS_JSON}" >/dev/null 2>&1; then
  echo "ERROR: User '${USERNAME}' not found in S3 registry." >&2
  exit 1
fi

USER_EMAIL=$(jq -r --arg u "${USERNAME}" '.[$u].user_email' "${USERS_JSON}")

# ---------------------------------------------------------------------------
# Fetch HMAC secret from SSM
# ---------------------------------------------------------------------------
HMAC_PARAM_PATH="/${PROJECT_NAME}/app/hmac-secret"

echo "Fetching HMAC secret..."
SECRET=$(aws ssm get-parameter \
  --name "${HMAC_PARAM_PATH}" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}")

if [[ -z "${SECRET}" ]]; then
  echo "ERROR: Could not read HMAC secret from SSM (${HMAC_PARAM_PATH})." >&2
  echo "       Ensure the web app is deployed: ENABLE_WEB_APP=true in admin.env, then ./admin.sh up" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Generate 72-hour magic link token
# Format: base64url("{username}:{expiry_unix}:{hmac_hex}")
# ---------------------------------------------------------------------------
EXPIRY=$(( $(date +%s) + 259200 ))
PAYLOAD="${USERNAME}:${EXPIRY}"
HMAC_HEX=$(printf '%s' "${PAYLOAD}" | openssl dgst -sha256 -hmac "${SECRET}" -hex | awk '{print $NF}')
TOKEN=$(printf '%s' "${PAYLOAD}:${HMAC_HEX}" | base64 | tr '+/' '-_' | tr -d '=' | tr -d '\n')

APP_LINK_URL="${WEB_APP_URL%/}?token=${TOKEN}"

# ---------------------------------------------------------------------------
# Send email (if SENDER_EMAIL is configured)
# ---------------------------------------------------------------------------
echo ""
echo "=== Publish App Link: ${USERNAME} ==="
echo ""

if [[ -n "${SENDER_EMAIL:-}" ]]; then
  echo "Sending app link email to ${USER_EMAIL}..."
  python3 "${SCRIPT_DIR}/send-onboarding-email.py" \
    --to "${USER_EMAIL}" \
    --from "${SENDER_EMAIL}" \
    --username "${USERNAME}" \
    --project "${PROJECT_NAME}" \
    --role "user" \
    --aws-profile "" \
    --aws-region "${AWS_REGION}" \
    --aws-cli-profile "${AWS_PROFILE}" \
    --ses-region "${AWS_REGION}" \
    --sso-start-url "" \
    --user-email "${USER_EMAIL}" \
    --app-url "${APP_LINK_URL}"
else
  echo "  SENDER_EMAIL not set — skipping email. Send the URL below manually."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Done ==="
echo ""
echo "  User:        ${USERNAME}"
echo "  Email:       ${USER_EMAIL}"
echo "  URL expires: 72 hours"
echo ""
echo "App link URL:"
echo ""
echo "  ${APP_LINK_URL}"
