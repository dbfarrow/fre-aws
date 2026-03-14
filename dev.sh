#!/usr/bin/env bash
# dev.sh — Developer tool for managing your Claude Code environment.
#
# Usage:
#   ./dev.sh start    [config]  - Start your EC2 instance
#   ./dev.sh stop     [config]  - Stop your EC2 instance (preserves all your data)
#   ./dev.sh connect  [config]  - Connect to your EC2 instance
#
# config defaults to config/developer.env. Pass an alternate file to test
# multiple users without editing developer.env:
#   ./dev.sh connect config/alice.env
set -euo pipefail

IMAGE_NAME="fre-aws"
COMMAND="${1:-}"
CONFIG_ARG="${2:-}"

if [[ -z "${COMMAND}" ]]; then
  echo "Usage: $0 {start|stop|connect} [config-file]" >&2
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
# Load developer config
# ---------------------------------------------------------------------------
if [[ -n "${CONFIG_ARG}" ]]; then
  DEV_CONFIG="$(pwd)/${CONFIG_ARG}"
else
  DEV_CONFIG="$(pwd)/config/developer.env"
fi

if [[ ! -f "${DEV_CONFIG}" ]]; then
  echo "ERROR: Config file not found: ${DEV_CONFIG}" >&2
  echo "       Copy the example and fill in your values:" >&2
  echo "         cp config/developer.env.example config/developer.env" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${DEV_CONFIG}"

: "${MY_USERNAME:?MY_USERNAME must be set in config/developer.env}"
: "${AWS_PROFILE:?AWS_PROFILE must be set in config/developer.env}"

# ---------------------------------------------------------------------------
# Common docker run arguments
# ---------------------------------------------------------------------------
DOCKER_ARGS=(
  "--rm"
  "--interactive"
  "--tty"
  "--env" "AWS_PAGER="
  "--env" "DEV_USERNAME=${MY_USERNAME}"
  # Mount AWS credentials (read-write: CLI writes SSO token cache)
  "--volume" "${HOME}/.aws:/root/.aws"
  # Mount the config file as developer.env regardless of its name on the host.
  # This allows alternate config files to be used without editing developer.env.
  "--volume" "${DEV_CONFIG}:/workspace/config/developer.env:ro"
  # Mount scripts
  "--volume" "$(pwd)/scripts:/workspace/scripts"
)

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${COMMAND}" in
  start)
    docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/start.sh
    ;;
  stop)
    docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/stop.sh
    ;;
  connect)
    # Verify the fre-claude SSH key exists on this Mac
    FRE_CLAUDE_KEY="${HOME}/.ssh/fre-claude"
    if [[ ! -f "${FRE_CLAUDE_KEY}" ]]; then
      echo "ERROR: SSH key not found at ~/.ssh/fre-claude" >&2
      echo "       Follow the SSH Key Setup section in README-developer.md" >&2
      exit 1
    fi

    CONNECT_ARGS=("${DOCKER_ARGS[@]}")
    CONNECT_ARGS+=("--volume" "${HOME}/.ssh:/root/.ssh:ro")
    # Forward git identity for session refresh on connect
    [[ -n "${GIT_USER_NAME:-}" ]]  && CONNECT_ARGS+=("--env" "GIT_USER_NAME=${GIT_USER_NAME}")
    [[ -n "${GIT_USER_EMAIL:-}" ]] && CONNECT_ARGS+=("--env" "GIT_USER_EMAIL=${GIT_USER_EMAIL}")
    docker run "${CONNECT_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/connect.sh
    ;;
  *)
    echo "Unknown command: ${COMMAND}" >&2
    echo "Usage: $0 {start|stop|connect}" >&2
    exit 1
    ;;
esac
