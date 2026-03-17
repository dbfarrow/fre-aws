#!/usr/bin/env bash
# update-user-key.sh — Replace a user's SSH key.
# Mode 1 (default): auto-generates a new ed25519 key pair, updates the S3
#   registry, stores the passphrase in Secrets Manager, pushes the key to
#   the running instance via SSM, and creates a new installer bundle.
# Mode 2: accepts a provided public key, updates the registry and instance.
#
# Requires DEV_USERNAME env var (set by admin.sh).
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
# shellcheck source=scripts/installer-bundle.sh
source "${SCRIPT_DIR}/installer-bundle.sh"

: "${PROJECT_NAME:?}" "${AWS_PROFILE:?}" "${AWS_REGION:?}"
: "${TF_BACKEND_BUCKET:?}" "${TF_BACKEND_REGION:?}"
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
# Key source
# ---------------------------------------------------------------------------
echo "SSH key update mode:"
echo "  1) Auto-generate a new key pair  (passphrase stored in Secrets Manager)  [default]"
echo "  2) Provide a new public key       (user manages their own private key)"
read -r -p "Select [1]: " KEY_MODE
KEY_MODE="${KEY_MODE:-1}"
echo ""

SSH_PRIVATE_KEY_FILE=""
SSH_KEY_PASSPHRASE=""

case "${KEY_MODE}" in
  2|own|provide)
    while true; do
      read -r -p "New SSH public key (paste full key, e.g. ssh-ed25519 AAAA...): " NEW_SSH_KEY
      if [[ -z "${NEW_SSH_KEY}" ]]; then
        echo "  SSH public key cannot be empty." >&2; continue
      fi
      if ! [[ "${NEW_SSH_KEY}" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|sk-ssh-ed25519@openssh\.com) ]]; then
        echo "  WARNING: Key does not start with a recognized SSH key type. Proceeding anyway."
      fi
      break
    done
    ;;
  *)
    # Auto-generate
    PRIV_KEY_PATH="/tmp/${DEV_USERNAME}-fre-claude-new"
    rm -f "${PRIV_KEY_PATH}" "${PRIV_KEY_PATH}.pub"
    SSH_KEY_PASSPHRASE=$(openssl rand -base64 24)
    ssh-keygen -t ed25519 -N "${SSH_KEY_PASSPHRASE}" \
      -f "${PRIV_KEY_PATH}" \
      -C "${DEV_USERNAME}@${PROJECT_NAME}" >/dev/null
    NEW_SSH_KEY=$(cat "${PRIV_KEY_PATH}.pub")
    SSH_PRIVATE_KEY_FILE="${PRIV_KEY_PATH}"
    echo "Generated new ed25519 key pair."
    ;;
esac

# ---------------------------------------------------------------------------
# Update S3 registry
# ---------------------------------------------------------------------------
jq \
  --arg user "${DEV_USERNAME}" \
  --arg key  "${NEW_SSH_KEY}" \
  '.[$user].ssh_public_key = $key' \
  "${USERS_JSON}" > "${USERS_JSON}.tmp"
mv "${USERS_JSON}.tmp" "${USERS_JSON}"

users_s3_upload "${USERS_JSON}"
echo "Registry updated with new public key."

# ---------------------------------------------------------------------------
# Update Secrets Manager (auto-generate mode only)
# ---------------------------------------------------------------------------
if [[ -n "${SSH_PRIVATE_KEY_FILE}" && -n "${SSH_KEY_PASSPHRASE}" ]]; then
  echo ""
  echo "Updating SSH key passphrase in Secrets Manager..."
  SECRET_ID="${PROJECT_NAME}/${DEV_USERNAME}/ssh-key-passphrase"
  if aws --region "${AWS_REGION}" --profile "${AWS_PROFILE}" \
      secretsmanager describe-secret --secret-id "${SECRET_ID}" >/dev/null 2>&1; then
    aws --region "${AWS_REGION}" --profile "${AWS_PROFILE}" \
      secretsmanager put-secret-value \
      --secret-id "${SECRET_ID}" \
      --secret-string "${SSH_KEY_PASSPHRASE}" >/dev/null
    echo "  Updated secret: ${SECRET_ID}"
  else
    aws --region "${AWS_REGION}" --profile "${AWS_PROFILE}" \
      secretsmanager create-secret \
      --name "${SECRET_ID}" \
      --description "SSH key passphrase for ${DEV_USERNAME} (${PROJECT_NAME})" \
      --secret-string "${SSH_KEY_PASSPHRASE}" >/dev/null
    echo "  Created secret: ${SECRET_ID}"
  fi
  unset SSH_KEY_PASSPHRASE
