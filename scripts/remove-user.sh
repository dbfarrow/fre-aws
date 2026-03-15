#!/usr/bin/env bash
# remove-user.sh — Remove a user from the fre-aws environment.
# Requires DEV_USERNAME env var (set by admin.sh).
# On next './admin.sh up', the user's EC2 instance and EBS data will be destroyed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
if [[ ! -f "${SCRIPT_DIR}/../config/defaults.env" ]]; then
  echo "ERROR: config/defaults.env not found." >&2
  exit 1
fi
source "${SCRIPT_DIR}/../config/defaults.env"

if [[ ! -f "${SCRIPT_DIR}/../config/backend.env" ]]; then
  echo "ERROR: config/backend.env not found. Run './admin.sh bootstrap' first." >&2
  exit 1
fi
source "${SCRIPT_DIR}/../config/backend.env"

# shellcheck source=scripts/users-s3.sh
source "${SCRIPT_DIR}/users-s3.sh"

: "${PROJECT_NAME:?}" "${AWS_PROFILE:?}" "${TF_BACKEND_BUCKET:?}" "${TF_BACKEND_REGION:?}"
: "${DEV_USERNAME:?DEV_USERNAME must be set (pass via admin.sh remove-user <username>)}"

echo "=== Remove User: ${DEV_USERNAME} ==="
echo ""

# ---------------------------------------------------------------------------
# Download current registry
# ---------------------------------------------------------------------------
USERS_JSON=$(mktemp)
trap 'rm -f "${USERS_JSON}" "${USERS_JSON}.tmp"' EXIT

users_s3_download "${USERS_JSON}"

# ---------------------------------------------------------------------------
# Check user exists
# ---------------------------------------------------------------------------
if ! jq -e --arg user "${DEV_USERNAME}" '.[$user] != null' "${USERS_JSON}" >/dev/null 2>&1; then
  echo "ERROR: User '${DEV_USERNAME}' not found in registry." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Warn and confirm
# ---------------------------------------------------------------------------
echo "WARNING: Removing '${DEV_USERNAME}' from the registry."
echo "         On the next './admin.sh up', their EC2 instance and EBS volume"
echo "         will be PERMANENTLY DESTROYED. This cannot be undone."
echo ""
read -r -p "Type '${DEV_USERNAME}' to confirm removal: " CONFIRM

if [[ "${CONFIRM}" != "${DEV_USERNAME}" ]]; then
  echo "Confirmation did not match. Aborted."
  exit 0
fi

# ---------------------------------------------------------------------------
# Remove entry and upload
# ---------------------------------------------------------------------------
jq --arg user "${DEV_USERNAME}" 'del(.[$user])' "${USERS_JSON}" > "${USERS_JSON}.tmp"
mv "${USERS_JSON}.tmp" "${USERS_JSON}"

users_s3_upload "${USERS_JSON}"

echo ""
echo "User '${DEV_USERNAME}' removed from registry."
echo "Run './admin.sh up' to destroy their EC2 instance and EBS volume."
