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
#   ./run.sh connect      - Open a shell on the EC2 instance (SSH with agent forwarding)
#   ./run.sh ssm          - Direct SSM shell (fallback when SSH isn't working)
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
# Load config on the host so we can pass SSH key and git identity into the
# container without needing to mount ~/.ssh for most commands.
# ---------------------------------------------------------------------------
SSH_PUBLIC_KEY=""
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GIT_USER_NAME="${GIT_USER_NAME:-}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-}"

if [[ -f "$(pwd)/config/defaults.env" ]]; then
  # shellcheck source=/dev/null
  source "$(pwd)/config/defaults.env"

  # Read SSH public key content on the host (path is a Mac path, not container path)
  if [[ -n "${SSH_PUBLIC_KEY_FILE:-}" ]]; then
    EXPANDED_KEY_FILE="${SSH_PUBLIC_KEY_FILE/#\~/$HOME}"
    if [[ -f "${EXPANDED_KEY_FILE}" ]]; then
      SSH_PUBLIC_KEY=$(cat "${EXPANDED_KEY_FILE}")
    else
      echo "WARNING: SSH_PUBLIC_KEY_FILE '${SSH_PUBLIC_KEY_FILE}' not found." >&2
    fi
  fi
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
  # Mount scripts so edits take effect without rebuilding the image
  "--volume" "$(pwd)/scripts:/workspace/scripts"
  # Pass SSH public key and git identity so up.sh can inject them into Terraform
  "--env" "SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY}"
  "--env" "GIT_USER_NAME=${GIT_USER_NAME}"
  "--env" "GIT_USER_EMAIL=${GIT_USER_EMAIL}"
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
    # Ensure the fre-claude key exists and is loaded in the Mac SSH agent.
    # The agent socket is then forwarded into the container so -A works end-to-end.
    FRE_CLAUDE_KEY="${HOME}/.ssh/fre-claude"
    if [[ ! -f "${FRE_CLAUDE_KEY}" ]]; then
      echo "ERROR: SSH key not found at ~/.ssh/fre-claude" >&2
      echo "       Create it with:" >&2
      echo "         ssh-keygen -t ed25519 -f ~/.ssh/fre-claude -C 'fre-claude'" >&2
      echo "       Then re-run './run.sh up' so Terraform can install the public key on the instance." >&2
      exit 1
    fi
    # Add to agent if not already loaded (avoids repeated passphrase prompts)
    if ! ssh-add -l 2>/dev/null | grep -qF "${FRE_CLAUDE_KEY}"; then
      echo "Adding fre-claude key to SSH agent..."
      ssh-add "${FRE_CLAUDE_KEY}"
    fi

    # Extra args for connect: SSH agent socket forwarding + GitHub token
    CONNECT_ARGS=("${DOCKER_ARGS[@]}")
    # Mount ~/.ssh read-only so SSH can find keys and known_hosts
    CONNECT_ARGS+=("--volume" "${HOME}/.ssh:/root/.ssh:ro")
    # Forward SSH agent from the Mac into the container so -A works end-to-end.
    # Docker Desktop for Mac exposes the host agent via this socket.
    if [[ -S "/run/host-services/ssh-auth.sock" ]]; then
      CONNECT_ARGS+=(
        "--volume" "/run/host-services/ssh-auth.sock:/ssh-agent.sock"
        "--env"    "SSH_AUTH_SOCK=/ssh-agent.sock"
      )
    fi
    # Pass GitHub token and git identity so session_start.sh can use them
    [[ -n "${GITHUB_TOKEN:-}" ]]  && CONNECT_ARGS+=("--env" "GH_TOKEN=${GITHUB_TOKEN}")
    [[ -n "${GIT_USER_NAME:-}" ]] && CONNECT_ARGS+=("--env" "GIT_USER_NAME=${GIT_USER_NAME}")
    [[ -n "${GIT_USER_EMAIL:-}" ]] && CONNECT_ARGS+=("--env" "GIT_USER_EMAIL=${GIT_USER_EMAIL}")
    docker run "${CONNECT_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/connect.sh
    ;;
  ssm)
    # Direct SSM shell — bypasses SSH entirely. Useful when SSH isn't working
    # or for admin tasks that don't need the developer user environment.
    docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/ssm.sh
    ;;
  test)
    docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" bats /workspace/tests/bats/
    ;;
  shell)
    # Drop into an interactive shell with credentials pre-exported for terraform.
    docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /bin/bash -c '
      source /workspace/config/defaults.env 2>/dev/null || true
      source /workspace/config/backend.env  2>/dev/null || true
      eval "$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env-no-export 2>/dev/null | sed '"'"'s/^/export /'"'"')" || true
      exec /bin/bash
    '
    ;;
  *)
    echo "Unknown command: ${COMMAND}" >&2
    echo "Usage: $0 {sso-login|verify|bootstrap|up|down|start|stop|connect|ssm|test|shell}" >&2
    exit 1
    ;;
esac
