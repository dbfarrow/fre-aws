#!/bin/bash
# session_start.sh — Interactive Claude Code session launcher.
# Runs automatically on SSH login. Offers locally-cloned repos (numbered),
# clone/new/shell actions (lettered), all launched inside named tmux sessions
# with `claude --continue` so conversation history always resumes.
#
# To update this script on a running instance without down/up:
#   ./run.sh refresh

# Already inside tmux — don't nest
[[ -n "${TMUX:-}" ]] && exit 0

# Only run interactively. If stdin is not a terminal (e.g. a git hook or other
# tool spawned a login shell), exit cleanly so the intended command can run.
if [[ ! -t 0 ]]; then
  exit 0
fi

# Auto-reattach: if exactly one tmux session is running, skip the menu and
# reconnect immediately — handles the "dropped connection" case transparently.
mapfile -t _SESSIONS < <(tmux list-sessions -F '#S' 2>/dev/null || true)
if [[ ${#_SESSIONS[@]} -eq 1 ]]; then
  echo "Reconnecting to '${_SESSIONS[0]}'..."
  exec tmux attach-session -t "${_SESSIONS[0]}"
fi
unset _SESSIONS

# Source instance config (written at provision time and by refresh)
# shellcheck source=/dev/null
source ~/.fre-config 2>/dev/null

# Source user-managed env vars (created locally as ~/.fre-aws, pushed via push-config).
# Silently skipped if not present — zero overhead for users who don't need it.
# shellcheck source=/dev/null
source ~/.fre-aws-user-env 2>/dev/null || true

# ---- LiteLLM gateway ----
# If a LiteLLM base URL is configured for this environment, fetch the user's
# API key from Secrets Manager and export both env vars so Claude routes through
# the proxy without any interactive setup step.
_LITELLM_URL=""
_LITELLM_KEY=""
if [[ -n "${FRE_PROJECT_NAME:-}" && -n "${FRE_REGION:-}" ]]; then
  _LITELLM_URL=$(aws ssm get-parameter \
    --name "/${FRE_PROJECT_NAME}/litellm/base-url" \
    --region "${FRE_REGION}" \
    --query 'Parameter.Value' --output text 2>/dev/null || true)
  [[ "${_LITELLM_URL}" == "None" ]] && _LITELLM_URL=""

  if [[ -n "${_LITELLM_URL}" ]]; then
    _SECRET_ID="${FRE_PROJECT_NAME}/${FRE_USERNAME:-developer}/litellm-key"
    _LITELLM_KEY=$(aws secretsmanager get-secret-value \
      --secret-id "${_SECRET_ID}" \
      --region "${FRE_REGION}" \
      --query 'SecretString' --output text 2>/dev/null || true)
    [[ "${_LITELLM_KEY}" == "None" ]] && _LITELLM_KEY=""

    if [[ -n "${_LITELLM_KEY}" ]]; then
      export ANTHROPIC_BASE_URL="${_LITELLM_URL}"
      export ANTHROPIC_API_KEY="${_LITELLM_KEY}"
    fi
  fi
fi

# Refresh git identity if passed through SSH env
[[ -n "${GIT_USER_NAME:-}"  ]] && git config --global user.name  "${GIT_USER_NAME}"
[[ -n "${GIT_USER_EMAIL:-}" ]] && git config --global user.email "${GIT_USER_EMAIL}"

# ---------------------------------------------------------------------------
# settings.json guard — backup/restore + atomic LiteLLM merge
# Claude Code writes settings non-atomically; a kill mid-write leaves a 0-byte
# file. Keep a .bak and restore from it automatically at session start.
# ---------------------------------------------------------------------------
_ensure_settings_json() {
  local settings="${HOME}/.claude/settings.json"
  local backup="${HOME}/.claude/settings.json.bak"
  mkdir -p "${HOME}/.claude"

  # Restore from backup if the file was truncated to 0 bytes
  if [[ -f "${settings}" && ! -s "${settings}" ]]; then
    if [[ -f "${backup}" && -s "${backup}" ]]; then
      echo "  (settings.json was empty — restored from backup)"
      cp "${backup}" "${settings}"
    else
      echo "  (settings.json was empty — removing for fresh start)"
      rm -f "${settings}"
    fi
  fi

  # LiteLLM: merge hasCompletedOnboarding using temp file + atomic rename
  # so our own write can't leave a 0-byte file if the process is killed
  if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
    local tmp
    tmp=$(mktemp "${HOME}/.claude/settings.json.XXXXXX")
    (jq '.hasCompletedOnboarding = true' "${settings}" 2>/dev/null \
      || echo '{"hasCompletedOnboarding": true}') > "${tmp}" \
      && mv "${tmp}" "${settings}" \
      || rm -f "${tmp}"
  fi

  # Update the backup from the current valid file
  if [[ -f "${settings}" && -s "${settings}" ]] && jq empty "${settings}" 2>/dev/null; then
    cp "${settings}" "${backup}"
  fi
}

REPOS_DIR="${HOME}/repos"
mkdir -p "${REPOS_DIR}"

echo ""
echo "╔═══════════════════════════════════════╗"
echo "║     Claude Code Development Env       ║"
echo "╚═══════════════════════════════════════╝"
echo ""

# ---------------------------------------------------------------------------
# Build menu from locally-cloned repos
# ---------------------------------------------------------------------------
OPTIONS=()
IDX=1

echo "  Projects"
while IFS= read -r -d '' dir; do
  REPO_NAME=$(basename "${dir}")
  printf "   %d) %s\n" "${IDX}" "${REPO_NAME}"
  OPTIONS+=("${dir}")
  (( IDX++ ))
done < <(find "${REPOS_DIR}" -mindepth 1 -maxdepth 1 -type d -name "*.git" -prune -o \
           -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)

if [[ ${#OPTIONS[@]} -eq 0 ]]; then
  echo "   (none)"
fi

echo ""
echo "  Actions"
echo "   c) Clone a GitHub repo"
echo "   n) New project"
echo "   s) Shell"
if [[ -n "${_LITELLM_URL}" ]]; then
  if [[ -z "${_LITELLM_KEY}" ]]; then
    echo ""
    echo "  No LiteLLM API key found."
  fi
  if [[ -n "${_LITELLM_KEY}" ]]; then
    echo "   k) Update LiteLLM API key"
  else
    echo "   k) Set LiteLLM API key"
  fi
fi
echo ""
echo "   q) Quit"
echo ""

# Default: first repo if any exist, otherwise clone
if [[ ${#OPTIONS[@]} -gt 0 ]]; then
  DEFAULT="1"
else
  DEFAULT="c"
fi

read -r -p "Choose [${DEFAULT}]: " CHOICE
CHOICE="${CHOICE:-${DEFAULT}}"

# ---------------------------------------------------------------------------
# Helper: launch Claude in a named tmux session for the given directory.
# Reattaches if a session with that name already exists.
# ---------------------------------------------------------------------------
launch_in_repo() {
  local dir="$1"
  local name; name=$(basename "${dir}")
  # Ensure per-project web root and upload directories exist, with uploads linked into web root
  mkdir -p ~/www/"${name}" ~/uploads/"${name}"
  ln -sf ~/uploads/"${name}" ~/www/"${name}"/uploads
  # Guard settings.json against truncation and merge LiteLLM flag if needed
  _ensure_settings_json
  if tmux has-session -t "${name}" 2>/dev/null; then
    echo "Reattaching to existing '${name}' session..."
    exec tmux attach-session -t "${name}"
  else
    echo "Starting Claude Code in ${name}..."
    cd "${dir}"
    exec tmux new-session -s "${name}" 'claude --continue 2>/dev/null || claude; exec bash'
  fi
}

# ---------------------------------------------------------------------------
# Shell option
# ---------------------------------------------------------------------------
if [[ "${CHOICE}" == "s" ]]; then
  echo ""
  echo "Repos are in ~/repos/. Type 'claude' to start Claude Code."
  cd "${HOME}"
  exec bash
fi

# ---------------------------------------------------------------------------
# Quit
# ---------------------------------------------------------------------------
if [[ "${CHOICE}" == "q" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# LiteLLM API key management
# ---------------------------------------------------------------------------
if [[ "${CHOICE}" == "k" ]]; then
  if [[ -z "${_LITELLM_URL}" ]]; then
    echo "  LiteLLM not configured for this environment."
    cd "${HOME}"
    exec bash
  fi
  read -r -s -p "  Enter your LiteLLM API key: " _NEW_KEY
  echo ""
  if [[ -n "${_NEW_KEY}" ]]; then
    _SECRET_ID="${FRE_PROJECT_NAME}/${FRE_USERNAME:-developer}/litellm-key"
    if aws secretsmanager create-secret \
        --name "${_SECRET_ID}" \
        --secret-string "${_NEW_KEY}" \
        --region "${FRE_REGION}" > /dev/null 2>&1; then
      echo "  API key saved."
    elif aws secretsmanager put-secret-value \
        --secret-id "${_SECRET_ID}" \
        --secret-string "${_NEW_KEY}" \
        --region "${FRE_REGION}" > /dev/null 2>&1; then
      echo "  API key updated."
    else
      echo "  ERROR: Failed to save API key. Check IAM permissions."
    fi
    export ANTHROPIC_BASE_URL="${_LITELLM_URL}"
    export ANTHROPIC_API_KEY="${_NEW_KEY}"
    _LITELLM_KEY="${_NEW_KEY}"
  fi
  # Re-invoke the menu so the user can pick a repo with the key now set
  exec /home/developer/session_start.sh
fi

# ---------------------------------------------------------------------------
# Clone a GitHub repo via gh CLI (OAuth token — no SSH key in GitHub required)
# ---------------------------------------------------------------------------
if [[ "${CHOICE}" == "c" ]]; then
  echo ""

  # Ensure gh is authenticated (HTTPS protocol — no SSH key required)
  if ! gh auth status >/dev/null 2>&1; then
    echo "GitHub authentication required."
    echo "You'll be shown a one-time code — open the URL in your browser and enter it."
    echo ""
    gh auth login --git-protocol https
    echo ""
  fi

  # Fetch repo list for a numbered menu — includes owned, collaborated, and org repos
  echo "Fetching your GitHub repos..."
  REPO_LIST=$(gh api 'user/repos?per_page=100&sort=updated' --jq '.[].full_name' 2>/dev/null || true)

  REPO_SLUG=""
  if [[ -z "${REPO_LIST}" ]]; then
    # Fallback: manual entry
    read -r -p "GitHub repo (owner/repo): " REPO_SLUG
  else
    REPO_OPTIONS=()
    RIDX=1
    echo ""
    while IFS= read -r repo; do
      printf "  %2d) %s\n" "${RIDX}" "${repo}"
      REPO_OPTIONS+=("${repo}")
      (( RIDX++ ))
    done <<< "${REPO_LIST}"
    printf "  %2d) Enter manually\n" "${RIDX}"
    MANUAL_OPT=${RIDX}
    echo ""
    read -r -p "Choose repo [1]: " REPO_CHOICE
    REPO_CHOICE="${REPO_CHOICE:-1}"

    if [[ "${REPO_CHOICE}" == "${MANUAL_OPT}" ]]; then
      read -r -p "GitHub repo (owner/repo): " REPO_SLUG
    elif [[ "${REPO_CHOICE}" =~ ^[0-9]+$ ]] && (( REPO_CHOICE >= 1 && REPO_CHOICE < MANUAL_OPT )); then
      REPO_SLUG="${REPO_OPTIONS[$((REPO_CHOICE-1))]}"
    else
      echo "Invalid choice. Dropping into shell."
      cd "${HOME}"
      exec bash
    fi
  fi

  if [[ -z "${REPO_SLUG}" ]]; then
    echo "No repo entered. Dropping into shell."
    cd "${HOME}"
    exec bash
  fi

  REPO_NAME=$(basename "${REPO_SLUG%.git}")
  LOCAL_DIR="${REPOS_DIR}/${REPO_NAME}"
  if [[ -d "${LOCAL_DIR}" ]]; then
    echo "  ${REPO_NAME} already exists locally — opening it."
  else
    echo "Cloning ${REPO_SLUG}..."
    gh repo clone "${REPO_SLUG}" "${LOCAL_DIR}" -- --quiet || {
      echo ""
      echo "Clone failed. Check that the repo name is correct and you have access."
      echo "Dropping into shell."
      cd "${HOME}"
      exec bash
    }
    echo "  Done."
  fi
  echo ""
  launch_in_repo "${LOCAL_DIR}"
fi

# ---------------------------------------------------------------------------
# Create a new local project directory
# ---------------------------------------------------------------------------
if [[ "${CHOICE}" == "n" ]]; then
  echo ""
  read -r -p "Project name: " PROJECT_NAME
  if [[ -z "${PROJECT_NAME}" ]]; then
    echo "No name entered. Dropping into shell."
    cd "${HOME}"
    exec bash
  fi
  LOCAL_DIR="${REPOS_DIR}/${PROJECT_NAME}"
  mkdir -p "${LOCAL_DIR}"
  echo ""
  launch_in_repo "${LOCAL_DIR}"
fi

# ---------------------------------------------------------------------------
# Validate numeric repo choice
# ---------------------------------------------------------------------------
if ! [[ "${CHOICE}" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#OPTIONS[@]} )); then
  echo "Invalid choice. Dropping into shell."
  cd "${HOME}"
  exec bash
fi

# ---------------------------------------------------------------------------
# Launch Claude in the selected local repo
# ---------------------------------------------------------------------------
launch_in_repo "${OPTIONS[$((CHOICE-1))]}"
