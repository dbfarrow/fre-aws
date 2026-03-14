#!/usr/bin/env bash
# run.sh — Host-side wrapper. Runs fre-aws scripts inside the Docker container.
#
# Usage:
#   ./run.sh sso-login    - Log in via IAM Identity Center (SSO) — opens a browser URL/code prompt
#   ./run.sh verify       - Verify AWS credentials are working
#   ./run.sh bootstrap    - One-time setup (creates S3, DynamoDB, KMS)
#   ./run.sh up           - Create / update AWS infrastructure
#   ./run.sh down         - Destroy AWS infrastructure
#   ./run.sh start        - Start the EC2 instance
#   ./run.sh stop         - Stop the EC2 instance
#   ./run.sh connect      - Open a shell on the EC2 instance
#   ./run.sh test         - Run BATS tests
#   ./run.sh shell        - Interactive shell inside the container (for debugging)
set -euo pipefail

IMAGE_NAME="fre-aws"
COMMAND="${1:-}"

if [[ -z "${COMMAND}" ]]; then
  echo "Usage: $0 {sso-login|verify|bootstrap|up|down|start|stop|connect|test|shell}" >&2
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
# Common docker run arguments
# ---------------------------------------------------------------------------
DOCKER_ARGS=(
  "--rm"
  "--interactive"
  "--tty"
  # Disable the AWS CLI pager — less is not installed in the container
  # and paging makes no sense in a non-interactive Docker context.
  "--env" "AWS_PAGER="
  # Mount AWS credentials read-write: the CLI writes SSO token cache to
  # ~/.aws/sso/cache/ and response cache to ~/.aws/cli/cache/ even for
  # read-only operations like sts get-caller-identity.
  "--volume" "${HOME}/.aws:/root/.aws"
  # Mount config (read-write so bootstrap.sh can write backend.env)
  "--volume" "$(pwd)/config:/workspace/config"
  # Mount terraform dir (for state cache and .terraform/)
  "--volume" "$(pwd)/terraform:/workspace/terraform"
)

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${COMMAND}" in
  sso-login)
    # Load the profile name from config if available, fall back to default
    AWS_PROFILE="claude-code"
    if [[ -f "$(pwd)/config/defaults.env" ]]; then
      # shellcheck source=/dev/null
      source "$(pwd)/config/defaults.env"
    fi
    # --use-device-code forces the URL+code flow instead of trying to open a
    # browser, which doesn't exist inside the container. The user opens the
    # printed URL in their Mac browser to complete login.
    docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" \
      aws sso login --use-device-code --profile "${AWS_PROFILE}"
    ;;
  verify)
    # Load the profile name from config if available, fall back to default
    AWS_PROFILE="claude-code"
    if [[ -f "$(pwd)/config/defaults.env" ]]; then
      # shellcheck source=/dev/null
      source "$(pwd)/config/defaults.env"
    fi
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
    docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/start.sh
    ;;
  stop)
    docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/stop.sh
    ;;
  connect)
    docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/connect.sh
    ;;
  test)
    docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" bats /workspace/tests/bats/
    ;;
  shell)
    docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /bin/bash
    ;;
  *)
    echo "Unknown command: ${COMMAND}" >&2
    echo "Usage: $0 {sso-login|verify|bootstrap|up|down|start|stop|connect|test|shell}" >&2
    exit 1
    ;;
esac
