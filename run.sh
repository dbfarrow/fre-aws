#!/usr/bin/env bash
# run.sh — Unified dispatch script for the fre-aws Claude Code environment.
#
# Invoke as admin.sh or user.sh (symlinks):
#   ./admin.sh <command> [username]
#   ./user.sh  <command> [config]
#
# Both symlinks point here; mode is detected via basename.
set -euo pipefail

IMAGE_NAME="fre-aws"
SCRIPT_NAME="$(basename "$0")"
COMMAND="${1:-}"

# ---------------------------------------------------------------------------
# Mode detection
# ---------------------------------------------------------------------------
case "${SCRIPT_NAME}" in
  admin.sh|admin) MODE="admin" ;;
  user.sh|user)   MODE="user"  ;;
  *)
    echo "ERROR: Invoke as admin.sh or user.sh (symlinks to run.sh)" >&2
    exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Help functions
# ---------------------------------------------------------------------------
usage_admin() {
  cat <<'EOF'
usage: admin.sh [-h] {command} [args]

Manage the fre-aws Claude Code environment.

options:
  -h, --help            Show this help message and exit

user management:
  add-user              Interactive wizard to add a new user
  remove-user <user>    Remove a user (destroys instance on next up)
  update-user-key <user>
                        Replace a user's SSH public key
  stat                  Show environment config, cost profile, and user/instance summary
  list [-v|--verbose]   List users and their instance state
                        -v shows all registry attributes (email, role, git, ssh key)

infrastructure:
  bootstrap             One-time setup (S3, DynamoDB, KMS, SES verification)
  up                    Create / update all AWS infrastructure
  down                  Destroy all AWS infrastructure
  repair-state [--dry-run] [user]
                        Import resources that exist in AWS but are missing from
                        Terraform state (fixes EntityAlreadyExists errors)

instance lifecycle:
  start [user]          Start an EC2 instance (omit user to start all)
  stop [user]           Stop an EC2 instance (omit user to stop all)

connection:
  connect <user>        Open a shell on a user's EC2 instance (SSH over SSM)
  refresh <user>        Push updated session_start.sh to a running instance
  ssm <user>            Direct SSM shell (fallback when SSH isn't working)

authentication:
  sso-login [--fresh]   Log in via IAM Identity Center
                        --fresh clears cached role credentials first
  verify                Verify AWS credentials are active
  verify-email <addr>   Pre-verify an SES recipient address (sandbox mode only)

development:
  build                 Build (or rebuild) the Docker image
  test                  Run BATS tests
  shell                 Interactive container shell for debugging

installer:
  publish-installer <user>
                        Re-generate installer bundle for a user, upload to
                        S3, and print a new 72-hour pre-signed URL
EOF
}

usage_user() {
  cat <<'EOF'
usage: user.sh [-h] {command} [config]

Connect to and manage your Claude Code EC2 instance.

options:
  -h, --help            Show this help message and exit
  config                Path to alternate user config (default: config/user.env)

authentication:
  sso-login [--fresh]   Log in to AWS (required before first connect each day)
                        --fresh clears cached role credentials first
  verify                Verify your AWS credentials are active

instance:
  start                 Start your EC2 instance
  stop                  Stop your instance when done (preserves all your data)

connection:
  connect               Open a shell on your EC2 instance

maintenance:
  update                Download and apply the latest scripts from S3
EOF
}

# ---------------------------------------------------------------------------
# Show help and exit on -h / --help / help / no command
# ---------------------------------------------------------------------------
if [[ -z "${COMMAND}" || "${COMMAND}" =~ ^(-h|--help|help)$ ]]; then
  "usage_${MODE}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Build image if missing (first-run convenience)
# ---------------------------------------------------------------------------
if ! docker image inspect "${IMAGE_NAME}" &>/dev/null; then
  echo "Docker image '${IMAGE_NAME}' not found. Building..."
  docker build -t "${IMAGE_NAME}" "$(dirname "$0")"
fi

# ---------------------------------------------------------------------------
# Admin mode setup
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "admin" ]]; then
  USERNAME="${2:-}"
  AWS_PROFILE="claude-code"

  if [[ -f "$(pwd)/config/admin.env" ]]; then
    # shellcheck source=/dev/null
    source "$(pwd)/config/admin.env"
  fi

  DOCKER_ARGS=(
    "--rm"
    "--interactive"
    "--tty"
    "--env" "AWS_PAGER="
    "--env" "SENDER_EMAIL=${SENDER_EMAIL:-}"
    "--env" "SSO_START_URL=${SSO_START_URL:-}"
    "--volume" "${HOME}/.aws:/root/.aws"
    "--volume" "$(pwd)/run.sh:/workspace/run.sh:ro"
    "--volume" "$(pwd)/Dockerfile:/workspace/Dockerfile:ro"
    "--volume" "$(pwd)/config:/workspace/config"
    "--volume" "$(pwd)/terraform:/workspace/terraform"
    "--volume" "$(pwd)/scripts:/workspace/scripts"
  )

  # Non-interactive variant — used when capturing stdout (e.g. list-users.sh)
  DOCKER_ARGS_QUIET=(
    "--rm"
    "--env" "AWS_PAGER="
    "--env" "SENDER_EMAIL=${SENDER_EMAIL:-}"
    "--env" "SSO_START_URL=${SSO_START_URL:-}"
    "--volume" "${HOME}/.aws:/root/.aws"
    "--volume" "$(pwd)/run.sh:/workspace/run.sh:ro"
    "--volume" "$(pwd)/Dockerfile:/workspace/Dockerfile:ro"
    "--volume" "$(pwd)/config:/workspace/config"
    "--volume" "$(pwd)/terraform:/workspace/terraform"
    "--volume" "$(pwd)/scripts:/workspace/scripts"
  )

  require_username() {
    if [[ -z "${USERNAME}" ]]; then
      echo "Usage: admin.sh ${COMMAND} <username>" >&2
      exit 1
    fi
  }
