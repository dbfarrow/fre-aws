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
# Validate username
# ---------------------------------------------------------------------------
: "${DEV_USERNAME:?DEV_USERNAME must be set (use: ./admin.sh publish-installer <username>)}"
USERNAME="${DEV_USERNAME}"

# ---------------------------------------------------------------------------
# Verify the onboarding bundle directory exists
# ---------------------------------------------------------------------------
BUNDLE_DIR="${SCRIPT_DIR}/../config/onboarding/${USERNAME}"

if [[ ! -d "${BUNDLE_DIR}" ]]; then
  echo "ERROR: Onboarding bundle not found: config/onboarding/${USERNAME}/" >&2
  echo "       Run './admin.sh add-user' first to create the initial bundle." >&2
  exit 1
fi

for f in user.env aws-config; do
  if [[ ! -f "${BUNDLE_DIR}/${f}" ]]; then
    echo "ERROR: ${f} not found in config/onboarding/${USERNAME}/" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Look up user info from S3 registry
# ---------------------------------------------------------------------------
USERS_JSON=$(mktemp)
trap 'rm -f "${USERS_JSON}"' EXIT

users_s3_download "${USERS_JSON}"

if ! jq -e --arg u "${USERNAME}" '.[$u] != null' "${USERS_JSON}" >/dev/null 2>&1; then
  echo "ERROR: User '${USERNAME}' not found in S3 registry." >&2
  exit 1
fi

USER_EMAIL=$(jq -r --arg u "${USERNAME}" '.[$u].user_email' "${USERS_JSON}")
ROLE=$(jq -r       --arg u "${USERNAME}" '.[$u].role'       "${USERS_JSON}")

# Derive the AWS profile name from the onboarding user.env
AWS_PROFILE_FOR_DEV=$(grep '^AWS_PROFILE=' "${BUNDLE_DIR}/user.env" | cut -d= -f2)

# ---------------------------------------------------------------------------
# Generate new installer bundle and upload to S3
# ---------------------------------------------------------------------------
echo "=== Publish Installer: ${USERNAME} ==="
echo ""
echo "Building installer bundle..."

INSTALLER_URL=$(_create_installer_bundle "${USERNAME}" "${BUNDLE_DIR}")

echo "  Uploaded to s3://${TF_BACKEND_BUCKET}/${PROJECT_NAME}/installers/${USERNAME}/latest.zip"

# ---------------------------------------------------------------------------
# Send onboarding email (if SENDER_EMAIL is configured)
# ---------------------------------------------------------------------------
echo ""
if [[ -n "${SENDER_EMAIL:-}" ]]; then
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
    --user-email "${USER_EMAIL}" \
    --installer-url "${INSTALLER_URL}"
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
