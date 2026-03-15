#!/usr/bin/env bash
# admin.sh — Admin tool for managing the fre-aws Claude Code environment.
#
# Usage:
#   ./admin.sh list                   - List all users and their instance state
#   ./admin.sh sso-login              - Log in via IAM Identity Center
#   ./admin.sh verify                 - Verify AWS credentials are working
#   ./admin.sh bootstrap              - One-time setup (S3, DynamoDB, KMS)
#   ./admin.sh up                     - Create / update AWS infrastructure
#   ./admin.sh down                   - Destroy AWS infrastructure
#   ./admin.sh start   [username]     - Start a user's EC2 instance (omit username to start all)
#   ./admin.sh stop    [username]     - Stop a user's EC2 instance (omit username to stop all)
#   ./admin.sh connect <username>     - Open a shell on a user's EC2 instance
#   ./admin.sh refresh <username>     - Push updated session_start.sh to a running instance
#   ./admin.sh ssm     <username>     - Direct SSM shell (fallback when SSH isn't working)
#   ./admin.sh test                   - Run BATS tests
#   ./admin.sh shell                  - Interactive shell inside the container (for debugging)
set -euo pipefail

IMAGE_NAME="fre-aws"
COMMAND="${1:-}"
USERNAME="${2:-}"

if [[ -z "${COMMAND}" ]]; then
  echo "Usage: $0 {list|sso-login|verify|bootstrap|up|down|start|stop|connect|refresh|ssm|test|shell}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Build the image if it doesn't exist (first run convenience)
# ---------------------------------------------------------------------------
if ! docker image inspect "${IMAGE_NAME}" &>/dev/null; then
  echo "Docker image '${IMAGE_NAME}' not found. Building..."
  docker build -t "${IMAGE_NAME}" "$(dirname "$0")"
fi

# ---------------------------------------------------------------------------
# Load admin config on the host so we can pass settings into the container.
# ---------------------------------------------------------------------------
AWS_PROFILE="claude-code"
if [[ -f "$(pwd)/config/defaults.env" ]]; then
  # shellcheck source=/dev/null
  source "$(pwd)/config/defaults.env"
fi

# ---------------------------------------------------------------------------
# Common docker run arguments
# ---------------------------------------------------------------------------
DOCKER_ARGS=(
  "--rm"
  "--interactive"
  "--tty"
  "--env" "AWS_PAGER="
  # Mount AWS credentials (read-write: CLI writes SSO token cache)
  "--volume" "${HOME}/.aws:/root/.aws"
  # Mount config (read-write so bootstrap.sh can write backend.env)
  "--volume" "$(pwd)/config:/workspace/config"
  # Mount terraform dir (for state cache and .terraform/)
  "--volume" "$(pwd)/terraform:/workspace/terraform"
  # Mount scripts so edits take effect without rebuilding the image
  "--volume" "$(pwd)/scripts:/workspace/scripts"
)

# ---------------------------------------------------------------------------
# Helper: require a username argument for per-user commands
# ---------------------------------------------------------------------------
require_username() {
  if [[ -z "${USERNAME}" ]]; then
    echo "Usage: $0 ${COMMAND} <username>" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${COMMAND}" in
  list)
    docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/list.sh
    ;;
  sso-login)
    docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" \
      aws sso login --use-device-code --profile "${AWS_PROFILE}"
    ;;
  verify)
    docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" \
      aws sts get-caller-identity --profile "${AWS_PROFILE}" --output table
    ;;
  bootstrap)
    docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/bootstrap.sh
    ;;
  up)
    docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/up.sh
    ;;
  down)
    docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/down.sh
    ;;
  start)
    if [[ -n "${USERNAME}" ]]; then
      docker run "${DOCKER_ARGS[@]}" \
        --env "DEV_USERNAME=${USERNAME}" \
        "${IMAGE_NAME}" /workspace/scripts/start.sh
    else
      CONFIGURED_USERS=$(grep -E '^\s+"?[a-zA-Z0-9_.@-]+"? = \{' "$(pwd)/config/users.tfvars" 2>/dev/null | awk '{gsub(/"/, "", $1); print $1}')
      if [[ -z "${CONFIGURED_USERS}" ]]; then
        echo "No users configured in config/users.tfvars." >&2; exit 1
      fi
      for user in ${CONFIGURED_USERS}; do
        docker run "${DOCKER_ARGS[@]}" --env "DEV_USERNAME=${user}" "${IMAGE_NAME}" /workspace/scripts/start.sh
      done
    fi
    ;;
  stop)
    if [[ -n "${USERNAME}" ]]; then
      docker run "${DOCKER_ARGS[@]}" \
        --env "DEV_USERNAME=${USERNAME}" \
        "${IMAGE_NAME}" /workspace/scripts/stop.sh
    else
      CONFIGURED_USERS=$(grep -E '^\s+"?[a-zA-Z0-9_.@-]+"? = \{' "$(pwd)/config/users.tfvars" 2>/dev/null | awk '{gsub(/"/, "", $1); print $1}')
      if [[ -z "${CONFIGURED_USERS}" ]]; then
        echo "No users configured in config/users.tfvars." >&2; exit 1
      fi
      for user in ${CONFIGURED_USERS}; do
        docker run "${DOCKER_ARGS[@]}" --env "DEV_USERNAME=${user}" "${IMAGE_NAME}" /workspace/scripts/stop.sh
      done
    fi
    ;;
  connect)
    require_username
    # Verify the fre-claude key exists on this Mac
    FRE_CLAUDE_KEY="${HOME}/.ssh/fre-claude"
    if [[ ! -f "${FRE_CLAUDE_KEY}" ]]; then
      echo "ERROR: SSH key not found at ~/.ssh/fre-claude" >&2
      echo "       Create it with:" >&2
      echo "         ssh-keygen -t ed25519 -f ~/.ssh/fre-claude -C 'fre-claude'" >&2
      exit 1
    fi
    docker run "${DOCKER_ARGS[@]}" \
      --volume "${HOME}/.ssh:/root/.ssh:ro" \
      --env "DEV_USERNAME=${USERNAME}" \
      "${IMAGE_NAME}" /workspace/scripts/connect.sh
    ;;
  refresh)
    require_username
    FRE_CLAUDE_KEY="${HOME}/.ssh/fre-claude"
    if [[ ! -f "${FRE_CLAUDE_KEY}" ]]; then
      echo "ERROR: SSH key not found at ~/.ssh/fre-claude" >&2
      exit 1
    fi
    docker run "${DOCKER_ARGS[@]}" \
      --volume "${HOME}/.ssh:/root/.ssh:ro" \
      --env "DEV_USERNAME=${USERNAME}" \
      "${IMAGE_NAME}" /workspace/scripts/refresh.sh
    ;;
  ssm)
    require_username
    docker run "${DOCKER_ARGS[@]}" \
      --env "DEV_USERNAME=${USERNAME}" \
      "${IMAGE_NAME}" /workspace/scripts/ssm.sh
    ;;
  test)
    docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" bats /workspace/tests/bats/
    ;;
  shell)
    docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /bin/bash -c '
      source /workspace/config/defaults.env 2>/dev/null || true
      source /workspace/config/backend.env  2>/dev/null || true
      eval "$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env-no-export 2>/dev/null | sed '"'"'s/^/export /'"'"')" || true
      exec /bin/bash
    '
    ;;
  *)
    echo "Unknown command: ${COMMAND}" >&2
    echo "Usage: $0 {list|sso-login|verify|bootstrap|up|down|start|stop|connect|refresh|ssm|test|shell}" >&2
    exit 1
    ;;
esac