fi

# ---------------------------------------------------------------------------
# User mode setup
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "user" ]]; then
  USER_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  CONFIG_ARG="${2:-}"

  # Detect --fresh flag before treating CONFIG_ARG as a file path
  FRESH_CREDS=false
  if [[ "${CONFIG_ARG}" == "--fresh" || "${CONFIG_ARG}" == "-f" ]]; then
    FRESH_CREDS=true
    CONFIG_ARG=""
  fi

  if [[ -n "${CONFIG_ARG}" ]]; then
    DEV_CONFIG="${CONFIG_ARG}"
    # Resolve relative paths against cwd
    [[ "${DEV_CONFIG}" != /* ]] && DEV_CONFIG="$(pwd)/${CONFIG_ARG}"
  else
    DEV_CONFIG="${USER_SCRIPT_DIR}/config/user.env"
  fi

  if [[ ! -f "${DEV_CONFIG}" ]]; then
    echo "ERROR: Config file not found: ${DEV_CONFIG}" >&2
    echo "       Your admin will provide a user.env — save it to ~/fre-aws/config/user.env" >&2
    exit 1
  fi

  # shellcheck source=/dev/null
  source "${DEV_CONFIG}"

  : "${MY_USERNAME:?MY_USERNAME must be set in config/user.env}"
  : "${AWS_PROFILE:?AWS_PROFILE must be set in config/user.env}"

  DOCKER_ARGS=(
    "--rm"
    "--interactive"
    "--tty"
    "--env" "AWS_PAGER="
    "--env" "DEV_USERNAME=${MY_USERNAME}"
    "--volume" "${HOME}/.aws:/root/.aws"
    "--volume" "${DEV_CONFIG}:/workspace/config/user.env:ro"
    "--volume" "${USER_SCRIPT_DIR}/scripts:/workspace/scripts"
  )
fi

# ---------------------------------------------------------------------------
# Admin dispatch
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "admin" ]]; then
  case "${COMMAND}" in
    stat)
      docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/stat.sh
      ;;
    list)
      docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/list.sh "${@:2}"
      ;;
    sso-login)
      if [[ "${USERNAME:-}" == "--fresh" || "${USERNAME:-}" == "-f" ]]; then
        echo "Clearing credential cache..."
        rm -f "${HOME}/.aws/cli/cache/"* 2>/dev/null || true
      fi
      docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" \
        aws sso login --use-device-code --profile "${AWS_PROFILE}"
      ;;
    verify)
      docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/verify.sh
      ;;
    verify-email)
      if [[ -z "${USERNAME}" ]]; then
        echo "Usage: admin.sh verify-email <email-address>" >&2
        exit 1
      fi
      docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" \
        aws ses verify-email-identity \
          --email-address "${USERNAME}" \
          --region "${AWS_REGION}" \
          --profile "${AWS_PROFILE}"
      echo "Verification email sent to ${USERNAME}. Click the link before running add-user."
      ;;
    repair-state)
      docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/repair-state.sh "${@:2}"
      ;;
    bootstrap)
      docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/bootstrap.sh
      ;;
    up)
      if [[ -n "${USERNAME}" ]]; then
        echo "ERROR: 'up' provisions ALL users — it does not accept a username." >&2
        echo "       To add one user: ./admin.sh add-user, then ./admin.sh up" >&2
        exit 1
      fi
      docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/up.sh
      ;;
    down)
      if [[ -n "${USERNAME}" ]]; then
        echo "ERROR: 'down' destroys ALL infrastructure — it does not accept a username." >&2
        echo "       To remove one user's instance: ./admin.sh remove-user ${USERNAME} && ./admin.sh up" >&2
        exit 1
      fi
      docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/down.sh
      ;;
    add-user)
      if [[ -n "${USERNAME}" ]]; then
        docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" \
          /workspace/scripts/add-user.sh "/workspace/${USERNAME}"
      else
        docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/add-user.sh
      fi
      ;;
    remove-user)
      require_username
      docker run "${DOCKER_ARGS[@]}" \
        --env "DEV_USERNAME=${USERNAME}" \
        "${IMAGE_NAME}" /workspace/scripts/remove-user.sh
      ;;
    update-user-key)
      require_username
      docker run "${DOCKER_ARGS[@]}" \
        --env "DEV_USERNAME=${USERNAME}" \
        "${IMAGE_NAME}" /workspace/scripts/update-user-key.sh
      ;;
    start)
      if [[ -n "${USERNAME}" ]]; then
        docker run "${DOCKER_ARGS[@]}" \
          --env "DEV_USERNAME=${USERNAME}" \
          "${IMAGE_NAME}" /workspace/scripts/start.sh
      else
        CONFIGURED_USERS=$(docker run "${DOCKER_ARGS_QUIET[@]}" "${IMAGE_NAME}" /workspace/scripts/list-users.sh)
        if [[ -z "${CONFIGURED_USERS}" ]]; then
          echo "No users registered. Run './admin.sh add-user' first." >&2; exit 1
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
        CONFIGURED_USERS=$(docker run "${DOCKER_ARGS_QUIET[@]}" "${IMAGE_NAME}" /workspace/scripts/list-users.sh)
        if [[ -z "${CONFIGURED_USERS}" ]]; then
          echo "No users registered. Run './admin.sh add-user' first." >&2; exit 1
        fi
        for user in ${CONFIGURED_USERS}; do
          docker run "${DOCKER_ARGS[@]}" --env "DEV_USERNAME=${user}" "${IMAGE_NAME}" /workspace/scripts/stop.sh
        done
      fi
      ;;
    connect)
      require_username
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
        --env "AWS_PROFILE=claude-code-dev" \
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
        --env "AWS_PROFILE=${AWS_PROFILE}" \
        "${IMAGE_NAME}" /workspace/scripts/refresh.sh
      ;;
    ssm)
      require_username
      docker run "${DOCKER_ARGS[@]}" \
        --env "DEV_USERNAME=${USERNAME}" \
        "${IMAGE_NAME}" /workspace/scripts/ssm.sh
      ;;
    publish-installer)
      require_username
      docker run "${DOCKER_ARGS[@]}" \
        --env "DEV_USERNAME=${USERNAME}" \
        "${IMAGE_NAME}" /workspace/scripts/publish-installer.sh
      ;;
    build)
      docker build -t "${IMAGE_NAME}" "$(dirname "$0")"
      ;;
    test)
      docker run "${DOCKER_ARGS[@]}" \
        --volume "$(pwd)/tests:/workspace/tests" \
        "${IMAGE_NAME}" bats /workspace/tests/bats/
      ;;
    shell)
      docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /bin/bash -c '
        source /workspace/config/admin.env 2>/dev/null || true
        source /workspace/config/backend.env  2>/dev/null || true
        eval "$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env-no-export 2>/dev/null | sed '"'"'s/^/export /'"'"')" || true
        exec /bin/bash
      '
      ;;
    *)
      echo "Unknown command: ${COMMAND}" >&2
      echo "Run './admin.sh --help' for usage." >&2
      exit 1
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# User dispatch
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "user" ]]; then
  case "${COMMAND}" in
    sso-login)
      if [[ "${FRESH_CREDS:-false}" == "true" ]]; then
        echo "Clearing credential cache..."
        rm -f "${HOME}/.aws/cli/cache/"* 2>/dev/null || true
      fi
      docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" \
        aws sso login --use-device-code --profile "${AWS_PROFILE}"
      ;;
    verify)
      docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/verify.sh
      ;;
    start)
      docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/start.sh
      ;;
    stop)
      docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/stop.sh
      ;;
    connect)
      FRE_CLAUDE_KEY="${HOME}/.ssh/fre-claude"
      if [[ ! -f "${FRE_CLAUDE_KEY}" ]]; then
        echo "ERROR: SSH key not found at ~/.ssh/fre-claude" >&2
        echo "       Follow the SSH Key Setup section in README-user.md" >&2
        exit 1
      fi
      CONNECT_ARGS=("${DOCKER_ARGS[@]}")
      CONNECT_ARGS+=("--volume" "${HOME}/.ssh:/root/.ssh:ro")
      [[ -n "${GIT_USER_NAME:-}" ]]  && CONNECT_ARGS+=("--env" "GIT_USER_NAME=${GIT_USER_NAME}")
      [[ -n "${GIT_USER_EMAIL:-}" ]] && CONNECT_ARGS+=("--env" "GIT_USER_EMAIL=${GIT_USER_EMAIL}")
      docker run "${CONNECT_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/connect.sh
      ;;
    update)
      docker run "${DOCKER_ARGS[@]}" \
        --volume "${USER_SCRIPT_DIR}:/workspace/fre-aws" \
        "${IMAGE_NAME}" /workspace/scripts/update.sh
      ;;
    *)
      echo "Unknown command: ${COMMAND}" >&2
      echo "Run './user.sh --help' for usage." >&2
      exit 1
      ;;
  esac
fi
