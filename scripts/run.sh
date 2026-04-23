#!/usr/bin/env bash
# run.sh — Phase 1 of ./user.sh run: download project from EC2 via rsync over SSM tunnel.
# Runs inside the tooling container. Docker commands run on the host after this exits.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Preserve any caller-provided AWS_PROFILE
_CALLER_PROFILE="${AWS_PROFILE:-}"

# Load config: user.env takes precedence; fall back to admin.env
if [[ -f "${SCRIPT_DIR}/../config/user.env" ]]; then
  source "${SCRIPT_DIR}/../config/user.env"
elif [[ -f "${SCRIPT_DIR}/../config/admin.env" ]]; then
  source "${SCRIPT_DIR}/../config/admin.env"
else
  echo "ERROR: No config found. Expected config/user.env or config/admin.env." >&2
  exit 1
fi
source "${SCRIPT_DIR}/../config/backend.env" 2>/dev/null || true

[[ -n "${_CALLER_PROFILE}" ]] && AWS_PROFILE="${_CALLER_PROFILE}"

: "${AWS_REGION:?}" "${PROJECT_NAME:?}"

DEV_USERNAME="${DEV_USERNAME:-${MY_USERNAME:-}}"
if [[ -z "${DEV_USERNAME}" ]]; then
  echo "ERROR: DEV_USERNAME not set." >&2
  exit 1
fi

: "${RUN_PROJECT:?}"

# ---------------------------------------------------------------------------
# Export AWS credentials
# ---------------------------------------------------------------------------
_PROFILE_ARGS=()
[[ -n "${AWS_PROFILE:-}" ]] && _PROFILE_ARGS=(--profile "${AWS_PROFILE}")
CREDS=$(aws configure export-credentials "${_PROFILE_ARGS[@]}" --format env-no-export 2>/dev/null) || {
  echo "ERROR: Could not export credentials${AWS_PROFILE:+ for profile '${AWS_PROFILE}'}." >&2
  echo "       If using SSO, run './user.sh sso-login' first." >&2
  exit 1
}
eval "$(echo "${CREDS}" | sed 's/^/export /')"

# ---------------------------------------------------------------------------
# Find running instance
# ---------------------------------------------------------------------------
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:Username,Values=${DEV_USERNAME}" \
    "Name=tag:ProjectName,Values=${PROJECT_NAME}" \
    "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --region "${AWS_REGION}" \
  --output text 2>/dev/null)

if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
  echo "ERROR: No running instance found for user '${DEV_USERNAME}' in project '${PROJECT_NAME}'." >&2
  echo "       Run './user.sh start' first." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# SSH options (SSM tunnel, no port 22)
# ---------------------------------------------------------------------------
SSH_OPTS=(
  "-o" "StrictHostKeyChecking=no"
  "-o" "UserKnownHostsFile=/dev/null"
  "-o" "LogLevel=ERROR"
  "-o" "ProxyCommand=aws ssm start-session --target ${INSTANCE_ID} --document-name AWS-StartSSHSession --parameters portNumber=22 --region ${AWS_REGION}"
)

# ---------------------------------------------------------------------------
# SSH agent / key setup
# ---------------------------------------------------------------------------
if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
  :
else
  SSH_KEY_FILE="${SSH_KEY_FILE:-/root/.ssh/fre-claude}"
  if [[ ! -f "${SSH_KEY_FILE}" ]]; then
    echo "ERROR: SSH key not found: ${SSH_KEY_FILE}" >&2
    exit 1
  fi
  eval "$(ssh-agent -s)" > /dev/null
  if [[ -n "${SSH_KEY_PASSPHRASE_SECRET:-}" ]]; then
    PASSPHRASE=$(aws secretsmanager get-secret-value \
      --secret-id "${SSH_KEY_PASSPHRASE_SECRET}" \
      --query 'SecretString' --output text \
      --region "${AWS_REGION}" 2>/dev/null) || {
      echo "ERROR: Could not retrieve SSH key passphrase from Secrets Manager." >&2
      echo "       Secret: ${SSH_KEY_PASSPHRASE_SECRET}" >&2
      exit 1
    }
    ASKPASS_SCRIPT=$(mktemp)
    chmod 700 "${ASKPASS_SCRIPT}"
    printf '#!/bin/sh\nprintf "%%s" "${_SSH_PASSPHRASE}"\n' > "${ASKPASS_SCRIPT}"
    trap 'rm -f "${ASKPASS_SCRIPT}"' EXIT
    _SSH_PASSPHRASE="${PASSPHRASE}" \
      SSH_ASKPASS="${ASKPASS_SCRIPT}" \
      SSH_ASKPASS_REQUIRE=force \
      ssh-add "${SSH_KEY_FILE}" >/dev/null 2>&1 || {
      echo "ERROR: Failed to add SSH key." >&2
      exit 1
    }
    unset PASSPHRASE _SSH_PASSPHRASE
  else
    ssh-add "${SSH_KEY_FILE}"
  fi
  SSH_OPTS+=("-i" "${SSH_KEY_FILE}")
fi

# ---------------------------------------------------------------------------
# Verify project exists on EC2
# ---------------------------------------------------------------------------
if ! ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" "test -d ~/repos/${RUN_PROJECT}" 2>/dev/null; then
  echo "ERROR: Project '${RUN_PROJECT}' not found on instance." >&2
  AVAILABLE=$(ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" 'ls ~/repos/ 2>/dev/null || true')
  if [[ -n "${AVAILABLE}" ]]; then
    echo "Available projects:" >&2
    while IFS= read -r repo; do
      echo "  ${repo}" >&2
    done <<< "${AVAILABLE}"
  fi
  exit 1
fi

# ---------------------------------------------------------------------------
# Download project from EC2 via rsync (exclude .git — no need for history)
# ---------------------------------------------------------------------------
mkdir -p /run-workspace/project/"${RUN_PROJECT}"

# Build SSH wrapper so rsync can use the SSM ProxyCommand (contains spaces)
SSH_WRAPPER=$(mktemp)
chmod 700 "${SSH_WRAPPER}"
{
  echo '#!/bin/sh'
  printf 'exec ssh'
  printf ' %q' "${SSH_OPTS[@]}"
  printf ' "$@"\n'
} > "${SSH_WRAPPER}"
trap 'rm -f "${SSH_WRAPPER}"' EXIT

echo "Downloading '${RUN_PROJECT}' from EC2 (excluding .git)..."
rsync -az --delete \
  --exclude '.git' \
  --exclude '.venv/' \
  --exclude 'node_modules/' \
  --exclude '.fre-dep-installed' \
  --progress \
  -e "${SSH_WRAPPER}" \
  developer@"${INSTANCE_ID}":~/repos/"${RUN_PROJECT}"/ \
  /run-workspace/project/"${RUN_PROJECT}"/
echo "Download complete."
