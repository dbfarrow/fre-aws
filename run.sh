#!/usr/bin/env bash
# run.sh — Unified dispatch script for the fre-aws Claude Code environment.
#
# Invoke as admin.sh or user.sh (symlinks):
#   ./admin.sh <command> [username]
#   ./user.sh  <command> [config]
#
# Both symlinks point here; mode is detected via basename.
set -euo pipefail

# Derive image name from PROJECT_NAME in admin.env.
# Falls back to "fre-aws" only if admin.env doesn't exist yet (repo cloned but not configured).
IMAGE_NAME="fre-aws"
_REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${_REPO_DIR}/config/admin.env" ]]; then
  _PN=$(grep -m1 -E '^PROJECT_NAME=' "${_REPO_DIR}/config/admin.env" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs 2>/dev/null || true)
  [[ -n "${_PN}" ]] && IMAGE_NAME="${_PN}"
  unset _PN
fi
unset _REPO_DIR
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
  add-user [file] [--no-email]
                        Interactive wizard to add a new user; optionally load
                        from a file. --no-email skips the onboarding email
                        and prints the installer URL instead.
  remove-user <user> [--keep-sso]
                        Destroy a user's EC2 instance and remove them from
                        the registry. --keep-sso preserves the IAM Identity
                        Center account so the user can be re-added without
                        AWS account setup.
  update-user-key <user>
                        Replace a user's SSH public key
  stat                  Show environment config, cost profile, and user/instance summary
  list [-v|--verbose]   List users and their instance state
                        -v shows all registry attributes (email, role, git, ssh key)

infrastructure:
  bootstrap [--plan] [--yes] [--profile <name>] [--region <region>]
                        One-time setup (S3, DynamoDB, SES verification,
                        IAM Identity Center permission sets).
                        --plan    Show what will be created without making changes.
                        --yes     Skip the confirmation prompt.
                        --profile Use a named AWS profile instead of admin.env.
                        --region  Override the deploy region from admin.env.
  configure             Second-admin onboarding: validate local admin.env against
                        canonical S3 settings and regenerate config/backend.env.
                        Run this after the super-admin has bootstrapped the project.
  up [user]             Create / update base infrastructure + all users (or just one user)
  down <user>           Destroy one user's instance (base infrastructure preserved)
  down --all            Destroy all users + base infrastructure (full teardown)
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
  push-admin-keys [user]
                        Append admin SSH key to authorized_keys on one or all
                        running instances (idempotent, uses SSM — no SSH needed)

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
  publish-installer <user> [--no-email]
                        Re-generate installer bundle for a user, upload to
                        S3, and print a new 72-hour pre-signed URL.
                        --no-email skips sending and prints the URL only.

browser app:
  publish-app-link <user> [--no-email]
                        Generate a 72-hour signed magic link for the browser
                        app and optionally send it via email.
                        --no-email skips sending and prints the URL only.
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

file sharing:
  upload <file-or-dir> [project]
                        Upload a file or directory to ~/uploads/<project>/
                        on your EC2 instance. Directories are synced with
                        rsync — only changed files are transferred. If
                        project is omitted, a menu of your repos is shown.

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
if ! docker info &>/dev/null; then
  echo "ERROR: Docker daemon is not running or not responding." >&2
  echo "       Start Docker Desktop (or OrbStack/Rancher Desktop) and try again." >&2
  exit 1
