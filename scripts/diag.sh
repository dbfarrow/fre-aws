#!/usr/bin/env bash
# diag.sh — SSM session / tunnel-freeze diagnosis
# Current hypothesis: session-manager-plugin version in Docker image (built at image
#   build time) may be older than the SSM agent on the new instance (3.3.4108.0),
#   causing protocol-level WebSocket stalls even under active traffic.
#   This check reports both versions so they can be compared.
#
# Run via: ./admin.sh diag
# Output goes to stdout AND config/diag-output.txt (readable by Claude on the host).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE="/workspace/config/diag-output.txt"

# ---------------------------------------------------------------------------
# Config + credentials
# ---------------------------------------------------------------------------
if [[ -f "${SCRIPT_DIR}/../config/admin.env" ]]; then
  source "${SCRIPT_DIR}/../config/admin.env"
elif [[ -f "${SCRIPT_DIR}/../config/user.env" ]]; then
  source "${SCRIPT_DIR}/../config/user.env"
else
  echo "ERROR: No config found (admin.env or user.env)." >&2
  exit 1
fi
source "${SCRIPT_DIR}/../config/backend.env" 2>/dev/null || true

: "${PROJECT_NAME:?}" "${AWS_REGION:?}"

_PROFILE_ARGS=()
[[ -n "${AWS_PROFILE:-}" ]] && _PROFILE_ARGS=(--profile "${AWS_PROFILE}")
_CREDS=$(aws configure export-credentials "${_PROFILE_ARGS[@]}" --format env-no-export 2>/dev/null) || {
  echo "ERROR: Could not export credentials. Run './admin.sh sso-login' first." >&2
  exit 1
}
eval "$(echo "${_CREDS}" | sed 's/^/export /')"
unset _CREDS _PROFILE_ARGS

# ---------------------------------------------------------------------------
# SSM helpers
# ---------------------------------------------------------------------------
_ssm_run() {
  local instance_id="$1"
  local label="$2"
  local cmd="$3"

  echo "--- ${label} ---"

  local input_json
  input_json=$(jq -n \
    --arg iid "${instance_id}" \
    --arg cmd "${cmd}" \
    '{"InstanceIds":[$iid],"DocumentName":"AWS-RunShellScript","Parameters":{"commands":[$cmd],"executionTimeout":["30"]}}')

  local cmd_id
  cmd_id=$(aws ssm send-command \
    --region "${AWS_REGION}" \
    --cli-input-json "${input_json}" \
    --query 'Command.CommandId' \
    --output text 2>/dev/null)

  local status=""
  for _w in $(seq 1 12); do
    sleep 5
    status=$(aws ssm get-command-invocation \
      --command-id "${cmd_id}" \
      --instance-id "${instance_id}" \
      --query 'Status' \
      --region "${AWS_REGION}" \
      --output text 2>/dev/null || echo "Pending")
    [[ "${status}" == "Success" || "${status}" == "Failed" || "${status}" == "TimedOut" ]] && break
  done

  aws ssm get-command-invocation \
    --command-id "${cmd_id}" \
    --instance-id "${instance_id}" \
    --query 'StandardOutputContent' \
    --region "${AWS_REGION}" \
    --output text 2>/dev/null

  if [[ "${status}" == "Failed" || "${status}" == "TimedOut" ]]; then
    echo "(command status: ${status})"
    aws ssm get-command-invocation \
      --command-id "${cmd_id}" \
      --instance-id "${instance_id}" \
      --query 'StandardErrorContent' \
      --region "${AWS_REGION}" \
      --output text 2>/dev/null || true
  fi
  echo ""
}

_wait_ssm() {
  local instance_id="$1"
  local max="${2:-6}"
  for _i in $(seq 1 "${max}"); do
    local _ping
    _ping=$(aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=${instance_id}" \
      --query 'InstanceInformationList[0].PingStatus' \
      --region "${AWS_REGION}" \
      --output text 2>/dev/null || true)
    [[ "${_ping}" == "Online" ]] && return 0
    echo "  SSM not ready yet (attempt ${_i}/${max})..."
    sleep 5
  done
  return 1
}

# ---------------------------------------------------------------------------
# Resolve instance
# ---------------------------------------------------------------------------
DEV_USERNAME="${DEV_USERNAME:-${MY_USERNAME:-}}"
: "${DEV_USERNAME:?ERROR: set MY_USERNAME in config/admin.env or pass DEV_USERNAME=<user>}"

INSTANCE_ID=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:Username,Values=${DEV_USERNAME}" \
    "Name=tag:ProjectName,Values=${PROJECT_NAME}" \
    "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --region "${AWS_REGION}" \
  --output text 2>/dev/null)

