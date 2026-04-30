#!/usr/bin/env bash
# refresh.sh — Push config updates to a running instance without a rebuild.
# Pushes: session_start.sh, autoshutdown timer, profile guards (bash or zsh).
# Does NOT touch user-owned dotfiles (.tmux.conf, .bashrc, etc.) — use push-config for those.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Preserve any caller-provided AWS_PROFILE (admin.sh passes its admin profile via --env)
_CALLER_PROFILE="${AWS_PROFILE:-}"

# Load config: user.env takes precedence (user path); fall back to admin.env (admin path)
if [[ -f "${SCRIPT_DIR}/../config/user.env" ]]; then
  source "${SCRIPT_DIR}/../config/user.env"
elif [[ -f "${SCRIPT_DIR}/../config/admin.env" ]]; then
  source "${SCRIPT_DIR}/../config/admin.env"
else
  echo "ERROR: No config found. Expected config/user.env or config/admin.env." >&2
  exit 1
fi
source "${SCRIPT_DIR}/../config/backend.env" 2>/dev/null || true

# Caller-provided profile wins (admin.sh refresh must use admin credentials, not user.env's profile)
[[ -n "${_CALLER_PROFILE}" ]] && AWS_PROFILE="${_CALLER_PROFILE}"

: "${AWS_REGION:?}" "${PROJECT_NAME:?}"

# DEV_USERNAME: set by admin.sh (command arg) or MY_USERNAME from admin.env
DEV_USERNAME="${DEV_USERNAME:-${MY_USERNAME:-}}"
if [[ -z "${DEV_USERNAME}" ]]; then
  echo "ERROR: DEV_USERNAME not set. Use './admin.sh refresh <username>' or set MY_USERNAME in config/admin.env." >&2
  exit 1
fi

_PROFILE_ARGS=()
[[ -n "${AWS_PROFILE:-}" ]] && _PROFILE_ARGS=(--profile "${AWS_PROFILE}")
_CREDS=$(aws configure export-credentials "${_PROFILE_ARGS[@]}" --format env-no-export 2>/dev/null) || {
  echo "ERROR: Could not export credentials${AWS_PROFILE:+ for profile '${AWS_PROFILE}'}." >&2
  echo "       If using SSO, run './admin.sh sso-login' first." >&2
  exit 1
}
eval "$(echo "${_CREDS}" | sed 's/^/export /')"
unset _CREDS _PROFILE_ARGS

SESSION_START="${SCRIPT_DIR}/session_start.sh"

# Resolve instance ID by Username tag
echo "--- resolving instance for '${DEV_USERNAME}' ---"
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:Username,Values=${DEV_USERNAME}" \
    "Name=tag:ProjectName,Values=${PROJECT_NAME}" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --region "${AWS_REGION}" \
  --output text 2>/dev/null)

if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
  echo "ERROR: No instance found for user '${DEV_USERNAME}' in project '${PROJECT_NAME}'." >&2
  exit 1
fi

SSH_OPTS=(
  "-o" "StrictHostKeyChecking=no"
  "-o" "UserKnownHostsFile=/dev/null"
  "-o" "LogLevel=ERROR"
  "-o" "ProxyCommand=aws ssm start-session --target ${INSTANCE_ID} --document-name AWS-StartSSHSession --parameters portNumber=22 --region ${AWS_REGION}"
)

if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
  # No agent forwarding — authenticate with key file
  SSH_KEY_FILE="${SSH_KEY_FILE:-/root/.ssh/fre-claude}"
  SSH_OPTS+=("-i" "${SSH_KEY_FILE}")
fi

echo "--- pushing session_start.sh to ${INSTANCE_ID} (${DEV_USERNAME}) ---"
ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "sudo tee /home/developer/session_start.sh > /dev/null && sudo chmod +x /home/developer/session_start.sh && sudo chown developer:developer /home/developer/session_start.sh" \
  < "${SESSION_START}"

echo "--- installing autoshutdown on ${INSTANCE_ID} (${DEV_USERNAME}) ---"
ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "sudo tee /usr/local/bin/autoshutdown.sh > /dev/null && sudo chmod +x /usr/local/bin/autoshutdown.sh" \
  << 'AUTOSHUTDOWN'
#!/bin/bash
# Shut down when no tmux sessions exist (user exited deliberately).
# Detached sessions (SSM drop) are kept alive — midnight Lambda handles those.
IDLE_FILE="${HOME}/.autoshutdown-idle-since"
source "${HOME}/.fre-config" 2>/dev/null || true
IDLE_THRESHOLD="${FRE_AUTOSHUTDOWN_IDLE_MINUTES:-30}"
SESSION_COUNT=$(tmux list-sessions 2>/dev/null | wc -l || echo 0)
if [[ "${SESSION_COUNT}" -gt 0 ]]; then
  rm -f "${IDLE_FILE}"; exit 0
