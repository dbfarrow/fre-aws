#!/usr/bin/env bash
# update-user-key.sh — Replace a user's SSH public key in the S3 registry.
# Requires DEV_USERNAME env var (set by admin.sh).
# After running, execute './admin.sh up' to push the new key to their EC2 instance.
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
: "${DEV_USERNAME:?DEV_USERNAME must be set (pass via admin.sh update-user-key <username>)}"

echo "=== Update SSH Key: ${DEV_USERNAME} ==="
echo ""

# ---------------------------------------------------------------------------
# Download registry and verify user exists
# ---------------------------------------------------------------------------
USERS_JSON=$(mktemp)
trap 'rm -f "${USERS_JSON}" "${USERS_JSON}.tmp"' EXIT

users_s3_download "${USERS_JSON}"

if ! jq -e --arg user "${DEV_USERNAME}" '.[$user] != null' "${USERS_JSON}" >/dev/null 2>&1; then
  echo "ERROR: User '${DEV_USERNAME}' not found in registry." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Prompt for new public key
# ---------------------------------------------------------------------------
while true; do
  read -r -p "New SSH public key (paste full key, e.g. ssh-ed25519 AAAA...): " NEW_SSH_KEY
  if [[ -z "${NEW_SSH_KEY}" ]]; then
    echo "  SSH public key cannot be empty." >&2
    continue
  fi
  if ! [[ "${NEW_SSH_KEY}" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|sk-ssh-ed25519@openssh\.com) ]]; then
    echo "  WARNING: Key does not start with a recognized SSH key type. Proceeding anyway."
  fi
  break
done

# ---------------------------------------------------------------------------
# Update registry
# ---------------------------------------------------------------------------
jq \
  --arg user "${DEV_USERNAME}" \
  --arg key  "${NEW_SSH_KEY}" \
  '.[$user].ssh_public_key = $key' \
  "${USERS_JSON}" > "${USERS_JSON}.tmp"
mv "${USERS_JSON}.tmp" "${USERS_JSON}"

users_s3_upload "${USERS_JSON}"

echo ""
echo "SSH public key updated for '${DEV_USERNAME}'."
echo "Run './admin.sh up' to push the new key to their EC2 instance."
