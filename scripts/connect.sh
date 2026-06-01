#!/usr/bin/env bash
# connect.sh — Opens an SSH session tunneled through SSM with agent forwarding.
# No inbound port 22 needed. Local GitHub SSH keys work transparently via -A.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Preserve any caller-provided AWS_PROFILE (admin.sh passes its admin profile via --env)
_CALLER_PROFILE="${AWS_PROFILE:-}"

# Load config: user.env takes precedence (user path); fall back to admin.env (admin path)
if [[ -f "${SCRIPT_DIR}/../config/user.env" ]]; then
  source "${SCRIPT_DIR}/../config/user.env"
elif [[ -f "${SCRIPT_DIR}/../config/admin.env" ]]; then
  source "${SCRIPT_DIR}/../config/admin.env"
else
  echo "ERROR: No config found. Expected config/user.env or config/admin.env." >&2
  exit 1
fi
source "${SCRIPT_DIR}/../config/backend.env" 2>/dev/null || true

# Caller-provided profile wins (admin.sh connect must use admin credentials, not user.env's profile)
[[ -n "${_CALLER_PROFILE}" ]] && AWS_PROFILE="${_CALLER_PROFILE}"

: "${AWS_REGION:?}" "${PROJECT_NAME:?}"

# DEV_USERNAME: set by admin.sh (command arg) or user.env (MY_USERNAME)
DEV_USERNAME="${DEV_USERNAME:-${MY_USERNAME:-}}"
if [[ -z "${DEV_USERNAME}" ]]; then
  echo "ERROR: DEV_USERNAME not set. Use './admin.sh connect <username>' or set MY_USERNAME in config/user.env." >&2
  exit 1
fi

# Preflight: session-manager-plugin is required for SSH-over-SSM ProxyCommand
if ! command -v session-manager-plugin &>/dev/null; then
  echo "ERROR: session-manager-plugin is not installed or not in PATH." >&2
  echo "       Install it with: brew install --cask session-manager-plugin" >&2
  echo "       Or download from: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html" >&2
  exit 1
fi

_PROFILE_ARGS=()
[[ -n "${AWS_PROFILE:-}" ]] && _PROFILE_ARGS=(--profile "${AWS_PROFILE}")
if ! CREDS=$(aws configure export-credentials "${_PROFILE_ARGS[@]}" --format env-no-export 2>/dev/null); then
  echo "Not logged in${AWS_PROFILE:+ (profile '${AWS_PROFILE}')}. Starting SSO login..."
  aws sso login --use-device-code "${_PROFILE_ARGS[@]}" || {
    echo "ERROR: SSO login failed." >&2
    exit 1
  }
  CREDS=$(aws configure export-credentials "${_PROFILE_ARGS[@]}" --format env-no-export 2>/dev/null) || {
    echo "ERROR: Could not export credentials after SSO login." >&2
    exit 1
  }
fi
eval "$(echo "${CREDS}" | sed 's/^/export /')"

# Resolve instance ID by Username tag
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:Username,Values=${DEV_USERNAME}" \
    "Name=tag:ProjectName,Values=${PROJECT_NAME}" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --region "${AWS_REGION}" \
  --output text 2>/dev/null)

