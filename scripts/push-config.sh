#!/usr/bin/env bash
# push-config.sh — Push personal dotfiles from the host to the user's EC2 instance.
#
# Dotfiles are mounted into /host-configs/ by run.sh (push-config command only).
# Files present in /host-configs/ are pushed; missing files are skipped silently.
#
# Dotfile mapping (source in container → destination on EC2):
#   /host-configs/tmux.conf  →  ~/.tmux.conf
#   /host-configs/bashrc     →  ~/.bashrc
#   /host-configs/zshrc      →  ~/.zshrc
#   /host-configs/vimrc      →  ~/.vimrc
#   /host-configs/fre-aws    →  ~/.fre-aws-user-env  (sourced before Claude launches)
#
# Does NOT touch ~/.bash_profile or ~/.zprofile — those are system-managed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Preserve any caller-provided AWS_PROFILE
_CALLER_PROFILE="${AWS_PROFILE:-}"

# Load config
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

DEV_USERNAME="${DEV_USERNAME:-}"
if [[ -z "${DEV_USERNAME}" ]]; then
  echo "ERROR: DEV_USERNAME not set. Use './admin.sh push-config <username>'." >&2
  exit 1
fi

_PROFILE_ARGS=()
[[ -n "${AWS_PROFILE:-}" ]] && _PROFILE_ARGS=(--profile "${AWS_PROFILE}")
_CREDS=$(aws configure export-credentials "${_PROFILE_ARGS[@]}" --format env-no-export 2>/dev/null) || {
  echo "ERROR: Could not export credentials${AWS_PROFILE:+ for profile '${AWS_PROFILE}'}." >&2
  echo "       If using SSO, run './admin.sh sso-login' first." >&2
  exit 1
}
eval "$(echo "${_CREDS}" | sed 's/^/export /')"
unset _CREDS _PROFILE_ARGS

# Resolve instance ID by Username tag
echo "--- resolving instance for '${DEV_USERNAME}' ---"
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
  echo "       Start the instance first: ./admin.sh start ${DEV_USERNAME}" >&2
  exit 1
fi

SSH_OPTS=(
  "-o" "StrictHostKeyChecking=no"
  "-o" "UserKnownHostsFile=/dev/null"
  "-o" "LogLevel=ERROR"
  "-o" "ProxyCommand=aws ssm start-session --target ${INSTANCE_ID} --document-name AWS-StartSSHSession --parameters portNumber=22 --region ${AWS_REGION}"
)

if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
  SSH_KEY_FILE="${SSH_KEY_FILE:-/root/.ssh/fre-claude}"
  SSH_OPTS+=("-i" "${SSH_KEY_FILE}")
fi

echo ""
echo "Pushing dotfiles to ${INSTANCE_ID} (${DEV_USERNAME})..."
echo ""

PUSHED=0
SKIPPED=0

_push_file() {
  local src="$1" dest="$2" label="$3"
  if [[ -f "${src}" ]]; then
    echo "  pushing ${label} → ${dest}"
    ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" "tee ${dest} > /dev/null" < "${src}"
    PUSHED=$(( PUSHED + 1 ))
  else
    echo "  skipping ${label} (not found on host)"
    SKIPPED=$(( SKIPPED + 1 ))
  fi
}

_push_file "/host-configs/tmux.conf" "~/.tmux.conf"        "~/.tmux.conf"
_push_file "/host-configs/bashrc"    "~/.bashrc"           "~/.bashrc"
_push_file "/host-configs/zshrc"     "~/.zshrc"            "~/.zshrc"
_push_file "/host-configs/vimrc"     "~/.vimrc"            "~/.vimrc"
_push_file "/host-configs/fre-aws"   "~/.fre-aws-user-env" "~/.fre-aws"

echo ""
if [[ "${PUSHED}" -eq 0 ]]; then
  echo "=== Nothing to push ==="
  echo "    None of the expected dotfiles were found on the host."
  echo "    Expected: ~/.tmux.conf  ~/.bashrc  ~/.zshrc  ~/.vimrc  ~/.fre-aws"
else
  echo "=== push-config complete: ${PUSHED} pushed, ${SKIPPED} skipped ==="
  echo "    Changes take effect on the next 'source <file>' or new shell session."
  echo "    tmux config: reload with 'tmux source-file ~/.tmux.conf' or start a new session."
fi