{
  echo "=== fre-aws diag: SSM tunnel freeze — $(date) ==="
  echo "  Project:  ${PROJECT_NAME}"
  echo "  User:     ${DEV_USERNAME}"
  echo "  Region:   ${AWS_REGION}"
  echo ""

  # ------------------------------------------------------------------
  # 0. Client-side: session-manager-plugin version (inside Docker)
  #    Compare against the SSM agent version on the instance.
  #    If the plugin is older than the agent, that's a likely culprit.
  # ------------------------------------------------------------------
  echo "--- client: session-manager-plugin version (Docker container) ---"
  session-manager-plugin --version 2>/dev/null || echo "(session-manager-plugin not found in PATH)"
  echo ""

  if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
    echo "ERROR: No running instance found for user '${DEV_USERNAME}' in project '${PROJECT_NAME}'."
    echo "       Is the instance running? Try: ./admin.sh start ${DEV_USERNAME}"
    exit 1
  fi
  echo "  Instance: ${INSTANCE_ID}"
  echo ""

  # ------------------------------------------------------------------
  # 1. SSM agent version + ping status
  # ------------------------------------------------------------------
  echo "--- SSM agent status (via EC2 API) ---"
  aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
    --region "${AWS_REGION}" \
    --query 'InstanceInformationList[0].{PingStatus:PingStatus,AgentVersion:AgentVersion,LastPingDateTime:LastPingDateTime}' \
    --output table 2>/dev/null
  echo ""

  if ! _wait_ssm "${INSTANCE_ID}" 3; then
    echo "ERROR: SSM agent not Online — cannot run on-instance checks."
    exit 1
  fi

  # ------------------------------------------------------------------
  # 2. Memory, swap, load average
  # ------------------------------------------------------------------
  _ssm_run "${INSTANCE_ID}" "memory + load" \
    "echo '== uptime / load =='; uptime; echo ''; echo '== memory (free -h) =='; free -h; echo ''; echo '== swap usage =='; swapon --show 2>/dev/null || echo '(no swap configured)'; echo ''; echo '== top 5 memory consumers =='; ps aux --sort=-%mem | head -6"

  # ------------------------------------------------------------------
  # 3. SSM agent service health + recent log lines
  #    Look for restarts, errors, or WebSocket disconnect messages
  # ------------------------------------------------------------------
  _ssm_run "${INSTANCE_ID}" "SSM agent logs (last 50 lines)" \
    "journalctl -u amazon-ssm-agent --no-pager -n 50 2>/dev/null || echo '(journalctl failed — trying log file)'; tail -n 50 /var/log/amazon/ssm/amazon-ssm-agent.log 2>/dev/null || true"

  # ------------------------------------------------------------------
  # 4. SSM agent restart history — how many times has it restarted?
  # ------------------------------------------------------------------
  _ssm_run "${INSTANCE_ID}" "SSM agent restart count" \
    "systemctl show amazon-ssm-agent --property=NRestarts,ActiveState,SubState,ExecMainStartTimestamp 2>/dev/null"

  # ------------------------------------------------------------------
  # 5. sshd idle-timeout settings
  #    ClientAliveInterval / ClientAliveCountMax control how long sshd
  #    keeps an idle client before closing. If too low, sshd boots the
  #    client before SSH keepalives have a chance to fire.
  # ------------------------------------------------------------------
  _ssm_run "${INSTANCE_ID}" "sshd idle-timeout config" \
    "echo '== /etc/ssh/sshd_config (ClientAlive* lines) =='; grep -i 'ClientAlive\|TCPKeepAlive\|ServerAlive' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null || echo '(no ClientAlive lines — using defaults: interval=0 meaning no server-side timeout)'"

  # ------------------------------------------------------------------
  # 6. Autoshutdown timer — confirm it's running and show last run time
  # ------------------------------------------------------------------
  _ssm_run "${INSTANCE_ID}" "autoshutdown timer" \
    "systemctl status autoshutdown.timer autoshutdown.service --no-pager 2>/dev/null; echo ''; echo '== last autoshutdown log entries =='; journalctl -u autoshutdown.service --no-pager -n 10 2>/dev/null || true"

  # ------------------------------------------------------------------
  # 7. Network: MTU on primary interface
  #    MTU mismatch (>1500 on an interface that can't handle it) is a
  #    classic cause of SSM/SSH sessions that freeze under load.
  # ------------------------------------------------------------------
  _ssm_run "${INSTANCE_ID}" "network MTU + interface" \
    "ip link show; echo ''; echo '== route =='; ip route"

  # ------------------------------------------------------------------
  # 8. Disk I/O — rule out heavy I/O blocking the SSM agent
  # ------------------------------------------------------------------
  _ssm_run "${INSTANCE_ID}" "disk usage + I/O wait" \
    "df -h; echo ''; echo '== I/O wait (1-second sample via iostat) =='; iostat -x 1 2 2>/dev/null || echo '(iostat not available)'"

  echo "=== Done ==="

} | tee "${OUTPUT_FILE}"

echo ""
echo "Results saved to config/diag-output.txt"
