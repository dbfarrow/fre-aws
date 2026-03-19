#!/usr/bin/env bash
# upload.sh — Upload a local file to ~/uploads/<project>/ on the EC2 instance.
# The file is piped over SSH stdin so no scp or separate key detection is needed.
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

: "${AWS_REGION:?}" "${AWS_PROFILE:?}" "${PROJECT_NAME:?}"

DEV_USERNAME="${DEV_USERNAME:-${MY_USERNAME:-}}"
if [[ -z "${DEV_USERNAME}" ]]; then
  echo "ERROR: DEV_USERNAME not set." >&2
  exit 1
fi

LOCAL_FILE="${UPLOAD_FILE:-}"
if [[ -z "${LOCAL_FILE}" || ! -f "${LOCAL_FILE}" ]]; then
  echo "ERROR: UPLOAD_FILE not set or file not found: ${LOCAL_FILE:-<unset>}" >&2
  exit 1
fi
FILENAME=$(basename "${LOCAL_FILE}")

CREDS=$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env-no-export 2>/dev/null) || {
  echo "ERROR: Could not export credentials for profile '${AWS_PROFILE}'." >&2
  echo "       If using SSO, run './user.sh sso-login' first." >&2
  exit 1
}
eval "$(echo "${CREDS}" | sed 's/^/export /')"

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

SSH_OPTS=(
  "-o" "StrictHostKeyChecking=no"
  "-o" "UserKnownHostsFile=/dev/null"
  "-o" "ProxyCommand=aws ssm start-session --target ${INSTANCE_ID} --document-name AWS-StartSSHSession --parameters portNumber=22 --region ${AWS_REGION}"
)

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
      --profile "${AWS_PROFILE}" --region "${AWS_REGION}" 2>/dev/null) || {
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

# Determine project: use UPLOAD_PROJECT env var or present a numbered menu
PROJECT="${UPLOAD_PROJECT:-}"
if [[ -z "${PROJECT}" ]]; then
  REPOS=$(ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" 'ls ~/repos/ 2>/dev/null || true')
  if [[ -z "${REPOS}" ]]; then
    read -r -p "Upload to project name: " PROJECT
  else
    echo ""
    echo "Select project to upload to:"
    REPO_OPTIONS=()
    RIDX=1
    while IFS= read -r repo; do
      printf "  %d) %s\n" "${RIDX}" "${repo}"
      REPO_OPTIONS+=("${repo}")
      (( RIDX++ ))
    done <<< "${REPOS}"
    echo ""
    read -r -p "Choose [1]: " PROJECT_CHOICE
    PROJECT_CHOICE="${PROJECT_CHOICE:-1}"
    if [[ "${PROJECT_CHOICE}" =~ ^[0-9]+$ ]] && (( PROJECT_CHOICE >= 1 && PROJECT_CHOICE <= ${#REPO_OPTIONS[@]} )); then
      PROJECT="${REPO_OPTIONS[$((PROJECT_CHOICE-1))]}"
    else
      read -r -p "Project name: " PROJECT
    fi
  fi
fi

if [[ -z "${PROJECT}" ]]; then
  echo "ERROR: No project specified." >&2
  exit 1
fi

echo "Uploading ${FILENAME} to ~/uploads/${PROJECT}/ on ${INSTANCE_ID}..."
ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "mkdir -p ~/uploads/${PROJECT}/ && cat > ~/uploads/${PROJECT}/${FILENAME}" \
  < "${LOCAL_FILE}"
echo "Done. File available at ~/uploads/${PROJECT}/${FILENAME}"