if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
  echo "ERROR: No instance found for user '${DEV_USERNAME}' in project '${PROJECT_NAME}'." >&2
  echo "       Has './admin.sh up' been run?" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Weekly SSM agent version check (runs when DO_VERSION_CHECK=true, set by
# run.sh if the state file is absent or >7 days old).
# Reads/writes /workspace/config/.state/versions.env on the host (via mount).
# ---------------------------------------------------------------------------
if [[ "${DO_VERSION_CHECK:-false}" == "true" ]]; then
  _VER_SSM_NEW=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
    --query 'InstanceInformationList[0].AgentVersion' \
    --region "${AWS_REGION}" \
    --output text 2>/dev/null || true)
  if [[ -n "${_VER_SSM_NEW}" && "${_VER_SSM_NEW}" != "None" ]]; then
    _VER_STATE_FILE="/workspace/config/.state/versions.env"
    mkdir -p "/workspace/config/.state"
    # Read existing fields (preserve PLUGIN_* written by build)
    _VER_PLUGIN=""; _VER_PLUGIN_AT=0
    _VER_SSM_OLD=""; _VER_SSM_CHANGED=0
    if [[ -f "${_VER_STATE_FILE}" ]]; then
      _VER_PLUGIN=$(grep      '^PLUGIN_VERSION='       "${_VER_STATE_FILE}" | cut -d= -f2 | tr -d '"' || true)
      _VER_PLUGIN_AT=$(grep   '^PLUGIN_UPDATED_AT='    "${_VER_STATE_FILE}" | cut -d= -f2 | tr -d '"' || true)
      _VER_SSM_OLD=$(grep     '^SSM_AGENT_VERSION='    "${_VER_STATE_FILE}" | cut -d= -f2 | tr -d '"' || true)
      _VER_SSM_CHANGED=$(grep '^SSM_AGENT_CHANGED_AT=' "${_VER_STATE_FILE}" | cut -d= -f2 | tr -d '"' || true)
    fi
    # If this is the first check ever, seed plugin version from the running container
    if [[ -z "${_VER_PLUGIN}" ]]; then
      _VER_PLUGIN=$(session-manager-plugin --version 2>/dev/null | tr -d '[:space:]' || echo "unknown")
      _VER_PLUGIN_AT=$(date +%s)
    fi
    # Detect agent version change
    if [[ -n "${_VER_SSM_OLD}" && "${_VER_SSM_NEW}" != "${_VER_SSM_OLD}" ]]; then
      echo "ℹ  SSM agent version changed: ${_VER_SSM_OLD} → ${_VER_SSM_NEW}"
      _VER_SSM_CHANGED=$(date +%s)
    fi
    printf 'PLUGIN_VERSION="%s"\nPLUGIN_UPDATED_AT="%s"\nSSM_AGENT_VERSION="%s"\nSSM_AGENT_CHANGED_AT="%s"\nSSM_AGENT_CHECKED_AT="%s"\n' \
      "${_VER_PLUGIN}" "${_VER_PLUGIN_AT:-0}" \
      "${_VER_SSM_NEW}" "${_VER_SSM_CHANGED:-0}" "$(date +%s)" \
      > "${_VER_STATE_FILE}"
  fi
fi

# Verify the instance is running
INSTANCE_STATE=$(aws ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" \
  --region "${AWS_REGION}" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text 2>/dev/null) || {
  echo "ERROR: Could not describe instance ${INSTANCE_ID}. Check your AWS credentials." >&2
  exit 1
}

if [[ "${INSTANCE_STATE}" != "running" ]]; then
  if [[ "${INSTANCE_STATE}" == "stopped" ]]; then
    read -r -p "Instance is stopped. Start it now? [y/N] " _start_confirm
    if [[ ! "${_start_confirm}" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 0
    fi
    echo "Starting ${INSTANCE_ID}..."
    aws ec2 start-instances --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}" > /dev/null
    echo "Waiting for instance to be running..."
    aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}"
    echo ""
  elif [[ "${INSTANCE_STATE}" == "pending" ]]; then
    echo "Instance is starting up, waiting..."
    aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}"
    echo ""
  elif [[ "${INSTANCE_STATE}" == "stopping" ]]; then
    echo "Instance is currently stopping. Wait a moment and try again." >&2
    exit 0
  else
    echo "ERROR: Instance is in state '${INSTANCE_STATE}' — cannot connect." >&2
    exit 1
  fi
fi

# Wait for SSM agent regardless of how the instance reached running state.
# Covers: externally started (Slack bot), resumed from hibernation, pending→running.
_ssm_ready=false
for _i in $(seq 1 24); do
  _ping=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
    --region "${AWS_REGION}" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)
  if [[ "${_ping}" == "Online" ]]; then _ssm_ready=true; break; fi
  if [[ "${_i}" -eq 1 ]]; then echo "Waiting for SSM agent..."; fi
  sleep 5
done
if [[ "${_ssm_ready}" != true ]]; then
  echo "WARNING: SSM agent not yet responding. Connection may fail — try again in a moment."
else
  echo "SSM agent ready."
fi
echo ""

echo "Connecting to ${INSTANCE_ID} (${DEV_USERNAME}) via SSH over SSM..."
echo ""