fi
[[ ! -f "${IDLE_FILE}" ]] && { date +%s > "${IDLE_FILE}"; exit 0; }
IDLE_MINUTES=$(( ($(date +%s) - $(cat "${IDLE_FILE}")) / 60 ))
if [[ "${IDLE_MINUTES}" -ge "${IDLE_THRESHOLD}" ]]; then
  TOKEN=$(curl -s -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token)
  INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
  REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
  logger "autoshutdown: no tmux sessions for ${IDLE_MINUTES}min — stopping via EC2 API"
  aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION" >/dev/null
fi
AUTOSHUTDOWN

ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "sudo tee /etc/systemd/system/autoshutdown.timer > /dev/null" \
  << 'TIMER'
[Unit]
Description=Auto-shutdown when idle

[Timer]
OnBootSec=15min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
TIMER

ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "sudo tee /etc/systemd/system/autoshutdown.service > /dev/null" \
  << 'SERVICE'
[Unit]
Description=Auto-shutdown check

[Service]
Type=oneshot
User=developer
ExecStart=/usr/local/bin/autoshutdown.sh
SERVICE

ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "sudo systemctl daemon-reload && sudo systemctl enable --now autoshutdown.timer && echo '  autoshutdown timer active'"

# Detect the login shell so we patch the right profile file.
# Uses getent to read the developer user's shell from /etc/passwd.
echo "--- detecting login shell on ${INSTANCE_ID} (${DEV_USERNAME}) ---"
INSTANCE_SHELL=$(ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "getent passwd developer | cut -d: -f7 | xargs basename" 2>/dev/null || echo "bash")
if [[ "${INSTANCE_SHELL}" == "zsh" ]]; then
  PROFILE_FILE=".zprofile"
else
  PROFILE_FILE=".bash_profile"
fi
echo "  Login shell: ${INSTANCE_SHELL} → patching ~/${PROFILE_FILE}"

# Ensure the profile uses the correct session launcher guard:
#   [[ -t 0 && -z "${TMUX:-}" ]]  (SSH and SSM browser terminal both have a TTY)
# Remove the SSH_TTY restriction if present — SSM browser sessions don't set SSH_TTY.
echo "--- patching ~/${PROFILE_FILE} on ${INSTANCE_ID} (${DEV_USERNAME}) ---"
ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" "
  PROFILE_FILE=${PROFILE_FILE}
  [[ ! -f ~/\${PROFILE_FILE} ]] && touch ~/\${PROFILE_FILE}
  if grep -q 'SSH_TTY' ~/\${PROFILE_FILE}; then
    sed -i 's/\[\[ -n \"\${SSH_TTY:-}\" && -t 0 && -z \"\${TMUX:-}\" \]\]/[[ -t 0 \&\& -z \"\${TMUX:-}\" ]]/' ~/\${PROFILE_FILE}
    sed -i 's/# Launch Claude Code session selector on interactive SSH login/# Launch Claude Code session selector on interactive login (SSH or SSM browser terminal)/' ~/\${PROFILE_FILE}
    echo '  removed SSH_TTY restriction'
  elif ! grep -q 'session_start.sh' ~/\${PROFILE_FILE}; then
    printf '\n# Launch Claude Code session selector on interactive login (SSH or SSM browser terminal)\nif [[ -t 0 && -z \"\${TMUX:-}\" ]]; then\n  exec /home/developer/session_start.sh\nfi\n' >> ~/\${PROFILE_FILE}
    echo '  session launcher guard added'
  else
    echo '  already up to date'
  fi
"

echo "--- ensuring rsync is installed on ${INSTANCE_ID} (${DEV_USERNAME}) ---"
ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "sudo dnf install -y rsync -q && echo '  rsync ready'"

echo "--- installing web-preview service on ${INSTANCE_ID} (${DEV_USERNAME}) ---"
ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "sudo python3 -m pip install --quiet markdown && echo '  python-markdown installed'"

ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "sudo tee /usr/local/bin/fre-web-preview > /dev/null && sudo chmod +x /usr/local/bin/fre-web-preview" \
  < "${SCRIPT_DIR}/fre-web-preview"

ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "sudo tee /etc/systemd/system/web-preview.service > /dev/null" \
  << 'WEB_PREVIEW_SERVICE'
[Unit]
Description=Web preview server for Claude Code output (renders .md as HTML)
After=network.target

[Service]
Type=simple
User=developer
ExecStart=/usr/local/bin/fre-web-preview
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
WEB_PREVIEW_SERVICE

ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "sudo systemctl daemon-reload && sudo systemctl enable web-preview.service && sudo systemctl restart web-preview.service && echo '  web-preview service active on port 8080 (markdown rendering active)'"

