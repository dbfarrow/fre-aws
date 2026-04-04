#!/usr/bin/env bash
# run.sh — Download a project from EC2, run it locally in Docker, upload the output.
# Runs inside the tooling container. Called by the `run` case in run.sh (host dispatcher).
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

: "${RUN_PROJECT:?}" "${RUN_SCRIPT:?}" "${RUN_IMAGE_NAME:?}"
: "${HOST_TEMP_DIR:?}"
RUN_SCRIPT_ARGS_B64="${RUN_SCRIPT_ARGS_B64:-}"
RUN_MOUNT_COUNT="${RUN_MOUNT_COUNT:-0}"
RUN_ENV_FILE="${RUN_ENV_FILE:-}"

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
# Download project from EC2
# ---------------------------------------------------------------------------
mkdir -p /run-workspace/project
echo "Downloading '${RUN_PROJECT}' from EC2..."
scp -r "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}":~/repos/"${RUN_PROJECT}"/ /run-workspace/project/

# ---------------------------------------------------------------------------
# Build base image (fre-run-base:latest) if not present
# ---------------------------------------------------------------------------
if ! docker image inspect fre-run-base:latest >/dev/null 2>&1; then
  echo "Building base run image (fre-run-base:latest)..."
  if [[ -f "/run-dockerfile-base" ]]; then
    docker build -t fre-run-base:latest -f /run-dockerfile-base /run-workspace/project/"${RUN_PROJECT}"/ 2>&1
  else
    # Inline fallback when Dockerfile.run is not mounted
    docker build -t fre-run-base:latest - <<'HEREDOC'
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    nodejs \
    npm \
    curl \
    wget \
    jq \
    git \
    ca-certificates \
    build-essential \
    && rm -rf /var/lib/apt/lists/*
ENV PIP_BREAK_SYSTEM_PACKAGES=1
WORKDIR /app
HEREDOC
  fi
fi

# ---------------------------------------------------------------------------
# Build project image if .fre-run.dockerfile exists
# ---------------------------------------------------------------------------
PROJECT_DOCKERFILE="/run-workspace/project/${RUN_PROJECT}/.fre-run.dockerfile"
ACTIVE_IMAGE="fre-run-base:latest"
if [[ -f "${PROJECT_DOCKERFILE}" ]]; then
  echo "Building project image (${RUN_IMAGE_NAME}:latest)..."
  docker build -t "${RUN_IMAGE_NAME}:latest" -f "${PROJECT_DOCKERFILE}" /run-workspace/project/"${RUN_PROJECT}"/ 2>&1
  ACTIVE_IMAGE="${RUN_IMAGE_NAME}:latest"
fi

# ---------------------------------------------------------------------------
# Decode script args (null-delimited, base64-encoded)
# ---------------------------------------------------------------------------
SCRIPT_ARGS=()
if [[ -n "${RUN_SCRIPT_ARGS_B64}" ]]; then
  while IFS= read -r -d '' _arg; do
    SCRIPT_ARGS+=("${_arg}")
  done < <(echo "${RUN_SCRIPT_ARGS_B64}" | base64 -d)
fi

# ---------------------------------------------------------------------------
# Detect runner from script extension
# ---------------------------------------------------------------------------
runner=""
case "${RUN_SCRIPT}" in
  *.py)  runner="python3" ;;
  *.js)  runner="node" ;;
  *.ts)  runner="npx ts-node" ;;
  *.sh)  runner="bash" ;;
esac

# ---------------------------------------------------------------------------
# Build docker run args for program container
# ---------------------------------------------------------------------------
PROGRAM_ARGS=(
  "--rm"
  "--volume" "${HOST_TEMP_DIR}/project/${RUN_PROJECT}:/app"
  "--workdir" "/app"
)

# Add user-supplied mounts
for (( _mi=0; _mi<RUN_MOUNT_COUNT; _mi++ )); do
  _mount_var="RUN_MOUNT_${_mi}"
  PROGRAM_ARGS+=("--volume" "${!_mount_var}")
done

# Add env vars from env-file (skip blank lines and comments)
if [[ -n "${RUN_ENV_FILE}" && -f "${RUN_ENV_FILE}" ]]; then
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    [[ -z "${_line}" || "${_line}" =~ ^# ]] && continue
    PROGRAM_ARGS+=("--env" "${_line}")
  done < "${RUN_ENV_FILE}"
fi

# ---------------------------------------------------------------------------
# Run program and capture output
# ---------------------------------------------------------------------------
echo ""
echo "Running ${RUN_SCRIPT} in ${ACTIVE_IMAGE}..."
echo "─────────────────────────────────────────"
# shellcheck disable=SC2086
docker run "${PROGRAM_ARGS[@]}" "${ACTIVE_IMAGE}" ${runner} "${RUN_SCRIPT}" "${SCRIPT_ARGS[@]}" 2>&1 | tee /run-workspace/output.txt
echo "─────────────────────────────────────────"

# ---------------------------------------------------------------------------
# Upload output to EC2
# ---------------------------------------------------------------------------
ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "mkdir -p ~/uploads/${RUN_PROJECT}/ ~/www/${RUN_PROJECT}/ && ln -sf ~/uploads/${RUN_PROJECT} ~/www/${RUN_PROJECT}/uploads"
scp "${SSH_OPTS[@]}" /run-workspace/output.txt developer@"${INSTANCE_ID}":~/uploads/"${RUN_PROJECT}"/run-output.txt

echo ""
echo "Run complete. Tell Claude: done"