fi

# ---------------------------------------------------------------------------
# Push new public key to running instance via SSM (no SSH needed)
# ---------------------------------------------------------------------------
echo ""
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:Username,Values=${DEV_USERNAME}" \
    "Name=tag:ProjectName,Values=${PROJECT_NAME}" \
    "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --output text 2>/dev/null || echo "")

if [[ -n "${INSTANCE_ID}" && "${INSTANCE_ID}" != "None" ]]; then
  echo "Pushing new public key to instance ${INSTANCE_ID} via SSM..."

  # Build the SSM parameters safely — jq handles quoting of the key value
  SSM_PARAMS=$(jq -n --arg key "${NEW_SSH_KEY}" '{
    "commands": [
      "echo \($key) > /home/developer/.ssh/authorized_keys",
      "chmod 600 /home/developer/.ssh/authorized_keys",
      "chown developer:developer /home/developer/.ssh/authorized_keys"
    ]
  }')

  CMD_ID=$(aws ssm send-command \
    --document-name "AWS-RunShellScript" \
    --targets "Key=instanceIds,Values=${INSTANCE_ID}" \
    --parameters "${SSM_PARAMS}" \
    --region "${AWS_REGION}" \
    --profile "${AWS_PROFILE}" \
    --comment "fre-aws: update SSH key for ${DEV_USERNAME}" \
    --query 'Command.CommandId' \
    --output text 2>/dev/null || echo "")

  if [[ -n "${CMD_ID}" && "${CMD_ID}" != "None" ]]; then
    echo "  Command sent (${CMD_ID}). Waiting..."
    STATUS="Pending"
    for _ in $(seq 1 20); do
      sleep 2
      STATUS=$(aws ssm get-command-invocation \
        --command-id "${CMD_ID}" \
        --instance-id "${INSTANCE_ID}" \
        --region "${AWS_REGION}" \
        --profile "${AWS_PROFILE}" \
        --query 'Status' --output text 2>/dev/null || echo "Unknown")
      [[ "${STATUS}" =~ ^(Success|Failed|Cancelled|TimedOut) ]] && break
    done
    if [[ "${STATUS}" == "Success" ]]; then
      echo "  New public key installed on instance."
    else
      echo "  WARNING: SSM command status: ${STATUS}." >&2
      echo "           The instance may need './admin.sh up' to pick up the new key." >&2
    fi
  else
    echo "  WARNING: Could not send SSM command." >&2
    echo "           Run './admin.sh up' to apply the key change on next instance recreate." >&2
  fi
else
  echo "No running instance found for ${DEV_USERNAME}."
  echo "  Run './admin.sh up' to provision a new instance with the updated key."
fi

# ---------------------------------------------------------------------------
# Regenerate installer bundle (auto-generate mode only)
# ---------------------------------------------------------------------------
if [[ -n "${SSH_PRIVATE_KEY_FILE}" ]]; then
  BUNDLE_DIR="${SCRIPT_DIR}/../config/onboarding/${DEV_USERNAME}"
  if [[ -d "${BUNDLE_DIR}" && -f "${BUNDLE_DIR}/user.env" ]]; then
    echo ""
    echo "Regenerating installer bundle..."
    cp "${SSH_PRIVATE_KEY_FILE}" "${BUNDLE_DIR}/fre-claude"
    chmod 600 "${BUNDLE_DIR}/fre-claude"
    INSTALLER_URL=$(_create_installer_bundle "${DEV_USERNAME}" "${BUNDLE_DIR}")
    echo "  Uploaded to s3://${TF_BACKEND_BUCKET}/${PROJECT_NAME}/installers/${DEV_USERNAME}/latest.zip"
    echo ""
    echo "Send this installer URL to ${DEV_USERNAME} (expires in 72 hours):"
    echo "  ${INSTALLER_URL}"
  else
    echo ""
    echo "  NOTE: Onboarding bundle dir not found at ${BUNDLE_DIR}/."
    echo "        New private key: ${SSH_PRIVATE_KEY_FILE}"
    echo "        Run './admin.sh add-user' for a full re-onboard, or copy the key manually."
  fi
fi

echo ""
echo "=== SSH key update complete ==="
