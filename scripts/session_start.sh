#!/bin/bash
# session_start.sh — Interactive Claude Code session launcher.
# Runs automatically on SSH login. Offers locally-cloned repos, cloning a
# new GitHub repo (via SSH agent forwarding), creating a new local project,
# or a plain shell.
#
# To update this script on a running instance without down/up:
#   ./run.sh refresh

# Only run interactively. If stdin is not a terminal (e.g. a git hook or other
# tool spawned a login shell), exit cleanly so the intended command can run.
if [[ ! -t 0 ]]; then
  exit 0
fi

# Refresh git identity if passed through SSH env
[[ -n "${GIT_USER_NAME:-}"  ]] && git config --global user.name  "${GIT_USER_NAME}"
[[ -n "${GIT_USER_EMAIL:-}" ]] && git config --global user.email "${GIT_USER_EMAIL}"

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

while IFS= read -r -d '' dir; do
  REPO_NAME=$(basename "${dir}")
  printf "  %2d) %s\n" "${IDX}" "${REPO_NAME}"
  OPTIONS+=("${dir}")
  (( IDX++ ))
done < <(find "${REPOS_DIR}" -mindepth 1 -maxdepth 1 -type d -name "*.git" -prune -o \
           -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)

printf "  %2d) Clone a GitHub repo\n"  "${IDX}"; CLONE_OPT=${IDX};  (( IDX++ ))
printf "  %2d) Create a new project\n" "${IDX}"; CREATE_OPT=${IDX}; (( IDX++ ))
printf "  %2d) Open a shell\n"         "${IDX}"; SHELL_OPT=${IDX}
echo ""
read -r -p "Choose [${CLONE_OPT}]: " CHOICE
CHOICE="${CHOICE:-${CLONE_OPT}}"

# ---------------------------------------------------------------------------
# Shell option
# ---------------------------------------------------------------------------
if [[ "${CHOICE}" == "${SHELL_OPT}" ]]; then
  echo ""
  echo "Repos are in ~/repos/. Type 'claude' to start Claude Code."
  cd "${HOME}"
  exec bash
fi

# ---------------------------------------------------------------------------
# Clone a GitHub repo via SSH (uses forwarded agent — no token needed)
# ---------------------------------------------------------------------------
if [[ "${CHOICE}" == "${CLONE_OPT}" ]]; then
  echo ""
  read -r -p "GitHub repo (owner/repo): " REPO_SLUG
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
    git clone "git@github.com:${REPO_SLUG}.git" "${LOCAL_DIR}" || {
      echo ""
      echo "Clone failed. Check the repo name and that your SSH key is added to GitHub."
      echo "Dropping into shell."
      cd "${HOME}"
      exec bash
    }
    echo "  Done."
  fi
  echo ""
  echo "Starting Claude Code in ${REPO_NAME}..."
  echo ""
  cd "${LOCAL_DIR}"
  exec claude
fi

# ---------------------------------------------------------------------------
# Create a new local project directory
# ---------------------------------------------------------------------------
if [[ "${CHOICE}" == "${CREATE_OPT}" ]]; then
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
  echo "Starting Claude Code in ${PROJECT_NAME}..."
  echo ""
  cd "${LOCAL_DIR}"
  exec claude
fi

# ---------------------------------------------------------------------------
# Validate local repo choice
# ---------------------------------------------------------------------------
if ! [[ "${CHOICE}" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#OPTIONS[@]} )); then
  echo "Invalid choice. Dropping into shell."
  cd "${HOME}"
  exec bash
fi

# ---------------------------------------------------------------------------
# Launch Claude in the selected local repo
# ---------------------------------------------------------------------------
SELECTED="${OPTIONS[$((CHOICE-1))]}"
echo ""
echo "Starting Claude Code in $(basename "${SELECTED}")..."
echo ""
cd "${SELECTED}"
exec claude
