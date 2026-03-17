#!/usr/bin/env bash
# publish-installer.sh — Re-generate the installer bundle for an existing user
# and upload a new latest.zip to S3. Prints the new pre-signed URL to stdout.
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

if [[ ! -f "${BUNDLE_DIR}/user.env" ]]; then
  echo "ERROR: user.env not found in config/onboarding/${USERNAME}/" >&2
  exit 1
fi

if [[ ! -f "${BUNDLE_DIR}/aws-config" ]]; then
  echo "ERROR: aws-config not found in config/onboarding/${USERNAME}/" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Generate new installer bundle and upload to S3
# ---------------------------------------------------------------------------
echo "=== Publish Installer: ${USERNAME} ==="
echo ""
echo "Building installer bundle..."

INSTALLER_URL=$(_create_installer_bundle "${USERNAME}" "${BUNDLE_DIR}")

echo ""
echo "=== Done ==="
echo ""
echo "  User:          ${USERNAME}"
echo "  S3 path:       s3://${TF_BACKEND_BUCKET}/${PROJECT_NAME}/installers/${USERNAME}/latest.zip"
echo "  URL expires:   72 hours"
echo ""
echo "Pre-signed URL (send to ${USERNAME}):"
echo ""
echo "${INSTALLER_URL}"
echo ""
echo "Installation command for user:"
echo "  curl -fsSL '<url>' -o /tmp/fre-setup.zip && unzip -d /tmp/fre-setup /tmp/fre-setup.zip && bash /tmp/fre-setup/install.sh"
