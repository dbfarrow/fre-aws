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
  pull-user <user>      Download a user's registry entry to config/users/<user>.env
  update-user [file]    Update a user's registry entry from a local .env file
                        (does not touch Identity Center, bundles, or running instances)

infrastructure:
  bootstrap [--plan] [--yes] [--profile <name>] [--region <region>]
                        One-time setup (S3, DynamoDB, SES verification,
                        IAM Identity Center permission sets).
                        --plan    Show what will be created without making changes.
                        --yes     Skip the confirmation prompt.
                        --profile Use a named AWS profile instead of admin.env.
                        --region  Override the deploy region from admin.env.
  configure [--fix-drift]
                        Second-admin onboarding: validate local admin.env against
                        canonical S3 settings and regenerate config/backend.env.
                        Run this after the super-admin has bootstrapped the project.
                        --fix-drift  Apply canonical values back to local admin.env
                                     (shows a diff and prompts for confirmation first).
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
  refresh <user>        Push system config (session_start.sh, autoshutdown, profile guard)
                        to a running instance. Does not touch user dotfiles.
  push-config <user>    Push personal dotfiles from the host to a user's instance.
                        Looks for: ~/.tmux.conf  ~/.bashrc  ~/.zshrc  ~/.vimrc
                        Missing files are skipped. Does not touch ~/.bash_profile
                        or ~/.zprofile.
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
  run <project> <script> [--mount local:container] [--env-file file] [-- args...]
                        Download a project from EC2, run it locally in
                        Docker, and upload the output back to EC2 as
                        ~/uploads/<project>/run-output.txt. Requires Docker
                        to be running. Tell Claude "done" after it completes.
  local-shell <project> [--verbose]
                        Drop into a persistent local shell scoped to a
                        project. csync pulls the current state from EC2;
                        cpush uploads output back for Claude to read.
                        --verbose prints the full docker command before launch.
                        Config: LOCAL_SYNC_DIR (default: ~/claude)
                                LOCAL_MOUNTS_<project>=host:container ...

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

  # Corporate CA cert — mount into container for SSL inspection environments.
  # entrypoint.sh installs it into the OS trust store on every container start.
  if [[ -n "${CORP_CA_CERT_FILE:-}" ]]; then
    _CA_PATH="${CORP_CA_CERT_FILE}"
    [[ "${_CA_PATH}" != /* ]] && _CA_PATH="$(pwd)/${_CA_PATH}"
    if [[ -f "${_CA_PATH}" ]]; then
      DOCKER_ARGS+=("--volume" "${_CA_PATH}:/certs/corp-ca.crt:ro")
      DOCKER_ARGS_QUIET+=("--volume" "${_CA_PATH}:/certs/corp-ca.crt:ro")
    else
      echo "WARNING: CORP_CA_CERT_FILE='${CORP_CA_CERT_FILE}' not found — skipping cert install" >&2
    fi
    unset _CA_PATH
  fi

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

  # upload, run, and local-shell use $2 as command arguments, not a config override
  [[ "${COMMAND}" == "upload" || "${COMMAND}" == "run" || "${COMMAND}" == "local-shell" ]] && CONFIG_ARG=""

  if [[ -n "${CONFIG_ARG}" ]]; then
    DEV_CONFIG="${CONFIG_ARG}"
    # Resolve relative paths against cwd
    [[ "${DEV_CONFIG}" != /* ]] && DEV_CONFIG="$(pwd)/${CONFIG_ARG}"
  else
    DEV_CONFIG="${USER_SCRIPT_DIR}/config/user.env"
    # Fall back to admin.env when user.env doesn't exist (admin testing user commands)
    if [[ ! -f "${DEV_CONFIG}" && -f "${USER_SCRIPT_DIR}/config/admin.env" ]]; then
      DEV_CONFIG="${USER_SCRIPT_DIR}/config/admin.env"
    fi
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

  # Corporate CA cert — mount into container for SSL inspection environments.
  if [[ -n "${CORP_CA_CERT_FILE:-}" ]]; then
    _CA_PATH="${CORP_CA_CERT_FILE}"
    [[ "${_CA_PATH}" != /* ]] && _CA_PATH="${USER_SCRIPT_DIR}/${_CA_PATH}"
    if [[ -f "${_CA_PATH}" ]]; then
      DOCKER_ARGS+=("--volume" "${_CA_PATH}:/certs/corp-ca.crt:ro")
    else
      echo "WARNING: CORP_CA_CERT_FILE='${CORP_CA_CERT_FILE}' not found — skipping cert install" >&2
    fi
    unset _CA_PATH
  fi

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
# Stale config detection helper
# Sets _DO_PUSH=false; if tracked dotfiles are newer than the last push timestamp,
# prints them and prompts the user; sets _DO_PUSH=true if confirmed.
# ---------------------------------------------------------------------------
_stale_push_check() {
  local username="$1" config_dir="$2"
  _DO_PUSH=false
  local timestamp_file="${config_dir}/.last-push-${username}"
  local tracked=()
  for f in "${HOME}/.tmux.conf" "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.vimrc" "${HOME}/.fre-aws"; do
    [[ -f "${f}" ]] && tracked+=("${f}")
  done
  [[ ${#tracked[@]} -eq 0 ]] && return 0
  _STALE_FILES=()
  if [[ ! -f "${timestamp_file}" ]]; then
    _STALE_FILES=("${tracked[@]}")
  else
    for f in "${tracked[@]}"; do
      [[ "${f}" -nt "${timestamp_file}" ]] && _STALE_FILES+=("${f}")
    done
  fi
  [[ ${#_STALE_FILES[@]} -eq 0 ]] && return 0
  echo "Config files changed since last push to '${username}':"
  for f in "${_STALE_FILES[@]}"; do printf "  %s\n" "$(basename "${f}")"; done
  echo ""
  read -r -p "Push config before connecting? [y/N] " _push_confirm
  echo ""
  [[ "${_push_confirm}" =~ ^[Yy]$ ]] && _DO_PUSH=true
}

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
      if [[ -n "${AWS_PROFILE:-}" ]]; then
        echo "Logging in with profile '${AWS_PROFILE}'..."
      else
        echo "Logging in with default credentials..."
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
      docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" /workspace/scripts/configure.sh "${@:2}"
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
    pull-user)
      require_username
      docker run "${DOCKER_ARGS[@]}" \
        --env "DEV_USERNAME=${USERNAME}" \
        "${IMAGE_NAME}" /workspace/scripts/pull-user.sh
      ;;
    update-user)
      if [[ -z "${USERNAME}" ]]; then
        echo "Usage: admin.sh update-user <file.env>" >&2
        exit 1
      fi
      docker run "${DOCKER_ARGS[@]}" \
        "${IMAGE_NAME}" /workspace/scripts/update-user.sh "/workspace/${USERNAME}"
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
      if [[ "${USERNAME}" == "${MY_USERNAME:-}" ]]; then
        _stale_push_check "${USERNAME}" "$(pwd)/config"
        if [[ "${_DO_PUSH}" == true ]]; then
          _PUSH_CFG_ARGS=()
          for _f in "${_STALE_FILES[@]}"; do
            _fname="$(basename "${_f}")"; _PUSH_CFG_ARGS+=("--volume" "${_f}:/host-configs/${_fname#.}:ro")
          done
          if [[ -n "${AGENT_SOCK}" ]]; then
            docker run "${DOCKER_ARGS[@]}" "${_PUSH_CFG_ARGS[@]}" \
              --volume "${AGENT_SOCK}:/tmp/ssh-agent.sock" \
              --env "SSH_AUTH_SOCK=/tmp/ssh-agent.sock" \
              --env "DEV_USERNAME=${USERNAME}" \
              --env "AWS_PROFILE=${AWS_PROFILE}" \
              "${IMAGE_NAME}" /workspace/scripts/push-config.sh \
            && touch "$(pwd)/config/.last-push-${USERNAME}"
          else
            docker run "${DOCKER_ARGS[@]}" "${_PUSH_CFG_ARGS[@]}" \
              --env "DEV_USERNAME=${USERNAME}" \
              --env "AWS_PROFILE=${AWS_PROFILE}" \
              "${IMAGE_NAME}" /workspace/scripts/push-config.sh \
            && touch "$(pwd)/config/.last-push-${USERNAME}"
          fi
          echo ""
        fi
      fi
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
    push-config)
      require_username
      AGENT_SOCK=$(_detect_ssh_agent_sock)
      _PUSH_CFG_ARGS=()
      [[ -f "${HOME}/.tmux.conf" ]] && _PUSH_CFG_ARGS+=("--volume" "${HOME}/.tmux.conf:/host-configs/tmux.conf:ro")
      [[ -f "${HOME}/.bashrc"   ]] && _PUSH_CFG_ARGS+=("--volume" "${HOME}/.bashrc:/host-configs/bashrc:ro")
      [[ -f "${HOME}/.zshrc"    ]] && _PUSH_CFG_ARGS+=("--volume" "${HOME}/.zshrc:/host-configs/zshrc:ro")
      [[ -f "${HOME}/.vimrc"    ]] && _PUSH_CFG_ARGS+=("--volume" "${HOME}/.vimrc:/host-configs/vimrc:ro")
      [[ -f "${HOME}/.fre-aws"  ]] && _PUSH_CFG_ARGS+=("--volume" "${HOME}/.fre-aws:/host-configs/fre-aws:ro")
      if [[ -n "${AGENT_SOCK}" ]]; then
        docker run "${DOCKER_ARGS[@]}" "${_PUSH_CFG_ARGS[@]}" \
          --volume "${AGENT_SOCK}:/tmp/ssh-agent.sock" \
          --env "SSH_AUTH_SOCK=/tmp/ssh-agent.sock" \
          --env "DEV_USERNAME=${USERNAME}" \
          --env "AWS_PROFILE=${AWS_PROFILE}" \
          "${IMAGE_NAME}" /workspace/scripts/push-config.sh \
        && touch "$(pwd)/config/.last-push-${USERNAME}"
      else
        docker run "${DOCKER_ARGS[@]}" "${_PUSH_CFG_ARGS[@]}" \
          --env "DEV_USERNAME=${USERNAME}" \
          --env "AWS_PROFILE=${AWS_PROFILE}" \
          "${IMAGE_NAME}" /workspace/scripts/push-config.sh \
        && touch "$(pwd)/config/.last-push-${USERNAME}"
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
      if [[ -n "${AWS_PROFILE:-}" ]]; then
        echo "Logging in with profile '${AWS_PROFILE}'..."
      else
        echo "Logging in with default credentials..."
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
      _stale_push_check "${MY_USERNAME}" "${USER_SCRIPT_DIR}/config"
      if [[ "${_DO_PUSH}" == true ]]; then
        _PUSH_CFG_ARGS=()
        for _f in "${_STALE_FILES[@]}"; do
          _fname="$(basename "${_f}")"; _PUSH_CFG_ARGS+=("--volume" "${_f}:/host-configs/${_fname#.}:ro")
        done
        PUSH_ARGS=("${DOCKER_ARGS[@]}" "${_PUSH_CFG_ARGS[@]}")
        if [[ -S "${SSH_AUTH_SOCK:-}" ]]; then
          PUSH_ARGS+=("--volume" "${SSH_AUTH_SOCK}:/tmp/ssh-agent.sock" "--env" "SSH_AUTH_SOCK=/tmp/ssh-agent.sock")
        elif [[ -S "/run/host-services/ssh-auth.sock" ]]; then
          PUSH_ARGS+=("--volume" "/run/host-services/ssh-auth.sock:/tmp/ssh-agent.sock" "--env" "SSH_AUTH_SOCK=/tmp/ssh-agent.sock")
        elif [[ -f "${USER_SCRIPT_DIR}/.ssh/fre-claude" ]]; then
          PUSH_ARGS+=("--volume" "${USER_SCRIPT_DIR}/.ssh:/root/.ssh:ro" "--env" "SSH_KEY_FILE=/root/.ssh/fre-claude" "--env" "SSH_KEY_PASSPHRASE_SECRET=${PROJECT_NAME}/${MY_USERNAME}/ssh-key-passphrase")
        elif [[ -f "${HOME}/.ssh/id_ed25519" ]]; then
          PUSH_ARGS+=("--volume" "${HOME}/.ssh:/root/.ssh:ro" "--env" "SSH_KEY_FILE=/root/.ssh/id_ed25519")
        elif [[ -f "${HOME}/.ssh/id_rsa" ]]; then
          PUSH_ARGS+=("--volume" "${HOME}/.ssh:/root/.ssh:ro" "--env" "SSH_KEY_FILE=/root/.ssh/id_rsa")
        fi
        docker run "${PUSH_ARGS[@]}" \
          --env "DEV_USERNAME=${MY_USERNAME}" \
          "${IMAGE_NAME}" /workspace/scripts/push-config.sh \
        && touch "${USER_SCRIPT_DIR}/config/.last-push-${MY_USERNAME}"
        echo ""
      fi
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
    run)
      RUN_PROJECT="${2:-}"
      RUN_SCRIPT="${3:-}"
      [[ -z "${RUN_PROJECT}" || -z "${RUN_SCRIPT}" ]] && {
        echo "Usage: user.sh run <project> <script-path> [--mount local:container] [--env-file <file>] [--local] [--tty] [-- args...]" >&2
        exit 1
      }
      [[ "${RUN_SCRIPT}" == --* ]] && {
        echo "ERROR: <script-path> is required before options (got '${RUN_SCRIPT}')" >&2
        echo "Usage: user.sh run <project> <script-path> [--mount local:container] [--env-file <file>] [--local] [--tty] [-- args...]" >&2
        exit 1
      }
      if ! command -v docker >/dev/null 2>&1; then
        echo "ERROR: Docker not found." >&2
        echo "       Ensure Docker Desktop (or OrbStack/Rancher) is running." >&2
        exit 1
      fi
      RUN_MOUNT_ARGS=(); RUN_ENV_FILE_HOST=""; RUN_SCRIPT_ARGS=(); RUN_LOCAL=false; RUN_TTY=false
      _rarg_state="opts"
      for _rarg in "${@:4}"; do
        if [[ "${_rarg_state}" == "past_doubledash" ]]; then
          RUN_SCRIPT_ARGS+=("${_rarg}"); continue
        fi
        if [[ -n "${_rarg_state}" && "${_rarg_state}" != "opts" ]]; then
          case "${_rarg_state}" in
            mount)
              _h="${_rarg%%:*}"; _h="${_h/#\~/${HOME}}"; _c="${_rarg#*:}"
              RUN_MOUNT_ARGS+=("${_h}:${_c}") ;;
            env-file)
              _ep="${_rarg/#\~/${HOME}}"; [[ "${_ep}" != /* ]] && _ep="$(pwd)/${_ep}"
              [[ ! -f "${_ep}" ]] && { echo "ERROR: env-file not found: ${_rarg}" >&2; exit 1; }
              RUN_ENV_FILE_HOST="${_ep}" ;;
          esac
          _rarg_state="opts"; continue
        fi
        case "${_rarg}" in
          --) _rarg_state="past_doubledash" ;;
          --mount) _rarg_state="mount" ;;
          --env-file) _rarg_state="env-file" ;;
          --mount=*)
            _v="${_rarg#--mount=}"; _h="${_v%%:*}"; _h="${_h/#\~/${HOME}}"
            RUN_MOUNT_ARGS+=("${_h}:${_v#*:}") ;;
          --env-file=*)
            _v="${_rarg#--env-file=}"; _v="${_v/#\~/${HOME}}"
            [[ "${_v}" != /* ]] && _v="$(pwd)/${_v}"; RUN_ENV_FILE_HOST="${_v}" ;;
          --local) RUN_LOCAL=true ;;
          --tty)   RUN_TTY=true ;;
          *)
            echo "ERROR: Unknown option: ${_rarg}" >&2
            echo "Usage: user.sh run <project> <script-path> [--mount local:container] [--env-file file] [--local] [--tty] [-- args...]" >&2
            exit 1 ;;
        esac
      done
      # Stable per-project cache dir — rsync only transfers changes on repeat runs
      RUN_CACHE_DIR="${HOME}/.fre-run-cache/${RUN_PROJECT}"
      if [[ "${RUN_LOCAL}" == true && ! -d "${RUN_CACHE_DIR}" ]]; then
        echo "ERROR: No local cache found for '${RUN_PROJECT}'." >&2
        echo "       Run without --local first to download the project from EC2." >&2
        exit 1
      fi
      mkdir -p "${RUN_CACHE_DIR}"
      # Temp dir holds output.txt for this run only; cleaned up on exit
      RUN_TEMP_DIR=$(mktemp -d /tmp/fre-run-XXXXXX)
      trap 'rm -rf "${RUN_TEMP_DIR}"' EXIT

      # Base args shared by both tooling container calls (download + upload)
      CONNECT_ARGS=("${DOCKER_ARGS[@]}")
      if [[ "${RUN_LOCAL}" == false ]]; then
        _setup_user_ssh_auth
        CONNECT_ARGS+=("--env" "RUN_PROJECT=${RUN_PROJECT}")
      fi

      # Phase 1: Download project from EC2 into persistent cache (skipped with --local)
      if [[ "${RUN_LOCAL}" == false ]]; then
        docker run "${CONNECT_ARGS[@]}" \
          "--volume" "${RUN_CACHE_DIR}:/run-workspace/project/${RUN_PROJECT}" \
          "${IMAGE_NAME}" /workspace/scripts/run.sh
      else
        echo "Skipping download (--local)."
      fi

      # Phase 2: Build base image — rebuild if absent or if Dockerfile content changed.
      # Hash is stored in ~/.fre-run-cache/.fre-base-hash; any change to Dockerfile.run
      # (or bump of the inline version string) triggers an automatic rebuild.
      mkdir -p "${HOME}/.fre-run-cache"
      _base_hash_file="${HOME}/.fre-run-cache/.fre-base-hash"
      if [[ -f "${USER_SCRIPT_DIR}/Dockerfile.run" ]]; then
        _base_hash=$(cksum "${USER_SCRIPT_DIR}/Dockerfile.run" | awk '{print $1}')
      else
        _base_hash="inline-v3"  # bump this string whenever the inline Dockerfile below changes
      fi
      _stored_base_hash=$(cat "${_base_hash_file}" 2>/dev/null || echo "")

      if ! docker image inspect fre-run-base:latest >/dev/null 2>&1 || \
          [[ "${_base_hash}" != "${_stored_base_hash}" ]]; then
        echo "Building base run image (fre-run-base:latest)..."
        if [[ -f "${USER_SCRIPT_DIR}/Dockerfile.run" ]]; then
          docker build -t fre-run-base:latest - < "${USER_SCRIPT_DIR}/Dockerfile.run"
        else
          docker build -t fre-run-base:latest - <<'INLINE_DOCKERFILE'
FROM python:3.12-slim-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends \
    locales nodejs npm curl wget jq git ca-certificates build-essential \
    && echo "en_US.UTF-8 UTF-8" > /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV UV_BREAK_SYSTEM_PACKAGES=1
RUN pip install --quiet uv
WORKDIR /app
INLINE_DOCKERFILE
        fi
        echo "${_base_hash}" > "${_base_hash_file}"
      fi

      # Phase 3: Build system image if .fre-run.dockerfile exists.
      # .fre-run.dockerfile is for SYSTEM packages (apt-get) only — no pip/uv/npm installs.
      # Project deps are installed into the mounted cache dir in Phase 3.5 and persist
      # between runs without any Docker image rebuild.
      # Hash check: only rebuild when .fre-run.dockerfile content changes or image is absent.
      RUN_ACTIVE_IMAGE="fre-run-base:latest"
      RUN_PROJECT_DOCKERFILE="${RUN_CACHE_DIR}/.fre-run.dockerfile"
      if [[ -f "${RUN_PROJECT_DOCKERFILE}" ]]; then
        _proj_hash_file="${RUN_CACHE_DIR}/.fre-proj-hash"
        _proj_hash=$(cksum "${RUN_PROJECT_DOCKERFILE}" | awk '{print $1}')
        _stored_proj_hash=$(cat "${_proj_hash_file}" 2>/dev/null || echo "")
        if ! docker image inspect "${IMAGE_NAME}-run:latest" >/dev/null 2>&1 || \
            [[ "${_proj_hash}" != "${_stored_proj_hash}" ]]; then
          echo "Building project system image (${IMAGE_NAME}-run:latest)..."
          docker build -t "${IMAGE_NAME}-run:latest" \
            -f "${RUN_PROJECT_DOCKERFILE}" \
            "${RUN_CACHE_DIR}/"
          echo "${_proj_hash}" > "${_proj_hash_file}"
        fi
        RUN_ACTIVE_IMAGE="${IMAGE_NAME}-run:latest"
      fi

      # Phase 3.5: Install project dependencies into the cache dir.
      # The venv / node_modules live in ~/.fre-run-cache/<project>/ on the host and
      # survive between runs. A stamp file tracks the mtime of the dep file; install
      # only runs when the dep file is newer than the stamp (i.e. changed on EC2).
      _dep_type=""
      _dep_src=""
      if [[ -f "${RUN_CACHE_DIR}/uv.lock" ]]; then
        _dep_type="uv-lock"; _dep_src="${RUN_CACHE_DIR}/uv.lock"
      elif [[ -f "${RUN_CACHE_DIR}/pyproject.toml" ]]; then
        _dep_type="uv";      _dep_src="${RUN_CACHE_DIR}/pyproject.toml"
      elif [[ -f "${RUN_CACHE_DIR}/requirements.txt" ]]; then
        _dep_type="pip";     _dep_src="${RUN_CACHE_DIR}/requirements.txt"
      elif [[ -f "${RUN_CACHE_DIR}/package.json" ]]; then
        _dep_type="npm"
        if [[ -f "${RUN_CACHE_DIR}/package-lock.json" ]]; then
          _dep_src="${RUN_CACHE_DIR}/package-lock.json"
        else
          _dep_src="${RUN_CACHE_DIR}/package.json"
        fi
      fi

      _dep_stamp="${RUN_CACHE_DIR}/.fre-dep-installed"
      _needs_install=true
      if [[ -n "${_dep_src}" && -f "${_dep_stamp}" && "${_dep_src}" -ot "${_dep_stamp}" ]]; then
        _needs_install=false
      fi

      if [[ "${_needs_install}" == true && -n "${_dep_type}" ]]; then
        case "${_dep_type}" in
          uv-lock)
            echo "Syncing Python dependencies (uv sync)..."
            docker run --rm \
              "--volume" "${RUN_CACHE_DIR}:/app" "--workdir" "/app" \
              "${RUN_ACTIVE_IMAGE}" uv sync ;;
          uv)
            echo "Installing Python dependencies (uv)..."
            docker run --rm \
              "--volume" "${RUN_CACHE_DIR}:/app" "--workdir" "/app" \
              "${RUN_ACTIVE_IMAGE}" bash -c "uv venv --quiet 2>/dev/null || true; uv pip install -e . --quiet" ;;
          pip)
            echo "Installing Python dependencies (pip)..."
            docker run --rm \
              "--volume" "${RUN_CACHE_DIR}:/app" "--workdir" "/app" \
              "${RUN_ACTIVE_IMAGE}" \
              bash -c "python3 -m venv .venv 2>/dev/null || true && .venv/bin/pip install -q -r requirements.txt" ;;
          npm)
            echo "Installing Node.js dependencies (npm)..."
            docker run --rm \
              "--volume" "${RUN_CACHE_DIR}:/app" "--workdir" "/app" \
              "${RUN_ACTIVE_IMAGE}" npm install --silent ;;
        esac
        touch "${_dep_stamp}"
      elif [[ "${_needs_install}" == false ]]; then
        echo "Dependencies up to date."
      elif [[ -z "${_dep_type}" ]]; then
        echo ""
        echo "⚠  No dependency file found (uv.lock, pyproject.toml, requirements.txt, package.json)."
        echo "   Running with no project deps installed."
        echo ""
      fi

      # Phase 4: Run program on host.
      # All Python package managers (uv, pip) create .venv in the project dir.
      # Activate it via VIRTUAL_ENV + PATH — no dependency on uv being in the container.
      # __main__.py runs as `python3 -m <pkg>` so relative imports resolve.
      # Length check on RUN_SCRIPT_ARGS avoids bash 3.2 set -u empty-array bug.
      case "${RUN_SCRIPT}" in
        */__main__.py|__main__.py)
          _pkg="${RUN_SCRIPT%/__main__.py}"; _pkg="${_pkg##*/}"
          _run_cmd=(python3 -m "${_pkg}") ;;
        *.py) _run_cmd=(python3 "${RUN_SCRIPT}") ;;
        *.js) _run_cmd=(node "${RUN_SCRIPT}") ;;
        *.ts) _run_cmd=(npx ts-node "${RUN_SCRIPT}") ;;
        *.sh) _run_cmd=(bash "${RUN_SCRIPT}") ;;
        *)    _run_cmd=("${RUN_SCRIPT}") ;;
      esac
      [[ ${#RUN_SCRIPT_ARGS[@]} -gt 0 ]] && _run_cmd+=("${RUN_SCRIPT_ARGS[@]}")

      RUN_PROGRAM_ARGS=(
        "--rm"
        "--volume" "${RUN_CACHE_DIR}:/app"
        "--workdir" "/app"
      )
      if [[ "${_dep_type}" == "uv-lock" || "${_dep_type}" == "uv" || "${_dep_type}" == "pip" ]]; then
        RUN_PROGRAM_ARGS+=(
          "--env" "VIRTUAL_ENV=/app/.venv"
          "--env" "PATH=/app/.venv/bin:/usr/local/bin:/usr/bin:/bin"
        )
      fi
      for _mount in "${RUN_MOUNT_ARGS[@]}"; do
        RUN_PROGRAM_ARGS+=("--volume" "${_mount}")
      done
      if [[ -n "${RUN_ENV_FILE_HOST}" ]]; then
        while IFS= read -r _line || [[ -n "${_line}" ]]; do
          [[ -z "${_line}" || "${_line}" =~ ^# ]] && continue
          RUN_PROGRAM_ARGS+=("--env" "${_line}")
        done < "${RUN_ENV_FILE_HOST}"
      fi
      echo ""
      echo "Running ${RUN_SCRIPT} in ${RUN_ACTIVE_IMAGE}..."
      echo "─────────────────────────────────────────"
      _run_exit=0
      if [[ "${RUN_TTY}" == true ]]; then
        # TTY mode: allocate pseudo-TTY for interactive/TUI programs.
        # Cannot pipe through tee — output is not captured or uploaded.
        docker run --interactive --tty "${RUN_PROGRAM_ARGS[@]}" "${RUN_ACTIVE_IMAGE}" \
          "${_run_cmd[@]}" || _run_exit=$?
      else
        docker run "${RUN_PROGRAM_ARGS[@]}" "${RUN_ACTIVE_IMAGE}" \
          "${_run_cmd[@]}" 2>&1 \
          | tee "${RUN_TEMP_DIR}/output.txt" || _run_exit=$?
      fi
      echo "─────────────────────────────────────────"

      # Phase 5: Upload output back to EC2 (skipped with --local or --tty)
      if [[ "${RUN_LOCAL}" == false && "${RUN_TTY}" == false ]]; then
        docker run "${CONNECT_ARGS[@]}" \
          "--volume" "${RUN_TEMP_DIR}:/run-workspace" \
          "${IMAGE_NAME}" /workspace/scripts/run-upload.sh
        if [[ "${_run_exit}" -ne 0 ]]; then
          echo "⚠  Program exited with code ${_run_exit} — output uploaded for Claude to diagnose."
          exit "${_run_exit}"
        fi
      else
        if [[ "${_run_exit}" -ne 0 ]]; then
          echo "⚠  Program exited with code ${_run_exit}."
          exit "${_run_exit}"
        fi
      fi
      ;;
    local-shell)
      PROJECT_ARG="${2:-}"
      LOCAL_SHELL_VERBOSE=false
      for _arg in "${@:2}"; do
        [[ "${_arg}" == "--verbose" || "${_arg}" == "-v" ]] && LOCAL_SHELL_VERBOSE=true
        [[ "${_arg}" != -* ]] && [[ -z "${PROJECT_ARG}" || "${_arg}" == "${PROJECT_ARG}" ]] && PROJECT_ARG="${_arg}"
      done
      # Re-extract project as the first non-flag arg
      PROJECT_ARG=""
      for _arg in "${@:2}"; do
        [[ "${_arg}" == --verbose || "${_arg}" == -v ]] && continue
        PROJECT_ARG="${_arg}"; break
      done
      if [[ -z "${PROJECT_ARG}" ]]; then
        echo "Usage: user.sh local-shell <project> [--verbose]" >&2
        exit 1
      fi

      # Refuse if already inside a Docker container
      if [[ -f /.dockerenv ]]; then
        echo "ERROR: Already inside a Docker container." >&2
        echo "       Use csync and cpush directly instead of ./user.sh local-shell." >&2
        exit 1
      fi

      # Resolve LOCAL_SYNC_DIR (from user.env or default ~/claude)
      _local_sync_dir="${LOCAL_SYNC_DIR:-${HOME}/claude}"
      _local_sync_dir="${_local_sync_dir/#\~/${HOME}}"
      _local_proj_dir="${_local_sync_dir}/${PROJECT_ARG}"
      mkdir -p "${_local_proj_dir}"

      # Container project path
      _container_proj_dir="/projects/${PROJECT_ARG}"

      # Per-project extra mounts: LOCAL_MOUNTS_<slug> (hyphens→underscores)
      _proj_slug="${PROJECT_ARG//-/_}"
      _mounts_var="LOCAL_MOUNTS_${_proj_slug}"
      _extra_mounts=()
      if [[ -n "${!_mounts_var:-}" ]]; then
        for _mount_pair in ${!_mounts_var}; do
          _host_path="${_mount_pair%%:*}"
          _host_path="${_host_path/#\~/${HOME}}"
          _cont_path="${_mount_pair#*:}"
          _extra_mounts+=("--volume" "${_host_path}:${_cont_path}")
        done
      fi

      # Detect shell: prefer zsh if the user has a .zshrc, else bash
      _shell_cmd="bash"
      _shell_launch_args=(--rcfile /workspace/scripts/local-shell-init.sh)
      _zdotdir_tmp=""
      if [[ -f "${HOME}/.zshrc" ]]; then
        _shell_cmd="zsh"
        _shell_launch_args=()
        # Create a temp ZDOTDIR with a .zshrc that sources the user's config
        # then our init. Cleaned up after docker exits.
        _zdotdir_tmp=$(mktemp -d)
        cat > "${_zdotdir_tmp}/.zshrc" <<'ZDOTRC'
[[ -f /root/.user.zshrc ]] && source /root/.user.zshrc
source /workspace/scripts/local-shell-init.sh
ZDOTRC
        trap 'rm -rf "${_zdotdir_tmp}"' EXIT
      fi

      # Mount dotfiles that exist on the host (skip missing)
      _dotfile_mounts=()
      [[ -f "${HOME}/.vimrc" ]]    && _dotfile_mounts+=("--volume" "${HOME}/.vimrc:/root/.vimrc:ro")
      [[ -d "${HOME}/.vim" ]]      && _dotfile_mounts+=("--volume" "${HOME}/.vim:/root/.vim")
      [[ -f "${HOME}/.tmux.conf" ]] && _dotfile_mounts+=("--volume" "${HOME}/.tmux.conf:/root/.tmux.conf:ro")
      if [[ "${_shell_cmd}" == "zsh" ]]; then
        _dotfile_mounts+=("--volume" "${HOME}/.zshrc:/root/.user.zshrc:ro")
        _dotfile_mounts+=("--volume" "${_zdotdir_tmp}:/zdotdir")
      elif [[ -f "${HOME}/.bashrc" ]]; then
        _dotfile_mounts+=("--volume" "${HOME}/.bashrc:/root/.user.bashrc:ro")
      fi

      CONNECT_ARGS=("${DOCKER_ARGS[@]}")
      _setup_user_ssh_auth
      CONNECT_ARGS+=(
        "--volume" "${_local_proj_dir}:${_container_proj_dir}"
        "--env" "FRE_PROJECT=${PROJECT_ARG}"
        "--env" "FRE_LOCAL_DIR=/projects"
      )
      [[ "${_shell_cmd}" == "zsh" ]] && CONNECT_ARGS+=("--env" "ZDOTDIR=/zdotdir")
      if [[ ${#_dotfile_mounts[@]} -gt 0 ]]; then
        CONNECT_ARGS+=("${_dotfile_mounts[@]}")
      fi
      if [[ ${#_extra_mounts[@]} -gt 0 ]]; then
        CONNECT_ARGS+=("${_extra_mounts[@]}")
      fi

      if [[ "${LOCAL_SHELL_VERBOSE}" == true ]]; then
        echo "docker run \\" >&2
        for _a in "${CONNECT_ARGS[@]}"; do printf '  %q \\\n' "${_a}" >&2; done
        printf '  %q \\\n' "${IMAGE_NAME}" >&2
        printf '  %q' "${_shell_cmd}" >&2
        for _a in "${_shell_launch_args[@]}"; do printf ' %q' "${_a}" >&2; done
        echo "" >&2
        echo "" >&2
      fi

      docker run "${CONNECT_ARGS[@]}" "${IMAGE_NAME}" \
        "${_shell_cmd}" "${_shell_launch_args[@]}"
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