echo "--- pushing ~/.claude/CLAUDE.md to ${INSTANCE_ID} (${DEV_USERNAME}) ---"
ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "mkdir -p ~/.claude && tee ~/.claude/CLAUDE.md > /dev/null" \
  << 'CLAUDE_MD'
## File Sharing with the User

A static web server is always running on this instance. The user can access it at **http://localhost:8080** in their local browser while connected.

Directory conventions (using `my-app` as an example project):
- `~/repos/my-app/` — the **working directory** (source code)
- `~/www/my-app/`   — the **web root** (also called the serve directory); files here are served at `http://localhost:8080/my-app/`
- `~/uploads/my-app/` — where user-uploaded files land; also accessible at `http://localhost:8080/my-app/uploads/` via a symlink in the web root

### Sharing visual output or web content

Write files to the **web root** (`~/www/<project>/`) where `<project>` is the basename of the working directory. For example, if the working directory is `~/repos/my-app/`, the web root is `~/www/my-app/`.

Files written to the web root are immediately visible at `http://localhost:8080/<project>/` in the user's browser. Tell the user to open that URL to preview your output.

### When the user uploads files

The user may upload screenshots, images, or reference files using `./user.sh upload`. Uploaded files appear in `~/uploads/<project>/` (same project-name convention as the web root). When the user says "I uploaded a screenshot" or "I sent you a file", check that directory.

## Running Programs Locally (`./user.sh run`)

Some programs must run on the user's Mac — to reach local files, local services, or credentials that this EC2 instance can't access. The `./user.sh run` command handles this: it downloads the project from EC2, runs it in a Docker container on the user's Mac, and uploads the output to `~/uploads/<project>/run-output.txt` for you to read.

### When to use it

Suggest `./user.sh run` when the program needs:
- Local files on the user's Mac (documents, images, data files)
- Local services (databases, APIs running on localhost)
- Local credentials or secrets not stored on EC2

### How to set it up

When building a project that will use `./user.sh run`:

1. **Project dependencies are installed automatically** — `./user.sh run` detects the package manager from the project files and installs into a cached venv/node_modules on the user's Mac:
   - `uv.lock` → `uv sync`
   - `pyproject.toml` (no lockfile) → `uv pip install -e .`
   - `requirements.txt` → `pip install -r requirements.txt`
   - `package.json` → `npm install`

   **Do NOT put `pip install`, `uv sync`, or `npm install` in `.fre-run.dockerfile`** — those belong in the project's standard package files, not the Dockerfile.

2. Only create `.fre-run.dockerfile` if the project needs **extra system packages** (e.g. `libpq-dev`, `ffmpeg`, `libreoffice`):
   ```dockerfile
   FROM fre-run-base:latest
   RUN apt-get update && apt-get install -y --no-install-recommends libpq-dev && rm -rf /var/lib/apt/lists/*
   ```
   If no extra system packages are needed, skip this file entirely.

3. Give the user a **single copy-pasteable command** with no placeholders — use the exact project name (matching `~/repos/<name>`), the exact relative script path within the project, and full absolute Mac paths for every `--mount` flag. Tell them to say **done** when it finishes.

### After the user says "done"

Check the output:
```bash
cat ~/uploads/<project>/run-output.txt
```

### Example Claude message to the user

> Run it locally with:
> `~/fre-aws/user.sh run myproject scripts/analyze.py --mount ~/Documents/sales:/data -- --year 2025`
> Then tell me **done**.
CLAUDE_MD

echo "--- refreshing .fre-config on ${INSTANCE_ID} (${DEV_USERNAME}) ---"
ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "printf 'FRE_PROJECT_NAME=%s\nFRE_USERNAME=%s\nFRE_REGION=%s\nFRE_AUTOSHUTDOWN_IDLE_MINUTES=%s\n' '${PROJECT_NAME}' '${DEV_USERNAME}' '${AWS_REGION}' '${AUTOSHUTDOWN_IDLE_MINUTES:-30}' > ~/.fre-config && chmod 600 ~/.fre-config && echo '  .fre-config updated'"

echo "--- setting hasCompletedOnboarding in ~/.claude/settings.json ---"
ssh "${SSH_OPTS[@]}" developer@"${INSTANCE_ID}" \
  "mkdir -p ~/.claude && (jq '.hasCompletedOnboarding = true' ~/.claude/settings.json 2>/dev/null || echo '{\"hasCompletedOnboarding\": true}') | tee ~/.claude/settings.json > /dev/null && echo '  done'"

echo ""
echo "=== refresh complete on ${INSTANCE_ID} (${DEV_USERNAME}) ==="
echo "    session_start.sh:     take effect on next connect"
echo "    autoshutdown timer:   active immediately"
echo "    web-preview service:  active immediately (http://localhost:8080)"
echo "    ~/.claude/CLAUDE.md:  updated"
echo "    ~/.fre-config:        updated"
echo "    hasCompletedOnboarding: set"