fi
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

  # Detect host timezone for passing into containers (for human-readable timestamps)
  _HOST_TZ=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || true)
  [[ -z "${_HOST_TZ}" && -f /etc/timezone ]] && _HOST_TZ=$(cat /etc/timezone 2>/dev/null || true)
  _HOST_TZ="${_HOST_TZ:-UTC}"

  DOCKER_ARGS=(
    "--rm"
    "--interactive"
    "--tty"
    "--env" "AWS_PAGER="
    "--env" "SENDER_EMAIL=${SENDER_EMAIL:-}"
    "--env" "SSO_START_URL=${SSO_START_URL:-}"
    "--env" "TZ=${_HOST_TZ}"
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
    "--env" "TZ=${_HOST_TZ}"
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

  # Detect the admin's SSH key: SSH_KEY_FILE from admin.env → id_ed25519 → id_rsa
  _detect_admin_ssh_key() {
    local key=""
    if [[ -n "${SSH_KEY_FILE:-}" ]]; then
      [[ "${SSH_KEY_FILE}" == /* ]] && key="${SSH_KEY_FILE}" || key="${HOME}/.ssh/${SSH_KEY_FILE}"
    elif [[ -f "${HOME}/.ssh/id_ed25519" ]]; then
      key="${HOME}/.ssh/id_ed25519"
    elif [[ -f "${HOME}/.ssh/id_rsa" ]]; then
      key="${HOME}/.ssh/id_rsa"
    fi
    echo "${key}"
  }

  # Detect a usable SSH agent socket to forward into the Docker container.
  # Prefers SSH_AUTH_SOCK (works on Mac with OrbStack, on Linux, and on WSL2
  # when an ssh-agent is running). Falls back to Docker Desktop for Mac's host
  # bridge socket (/run/host-services/ssh-auth.sock). On WSL2 without a running
  # agent, neither path is found and the empty return triggers the key-file
  # fallback in the caller (mounts ~/.ssh and prompts for passphrase).
  _detect_ssh_agent_sock() {
    if [[ -S "${SSH_AUTH_SOCK:-}" ]]; then
      echo "${SSH_AUTH_SOCK}"
    elif [[ -S "/run/host-services/ssh-auth.sock" ]]; then
      echo "/run/host-services/ssh-auth.sock"
    else
      echo ""
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

  # upload uses $2 as the file/directory to transfer, not a config override
  [[ "${COMMAND}" == "upload" ]] && CONFIG_ARG=""

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

  # Use a local .aws/ next to user.sh when it exists (created by install.sh),
  # otherwise fall back to ~/.aws (admin testing from the repo).
  if [[ -d "${USER_SCRIPT_DIR}/.aws" ]]; then
    USER_AWS_DIR="${USER_SCRIPT_DIR}/.aws"
  else
    USER_AWS_DIR="${HOME}/.aws"
  fi

  DOCKER_ARGS=(
    "--rm"
    "--interactive"
    "--tty"
    "--env" "AWS_PAGER="
    "--env" "DEV_USERNAME=${MY_USERNAME}"
    "--volume" "${USER_AWS_DIR}:/root/.aws"
    "--volume" "${DEV_CONFIG}:/workspace/config/user.env:ro"
    "--volume" "${USER_SCRIPT_DIR}/scripts:/workspace/scripts"
  )

  # Append SSH auth options to CONNECT_ARGS (caller must initialise it first).
  # Prefers a running ssh-agent; falls back to key files in priority order.
  _setup_user_ssh_auth() {
    local user_ssh_dir="${USER_SCRIPT_DIR}/.ssh"
    if [[ -S "${SSH_AUTH_SOCK:-}" ]]; then
      CONNECT_ARGS+=(
        "--volume" "${SSH_AUTH_SOCK}:/tmp/ssh-agent.sock"
        "--env" "SSH_AUTH_SOCK=/tmp/ssh-agent.sock"
      )
    elif [[ -S "/run/host-services/ssh-auth.sock" ]]; then
      CONNECT_ARGS+=(
        "--volume" "/run/host-services/ssh-auth.sock:/tmp/ssh-agent.sock"
        "--env" "SSH_AUTH_SOCK=/tmp/ssh-agent.sock"
      )
    elif [[ -f "${user_ssh_dir}/fre-claude" ]]; then
      CONNECT_ARGS+=(
        "--volume" "${user_ssh_dir}:/root/.ssh:ro"
        "--env" "SSH_KEY_FILE=/root/.ssh/fre-claude"
        "--env" "SSH_KEY_PASSPHRASE_SECRET=${PROJECT_NAME}/${MY_USERNAME}/ssh-key-passphrase"
      )
    elif [[ -f "${HOME}/.ssh/id_ed25519" ]]; then
      CONNECT_ARGS+=(
        "--volume" "${HOME}/.ssh:/root/.ssh:ro"
        "--env" "SSH_KEY_FILE=/root/.ssh/id_ed25519"
      )
    elif [[ -f "${HOME}/.ssh/id_rsa" ]]; then
      CONNECT_ARGS+=(
        "--volume" "${HOME}/.ssh:/root/.ssh:ro"
        "--env" "SSH_KEY_FILE=/root/.ssh/id_rsa"
      )
    else
      echo "ERROR: No SSH key or agent found." >&2
      echo "       Checked: ssh-agent (SSH_AUTH_SOCK)" >&2
      echo "                ${user_ssh_dir}/fre-claude" >&2
      echo "                ~/.ssh/id_ed25519" >&2
      echo "                ~/.ssh/id_rsa" >&2
      echo "       Ask your admin to regenerate your installer bundle." >&2
      exit 1
    fi
  }
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
      BOOTSTRAP_PROFILE=""
      BOOTSTRAP_REGION=""
      BOOTSTRAP_ARGS=()
      _skip_next=""
      for _arg in "${@:2}"; do
        if [[ -n "${_skip_next}" ]]; then
          case "${_skip_next}" in
            profile) BOOTSTRAP_PROFILE="${_arg}" ;;
            region)  BOOTSTRAP_REGION="${_arg}" ;;
          esac
          _skip_next=""
          continue
        fi
        case "${_arg}" in
          --profile)    _skip_next=profile ;;
          --profile=*)  BOOTSTRAP_PROFILE="${_arg#--profile=}" ;;
          --region)     _skip_next=region ;;
          --region=*)   BOOTSTRAP_REGION="${_arg#--region=}" ;;
          --plan|--dry-run|--yes|-y) BOOTSTRAP_ARGS+=("${_arg}") ;;
        esac
      done
      docker run "${DOCKER_ARGS[@]}" \
        --env "BOOTSTRAP_PROFILE_OVERRIDE=${BOOTSTRAP_PROFILE}" \
        --env "BOOTSTRAP_REGION_OVERRIDE=${BOOTSTRAP_REGION}" \
        "${IMAGE_NAME}" /workspace/scripts/bootstrap.sh "${BOOTSTRAP_ARGS[@]}"
      ;;
    configure)
      docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/configure.sh
      ;;
    up)
      ADMIN_SSH_PUB_KEY=""
      HOST_SSH_KEY=$(_detect_admin_ssh_key)
      if [[ -n "${HOST_SSH_KEY}" && -f "${HOST_SSH_KEY}.pub" ]]; then
        ADMIN_SSH_PUB_KEY=$(cat "${HOST_SSH_KEY}.pub")
      fi
      docker run "${DOCKER_ARGS[@]}" \
        --env "ADMIN_SSH_PUB_KEY=${ADMIN_SSH_PUB_KEY}" \
        "${IMAGE_NAME}" /workspace/scripts/up.sh "${USERNAME:-}"
      ;;
    down)
      if [[ -z "${USERNAME}" ]]; then
        echo "Usage: admin.sh down <username>        destroy one user's instance" >&2
        echo "       admin.sh down --all             destroy all users + base infrastructure" >&2
        exit 1
      elif [[ "${USERNAME}" == "--all" ]]; then
        docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/down.sh
      else
        docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/down.sh "${USERNAME}"
      fi
      ;;
    add-user)
      NO_EMAIL_FLAG=""
      [[ "${2:-}" == "--no-email" || "${3:-}" == "--no-email" ]] && NO_EMAIL_FLAG="true"
      if [[ -n "${USERNAME}" && "${USERNAME}" != "--no-email" ]]; then
        docker run "${DOCKER_ARGS[@]}" --env "NO_EMAIL_SEND=${NO_EMAIL_FLAG}" \
          "${IMAGE_NAME}" /workspace/scripts/add-user.sh "/workspace/${USERNAME}"
      else
        docker run "${DOCKER_ARGS[@]}" --env "NO_EMAIL_SEND=${NO_EMAIL_FLAG}" \
          "${IMAGE_NAME}" /workspace/scripts/add-user.sh
      fi
      ;;
    remove-user)
      require_username
      KEEP_SSO_FLAG=""
      [[ "${3:-}" == "--keep-sso" ]] && KEEP_SSO_FLAG="true"
      docker run "${DOCKER_ARGS[@]}" \
        --env "DEV_USERNAME=${USERNAME}" \
        --env "KEEP_SSO_USER=${KEEP_SSO_FLAG}" \
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
      # Determine the profile for connect (developer-access, not admin-access).
      # Priority: explicit CONNECT_PROFILE > derived from AWS_PROFILE > default creds.
      # External mode: use AWS_PROFILE directly (org profile already has SSM access).
      # Managed mode: append -dev to AWS_PROFILE, but only if AWS_PROFILE is set.
      if [[ -n "${CONNECT_PROFILE:-}" ]]; then
        _CONNECT_PROFILE="${CONNECT_PROFILE}"
      elif [[ "${IDENTITY_MODE:-managed}" == "external" ]]; then
        _CONNECT_PROFILE="${AWS_PROFILE:-}"
      elif [[ -n "${AWS_PROFILE:-}" ]]; then
        _CONNECT_PROFILE="${AWS_PROFILE}-dev"
      else
        _CONNECT_PROFILE=""
      fi
      # Only inject AWS_PROFILE into the container if we resolved a profile.
      # Empty means: use default credential chain inside the container.
      _CONNECT_PROFILE_ARG=()
      [[ -n "${_CONNECT_PROFILE}" ]] && _CONNECT_PROFILE_ARG=("--env" "AWS_PROFILE=${_CONNECT_PROFILE}")
      AGENT_SOCK=$(_detect_ssh_agent_sock)
      if [[ -n "${AGENT_SOCK}" ]]; then
        # Agent forwarding: mount host ssh-agent socket into container — no key file or passphrase needed.
        docker run "${DOCKER_ARGS[@]}" \
          --publish "${WEB_PREVIEW_PORT:-8080}:${WEB_PREVIEW_PORT:-8080}" \
          --volume "${AGENT_SOCK}:/tmp/ssh-agent.sock" \
          --env "SSH_AUTH_SOCK=/tmp/ssh-agent.sock" \
          --env "DEV_USERNAME=${USERNAME}" \
          "${_CONNECT_PROFILE_ARG[@]}" \
          "${IMAGE_NAME}" /workspace/scripts/connect.sh
      else
        # Key file fallback: start fresh agent inside container, prompt for passphrase.
        HOST_SSH_KEY=$(_detect_admin_ssh_key)
        if [[ -z "${HOST_SSH_KEY}" || ! -f "${HOST_SSH_KEY}" ]]; then
          echo "ERROR: No SSH key found and no SSH agent running." >&2
          echo "       Load your key first: ssh-add ~/.ssh/id_ed25519" >&2
          echo "       Or create a key:     ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519" >&2
          exit 1
        fi
        CONTAINER_SSH_KEY="/root/.ssh/$(basename "${HOST_SSH_KEY}")"
        docker run "${DOCKER_ARGS[@]}" \
          --publish "${WEB_PREVIEW_PORT:-8080}:${WEB_PREVIEW_PORT:-8080}" \
          --volume "${HOME}/.ssh:/root/.ssh:ro" \
          --env "DEV_USERNAME=${USERNAME}" \
          "${_CONNECT_PROFILE_ARG[@]}" \
          --env "SSH_KEY_FILE=${CONTAINER_SSH_KEY}" \
          "${IMAGE_NAME}" /workspace/scripts/connect.sh
      fi
      ;;
    refresh)
      require_username
      AGENT_SOCK=$(_detect_ssh_agent_sock)
      if [[ -n "${AGENT_SOCK}" ]]; then
        docker run "${DOCKER_ARGS[@]}" \
          --volume "${AGENT_SOCK}:/tmp/ssh-agent.sock" \
          --env "SSH_AUTH_SOCK=/tmp/ssh-agent.sock" \
          --env "DEV_USERNAME=${USERNAME}" \
          --env "AWS_PROFILE=${AWS_PROFILE}" \
          "${IMAGE_NAME}" /workspace/scripts/refresh.sh
      else
        HOST_SSH_KEY=$(_detect_admin_ssh_key)
        if [[ -z "${HOST_SSH_KEY}" || ! -f "${HOST_SSH_KEY}" ]]; then
          echo "ERROR: No SSH key found and no SSH agent running." >&2
          echo "       Load your key first: ssh-add ~/.ssh/id_ed25519" >&2
          echo "       Or create a key:     ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519" >&2
          exit 1
        fi
        CONTAINER_SSH_KEY="/root/.ssh/$(basename "${HOST_SSH_KEY}")"
        docker run "${DOCKER_ARGS[@]}" \
          --volume "${HOME}/.ssh:/root/.ssh:ro" \
          --env "DEV_USERNAME=${USERNAME}" \
          --env "AWS_PROFILE=${AWS_PROFILE}" \
          --env "SSH_KEY_FILE=${CONTAINER_SSH_KEY}" \
          "${IMAGE_NAME}" /workspace/scripts/refresh.sh
      fi
      ;;
    ssm)
      require_username
      docker run "${DOCKER_ARGS[@]}" \
        --env "DEV_USERNAME=${USERNAME}" \
        "${IMAGE_NAME}" /workspace/scripts/ssm.sh
      ;;
    publish-installer)
      require_username
      NO_EMAIL_FLAG=""
      [[ "${3:-}" == "--no-email" ]] && NO_EMAIL_FLAG="true"
      docker run "${DOCKER_ARGS[@]}" \
        --env "DEV_USERNAME=${USERNAME}" \
        --env "NO_EMAIL_SEND=${NO_EMAIL_FLAG}" \
        "${IMAGE_NAME}" /workspace/scripts/publish-installer.sh
      ;;
    publish-app-link)
      require_username
      NO_EMAIL_FLAG=""
      [[ "${3:-}" == "--no-email" ]] && NO_EMAIL_FLAG="true"
      docker run "${DOCKER_ARGS[@]}" \
        --env "DEV_USERNAME=${USERNAME}" \
        --env "NO_EMAIL_SEND=${NO_EMAIL_FLAG}" \
        "${IMAGE_NAME}" /workspace/scripts/publish-app-link.sh
      ;;
    push-admin-keys)
      HOST_SSH_KEY=$(_detect_admin_ssh_key)
      if [[ -z "${HOST_SSH_KEY}" || ! -f "${HOST_SSH_KEY}" ]]; then
        echo "ERROR: No SSH key found." >&2
        echo "       Create one: ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519" >&2
        exit 1
      fi
      if [[ ! -f "${HOST_SSH_KEY}.pub" ]]; then
        echo "ERROR: No public key found at ${HOST_SSH_KEY}.pub" >&2
        echo "       Generate it: ssh-keygen -y -f ${HOST_SSH_KEY} > ${HOST_SSH_KEY}.pub" >&2
        exit 1
      fi
      ADMIN_SSH_PUB_KEY=$(cat "${HOST_SSH_KEY}.pub")
      docker run "${DOCKER_ARGS[@]}" \
        --env "DEV_USERNAME=${USERNAME}" \
        --env "ADMIN_SSH_PUB_KEY=${ADMIN_SSH_PUB_KEY}" \
        "${IMAGE_NAME}" /workspace/scripts/push-admin-keys.sh
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
        set -a
        source /workspace/config/admin.env 2>/dev/null || true
        source /workspace/config/backend.env 2>/dev/null || true
        set +a
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
        rm -f "${USER_AWS_DIR}/cli/cache/"* 2>/dev/null || true
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
      CONNECT_ARGS=("${DOCKER_ARGS[@]}")
      _setup_user_ssh_auth
      [[ -n "${GIT_USER_NAME:-}"  ]] && CONNECT_ARGS+=("--env" "GIT_USER_NAME=${GIT_USER_NAME}")
      [[ -n "${GIT_USER_EMAIL:-}" ]] && CONNECT_ARGS+=("--env" "GIT_USER_EMAIL=${GIT_USER_EMAIL}")
      CONNECT_ARGS+=("--publish" "${WEB_PREVIEW_PORT:-8080}:${WEB_PREVIEW_PORT:-8080}")
      docker run "${CONNECT_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/connect.sh
      ;;
    upload)
      LOCAL_FILE="${2:-}"
      if [[ -z "${LOCAL_FILE}" ]]; then
        echo "Usage: user.sh upload <local-file> [project-name]" >&2
        exit 1
      fi
      [[ "${LOCAL_FILE}" != /* ]] && LOCAL_FILE="$(pwd)/${LOCAL_FILE}"
      if [[ ! -e "${LOCAL_FILE}" ]]; then
        echo "ERROR: File or directory not found: ${LOCAL_FILE}" >&2
        exit 1
      fi
      CONNECT_ARGS=("${DOCKER_ARGS[@]}")
      _setup_user_ssh_auth
      CONNECT_ARGS+=(
        "--volume" "${LOCAL_FILE}:${LOCAL_FILE}:ro"
        "--env" "UPLOAD_FILE=${LOCAL_FILE}"
        "--env" "UPLOAD_PROJECT=${3:-}"
      )
      docker run "${CONNECT_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/upload.sh
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