# Common SSH options for both authentication paths
SSH_OPTS=(
  "-A"                              # Forward agent to EC2 (keys in agent available on instance)
  "-o" "StrictHostKeyChecking=no"   # Instance ID changes on recreate
  "-o" "UserKnownHostsFile=/dev/null"
  # Keepalives: send a null packet every 10s so the SSM WebSocket stays alive.
  # With plugin 1.2.814.0 / agent 3.3.x the WebSocket occasionally stalls without
  # closing — 3 missed keepalives (30s total) gets a clean disconnect rather than
  # an indefinite hang. ServerAliveInterval=10 also keeps the SSM WebSocket warm
  # enough that the service doesn't consider the session idle between Claude turns.
  "-o" "ServerAliveInterval=10"
  "-o" "ServerAliveCountMax=3"
  # Tunnel SSH through SSM — no inbound port 22 needed in security group
  "-o" "ProxyCommand=aws ssm start-session --target ${INSTANCE_ID} --document-name AWS-StartSSHSession --parameters portNumber=22 --region ${AWS_REGION}"
)

# Forward git identity to the remote session so session_start.sh can refresh it
[[ -n "${GIT_USER_NAME:-}"  ]] && SSH_OPTS+=("-o" "SendEnv=GIT_USER_NAME")
[[ -n "${GIT_USER_EMAIL:-}" ]] && SSH_OPTS+=("-o" "SendEnv=GIT_USER_EMAIL")

if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
  # Agent forwarding path: host ssh-agent is mounted into this container.
  # SSH will authenticate using keys already in the agent — no key file or prompt needed.
  :
else
  # Key file path: start a fresh agent inside the container and load the key.
  SSH_KEY_FILE="${SSH_KEY_FILE:-/root/.ssh/fre-claude}"
  if [[ ! -f "${SSH_KEY_FILE}" ]]; then
    echo "ERROR: SSH key not found: ${SSH_KEY_FILE}" >&2
    echo "       Start your SSH agent and run 'ssh-add' on your Mac," >&2
    echo "       or set SSH_KEY_FILE in config/admin.env." >&2
    exit 1
  fi
  eval "$(ssh-agent -s)" > /dev/null
  if [[ -n "${SSH_KEY_PASSPHRASE_SECRET:-}" ]]; then
    # User mode: retrieve passphrase from Secrets Manager, load key non-interactively
    PASSPHRASE=$(aws secretsmanager get-secret-value \
      --secret-id "${SSH_KEY_PASSPHRASE_SECRET}" \
      --query 'SecretString' --output text \
      --region "${AWS_REGION}" 2>/dev/null) || {
      echo "ERROR: Could not retrieve SSH key passphrase from Secrets Manager." >&2
      echo "       Secret: ${SSH_KEY_PASSPHRASE_SECRET}" >&2
      echo "       Ensure your AWS credentials are active (run 'user.sh sso-login')." >&2
      exit 1
    }
    # Write a temporary askpass helper that prints the passphrase non-interactively
    ASKPASS_SCRIPT=$(mktemp)
    chmod 700 "${ASKPASS_SCRIPT}"
    printf '#!/bin/sh\nprintf "%%s" "${_SSH_PASSPHRASE}"\n' > "${ASKPASS_SCRIPT}"
    trap 'rm -f "${ASKPASS_SCRIPT}"' EXIT
    _SSH_PASSPHRASE="${PASSPHRASE}" \
      SSH_ASKPASS="${ASKPASS_SCRIPT}" \
      SSH_ASKPASS_REQUIRE=force \
      ssh-add "${SSH_KEY_FILE}" >/dev/null 2>&1 || {
      echo "ERROR: Failed to add SSH key. The passphrase stored in Secrets Manager may not match the key." >&2
      exit 1
    }
    unset PASSPHRASE _SSH_PASSPHRASE
  else
    # Admin mode: interactive passphrase prompt (or no passphrase if key has none)
    ssh-add "${SSH_KEY_FILE}"
  fi
  SSH_OPTS+=("-i" "${SSH_KEY_FILE}")  # Explicit key — SSH won't auto-discover non-default names
fi

SSH_OPTS+=("-L" "0.0.0.0:${WEB_PREVIEW_PORT:-8080}:localhost:8080")

# Forward any additional ports requested by the caller (e.g. OAuth callback receivers)
for _port in ${EXTRA_FORWARD_PORTS:-}; do
  SSH_OPTS+=("-L" "0.0.0.0:${_port}:localhost:${_port}")
done
unset _port

ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}"
