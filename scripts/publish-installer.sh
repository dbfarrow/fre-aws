#!/usr/bin/env bash
# publish-installer.sh — Re-generate the installer bundle for an existing user,
# upload a new latest.zip to S3, and re-send the onboarding email.
#
# Usage (via admin.sh):
#   ./admin.sh publish-installer <username>
#
# Environment variable required:
#   DEV_USERNAME — the target username
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

# shellcheck source=scripts/installer-bundle.sh
source "${SCRIPT_DIR}/installer-bundle.sh"
# shellcheck source=scripts/users-s3.sh
source "${SCRIPT_DIR}/users-s3.sh"

: "${PROJECT_NAME:?}" "${AWS_PROFILE:?}" "${TF_BACKEND_BUCKET:?}" "${TF_BACKEND_REGION:?}"

# ---------------------------------------------------------------------------
# Verify AWS credentials before doing anything
# ---------------------------------------------------------------------------
aws sts get-caller-identity --profile "${AWS_PROFILE}" --output json >/dev/null 2>&1 || {
  echo "ERROR: AWS credentials not valid for profile '${AWS_PROFILE}'." >&2
  echo "       Run 'aws sso login --profile ${AWS_PROFILE}' and retry." >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Validate username
# ---------------------------------------------------------------------------
: "${DEV_USERNAME:?DEV_USERNAME must be set (use: ./admin.sh publish-installer <username>)}"
USERNAME="${DEV_USERNAME}"

# ---------------------------------------------------------------------------
# Look up user info from S3 registry
# ---------------------------------------------------------------------------
USERS_JSON=$(mktemp)
USER_ENV_TMP=$(mktemp)
trap 'rm -f "${USERS_JSON}" "${USER_ENV_TMP}"' EXIT

users_s3_download "${USERS_JSON}"

if ! jq -e --arg u "${USERNAME}" '.[$u] != null' "${USERS_JSON}" >/dev/null 2>&1; then
  echo "ERROR: User '${USERNAME}' not found in S3 registry." >&2
  exit 1
fi

USER_EMAIL=$(jq -r --arg u "${USERNAME}" '.[$u].user_email' "${USERS_JSON}")
ROLE=$(jq -r       --arg u "${USERNAME}" '.[$u].role'       "${USERS_JSON}")

# Download user.env from S3 to extract the AWS profile name
aws s3 cp "s3://${TF_BACKEND_BUCKET}/${PROJECT_NAME}/users/${USERNAME}/user.env" \
  "${USER_ENV_TMP}" --region "${TF_BACKEND_REGION}" --profile "${AWS_PROFILE}" 2>/dev/null || {
  # S3 not found — check for local bundle dir (one-time migration path)
  LOCAL_BUNDLE_DIR="${SCRIPT_DIR}/../config/onboarding/${USERNAME}"
  if [[ -f "${LOCAL_BUNDLE_DIR}/user.env" ]]; then
    echo "  (Onboarding files for '${USERNAME}' not yet in S3 — will migrate during bundle creation.)"
    cp "${LOCAL_BUNDLE_DIR}/user.env" "${USER_ENV_TMP}"
  else
    echo "ERROR: Onboarding files for '${USERNAME}' not found in S3." >&2
    echo "       Run publish-installer from the original machine to migrate them." >&2
    exit 1
  fi
}
AWS_PROFILE_FOR_DEV=$(grep '^AWS_PROFILE=' "${USER_ENV_TMP}" | cut -d= -f2)

# ---------------------------------------------------------------------------
# Generate new installer bundle and upload to S3
# ---------------------------------------------------------------------------
echo "=== Publish Installer: ${USERNAME} ==="
echo ""
echo "Building installer bundle..."

# Pass local bundle dir as fallback for auto-migration (no-op if S3 already has files)
LOCAL_BUNDLE_DIR="${SCRIPT_DIR}/../config/onboarding/${USERNAME}"
INSTALLER_URL=$(_create_installer_bundle "${USERNAME}" "${LOCAL_BUNDLE_DIR}")

echo "  Uploaded to s3://${TF_BACKEND_BUCKET}/${PROJECT_NAME}/installers/${USERNAME}/latest.zip"

# ---------------------------------------------------------------------------
# Send onboarding email (or skip with --no-email / missing SENDER_EMAIL)
# ---------------------------------------------------------------------------
echo ""
if [[ "${NO_EMAIL_SEND:-}" == "true" ]]; then
  echo "  --no-email: skipping email."
elif [[ -n "${SENDER_EMAIL:-}" ]]; then
  # In SES sandbox mode, the recipient must be verified before we can send.
  SES_STATUS=$(aws sesv2 get-email-identity --email-identity "${USER_EMAIL}" \
    --region "${AWS_REGION}" --profile "${AWS_PROFILE}" \
    --query 'VerificationStatus' --output text 2>/dev/null || echo "NOT_FOUND")
  if [[ "${SES_STATUS}" != "SUCCESS" ]]; then
    if [[ "${SES_STATUS}" == "NOT_FOUND" ]]; then
      aws sesv2 create-email-identity --email-identity "${USER_EMAIL}" \
        --region "${AWS_REGION}" --profile "${AWS_PROFILE}" >/dev/null
    fi
    echo "NOTE: ${USER_EMAIL} is not yet verified with SES (sandbox mode)."
    echo "  A verification email has been sent to that address."
    echo "  Once they click the verification link, re-run:"
    echo "    ./admin.sh publish-installer ${USERNAME}"
    echo ""
    echo "Pre-signed URL (expires 72 hours):"
    echo ""
    echo "  ${INSTALLER_URL}"
    exit 0
  fi

  echo "Sending onboarding email to ${USER_EMAIL}..."
  python3 "${SCRIPT_DIR}/send-onboarding-email.py" \
    --to "${USER_EMAIL}" \
    --from "${SENDER_EMAIL}" \
    --username "${USERNAME}" \
    --project "${PROJECT_NAME}" \
    --role "${ROLE}" \
    --aws-profile "${AWS_PROFILE_FOR_DEV}" \
    --aws-region "${AWS_REGION}" \
    --aws-cli-profile "${AWS_PROFILE}" \
    --ses-region "${AWS_REGION}" \
    --sso-start-url "${SSO_START_URL:-}" \
    --sso-region "${SSO_REGION:-}" \
    --account-id "${TF_BACKEND_ACCOUNT_ID:-}" \
    --installer-url "${INSTALLER_URL}" \
    ${REPO_URL:+--repo-url "${REPO_URL}"} \
    ${LOGO_URL:+--logo-url "${LOGO_URL}"}
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
echo "Pre-signed URL:"
echo ""
echo "  ${INSTALLER_URL}"
