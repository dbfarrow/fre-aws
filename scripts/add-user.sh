#!/usr/bin/env bash
# add-user.sh — Interactive wizard to add a user to the fre-aws environment.
# Prompts for username, SSH public key, git name, and git email.
# Validates input, checks for duplicates, then writes to the S3 user registry.
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

echo "=== Add User ==="
echo ""

# ---------------------------------------------------------------------------
# Prompt for username
# ---------------------------------------------------------------------------
while true; do
  read -r -p "Username (letters, numbers, dots, hyphens, underscores): " NEW_USERNAME
  if [[ -z "${NEW_USERNAME}" ]]; then
    echo "  Username cannot be empty." >&2
    continue
  fi
  if ! [[ "${NEW_USERNAME}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "  Invalid username. Use only letters, numbers, dots, hyphens, underscores." >&2
    continue
  fi
  break
done

# ---------------------------------------------------------------------------
# Prompt for SSH public key
# ---------------------------------------------------------------------------
while true; do
  read -r -p "SSH public key (paste full key, e.g. ssh-ed25519 AAAA...): " SSH_PUBLIC_KEY
  if [[ -z "${SSH_PUBLIC_KEY}" ]]; then
    echo "  SSH public key cannot be empty." >&2
    continue
  fi
  if ! [[ "${SSH_PUBLIC_KEY}" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|sk-ssh-ed25519@openssh\.com) ]]; then
    echo "  WARNING: Key does not start with a recognized SSH key type. Proceeding anyway."
  fi
  break
done

# ---------------------------------------------------------------------------
# Prompt for git name
# ---------------------------------------------------------------------------
while true; do
  read -r -p "Git user name (e.g. Alice Smith): " GIT_USER_NAME
  if [[ -z "${GIT_USER_NAME}" ]]; then
    echo "  Git user name cannot be empty." >&2
    continue
  fi
  break
done

# ---------------------------------------------------------------------------
# Prompt for git email
# ---------------------------------------------------------------------------
while true; do
  read -r -p "Git user email (e.g. alice@example.com): " GIT_USER_EMAIL
  if [[ -z "${GIT_USER_EMAIL}" ]]; then
    echo "  Git user email cannot be empty." >&2
    continue
  fi
  break
done

echo ""
echo "Adding user '${NEW_USERNAME}'..."

# ---------------------------------------------------------------------------
# Download current registry
# ---------------------------------------------------------------------------
USERS_JSON=$(mktemp)
trap 'rm -f "${USERS_JSON}"' EXIT

users_s3_download "${USERS_JSON}"

# ---------------------------------------------------------------------------
# Check for duplicate
# ---------------------------------------------------------------------------
if jq -e --arg user "${NEW_USERNAME}" '.[$user] != null' "${USERS_JSON}" >/dev/null 2>&1; then
  echo "ERROR: User '${NEW_USERNAME}' already exists in the registry." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Add entry and upload
# ---------------------------------------------------------------------------
jq \
  --arg user  "${NEW_USERNAME}" \
  --arg key   "${SSH_PUBLIC_KEY}" \
  --arg name  "${GIT_USER_NAME}" \
  --arg email "${GIT_USER_EMAIL}" \
  '.[$user] = {ssh_public_key: $key, git_user_name: $name, git_user_email: $email}' \
  "${USERS_JSON}" > "${USERS_JSON}.tmp"
mv "${USERS_JSON}.tmp" "${USERS_JSON}"

users_s3_upload "${USERS_JSON}"

echo "User '${NEW_USERNAME}' added to registry."
echo ""
echo "Next step: run './admin.sh up' to provision their EC2 instance."
