echo "Region: ${REGION}  Project: ${PROJECT_NAME}  User: ${DEV_USERNAME}"

# ---------------------------------------------------------------------------
# System updates and tools
# ---------------------------------------------------------------------------
dnf update -y
dnf install -y git tmux vim htop openssh-server rsync

# ---------------------------------------------------------------------------
# fzf — fuzzy finder for session_start.sh repo/clone selection
# Not in AL2023 dnf repos; install latest binary from GitHub releases
# ---------------------------------------------------------------------------
_FZF_ARCH=$(uname -m)
[[ "${_FZF_ARCH}" == "aarch64" ]] && _FZF_ARCH="arm64" || _FZF_ARCH="amd64"
_FZF_VER=$(curl -sf https://api.github.com/repos/junegunn/fzf/releases/latest | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))" 2>/dev/null || true)
if [[ -n "${_FZF_VER}" ]]; then
  curl -sL "https://github.com/junegunn/fzf/releases/download/v${_FZF_VER}/fzf-${_FZF_VER}-linux_${_FZF_ARCH}.tar.gz" | tar -xz -C /usr/local/bin fzf
  echo "fzf ${_FZF_VER} installed."
else
  echo "WARNING: Could not fetch fzf release info — skipping fzf install. Repo picker will fall back to numbered list."
fi

# ---------------------------------------------------------------------------
# GitHub CLI (gh) — used for authenticated repo browsing and cloning
# ---------------------------------------------------------------------------
dnf install -y 'dnf-command(config-manager)'
dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
dnf install -y gh
gh --version || true

# ---------------------------------------------------------------------------
# Node.js (required by Claude Code CLI)
# ---------------------------------------------------------------------------
dnf install -y nodejs npm
node --version
npm --version

# ---------------------------------------------------------------------------
# Claude Code CLI
# ---------------------------------------------------------------------------
npm install -g @anthropic-ai/claude-code
claude --version || true

# ---------------------------------------------------------------------------
# Data volume — mount at /home/developer/ if DATA_VOLUME_ID is set
# ---------------------------------------------------------------------------
if [[ -n "${DATA_VOLUME_ID:-}" ]]; then
  echo "--- mounting data volume ${DATA_VOLUME_ID} ---"
  # Nitro instances expose EBS volumes via NVMe. The volume serial is the volume
  # ID with dashes removed (vol-0abc1234 → vol0abc1234).
  # Wait up to 5 minutes (60 × 5s). The Terraform aws_volume_attachment resource
  # is applied after the instance reaches running state, so the attachment can
  # arrive well after user_data starts — especially when dnf cache is warm and
  # the package installs finish in seconds rather than minutes.
  VOLUME_SERIAL="${DATA_VOLUME_ID//-/}"
  DATA_DEV=""
  for i in $(seq 1 60); do
    SYMLINK="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOLUME_SERIAL}"
    if [[ -L "${SYMLINK}" ]]; then
      DATA_DEV=$(readlink -f "${SYMLINK}")
      break
    fi
    sleep 5
  done
  if [[ -z "${DATA_DEV}" ]]; then
    echo "WARNING: Data volume device not found after 300s — continuing without mount." >&2
  else
    if ! blkid "${DATA_DEV}" > /dev/null 2>&1; then
      echo "  First boot: formatting data volume..."
      mkfs.ext4 -L fre-user-data "${DATA_DEV}"
    fi
    mkdir -p /home/developer
    mount "${DATA_DEV}" /home/developer
    grep -q "fre-user-data" /etc/fstab || \
      echo "LABEL=fre-user-data /home/developer ext4 defaults,nofail 0 2" >> /etc/fstab
    echo "  Data volume mounted at /home/developer/"
  fi
fi

# ---------------------------------------------------------------------------
# Developer user
# ---------------------------------------------------------------------------
if [[ "${PREFERRED_SHELL:-bash}" == "zsh" ]]; then
  dnf install -y zsh
  _SHELL="$(which zsh)"
else
  _SHELL="/bin/bash"
fi

if ! id "developer" &>/dev/null; then
  if mountpoint -q /home/developer 2>/dev/null; then
    # Data volume already mounted — create user without recreating home dir
    useradd -M -d /home/developer -s "${_SHELL}" developer
  else
    useradd -m -d /home/developer -s "${_SHELL}" developer
  fi
  echo "developer ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/developer
  chmod 440 /etc/sudoers.d/developer
fi

if [[ "${PREFERRED_SHELL:-bash}" == "zsh" ]]; then
  # Suppress the zsh new-user wizard on first login
  touch /home/developer/.zshrc
  chown developer:developer /home/developer/.zshrc
  echo "Preferred shell: zsh"
else
  echo "Preferred shell: bash"
fi

chown developer:developer /home/developer

# ---------------------------------------------------------------------------
# SSH authorized key
# ---------------------------------------------------------------------------
if [[ -n "${SSH_PUBLIC_KEY}" ]]; then
  mkdir -p /home/developer/.ssh
  chmod 700 /home/developer/.ssh
  echo "${SSH_PUBLIC_KEY}" > /home/developer/.ssh/authorized_keys
  chmod 600 /home/developer/.ssh/authorized_keys
  chown -R developer:developer /home/developer/.ssh
  echo "SSH public key installed for developer user."
else
  echo "WARNING: No SSH public key provided — SSH agent forwarding will not work."
fi

# ---------------------------------------------------------------------------
# Git identity (pre-configure; refreshed at each login via SSH env vars)
# ---------------------------------------------------------------------------
[[ -n "${GIT_USER_NAME}"  ]] && su - developer -c "git config --global user.name  '${GIT_USER_NAME}'"
[[ -n "${GIT_USER_EMAIL}" ]] && su - developer -c "git config --global user.email '${GIT_USER_EMAIL}'"
su - developer -c "git config --global core.editor vim"
su - developer -c "git config --global init.defaultBranch main"

# ---------------------------------------------------------------------------
# SSH server — accept git identity from the SSH client
# ---------------------------------------------------------------------------
cat >> /etc/ssh/sshd_config << 'SSHD_CONF'

# fre-aws: allow developer login with public key only
AllowUsers developer
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no

# Forward these env vars from the connecting SSH client
AcceptEnv LANG LC_* GIT_USER_NAME GIT_USER_EMAIL
SSHD_CONF

systemctl enable sshd
systemctl start sshd
echo "SSH server configured."

# ---------------------------------------------------------------------------
# Repo workspace
# ---------------------------------------------------------------------------
mkdir -p /home/developer/repos
chown developer:developer /home/developer/repos

# ---------------------------------------------------------------------------
# Autoshutdown — stop instance when no tmux sessions exist for 10+ minutes
# ---------------------------------------------------------------------------
cat > /usr/local/bin/autoshutdown.sh << 'AUTOSHUTDOWN'
#!/bin/bash
# Shut down when no tmux sessions exist (user exited deliberately).
# Detached sessions (SSM drop) are kept alive — midnight Lambda handles those.
IDLE_FILE="${HOME}/.autoshutdown-idle-since"
SESSION_COUNT=$(tmux list-sessions 2>/dev/null | wc -l || echo 0)
if [[ "${SESSION_COUNT}" -gt 0 ]]; then
  rm -f "${IDLE_FILE}"; exit 0
fi
[[ ! -f "${IDLE_FILE}" ]] && { date +%s > "${IDLE_FILE}"; exit 0; }
IDLE_MINUTES=$(( ($(date +%s) - $(cat "${IDLE_FILE}")) / 60 ))
if [[ "${IDLE_MINUTES}" -ge 10 ]]; then
  TOKEN=$(curl -s -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token)
  INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
  REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
  logger "autoshutdown: no tmux sessions for ${IDLE_MINUTES}min — stopping via EC2 API"
  aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION" >/dev/null
fi
AUTOSHUTDOWN
chmod +x /usr/local/bin/autoshutdown.sh

cat > /etc/systemd/system/autoshutdown.timer << 'TIMER'
[Unit]
Description=Auto-shutdown when idle

[Timer]
OnBootSec=15min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
TIMER

cat > /etc/systemd/system/autoshutdown.service << 'SERVICE'
[Unit]
Description=Auto-shutdown check

[Service]
Type=oneshot
User=developer
ExecStart=/usr/local/bin/autoshutdown.sh
SERVICE

systemctl enable --now autoshutdown.timer
echo "Autoshutdown timer enabled."

# ---------------------------------------------------------------------------
# Web preview — markdown, JSON, YAML rendering server for ~/www/
# ---------------------------------------------------------------------------
mkdir -p /home/developer/www /home/developer/uploads
chown developer:developer /home/developer/www /home/developer/uploads

dnf install -y -q python3-pip
python3 -m pip install --quiet markdown

cat > /usr/local/bin/fre-web-preview << 'PREVIEW_SERVER'
#!/usr/bin/env python3
"""fre-web-preview — markdown, JSON, and YAML rendering HTTP server for Claude Code output preview."""
import datetime
import http.server
import io
import json
import os
import html as html_module

try:
    import markdown
    HAS_MARKDOWN = True
except ImportError:
    HAS_MARKDOWN = False

# CONTENT_WIDTH is replaced per-request from ~/.fre-preview-width
CSS = """<style>
body{max-width:CONTENT_WIDTH;margin:40px auto;padding:0 20px;
     font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
     line-height:1.6;color:#24292e}
pre{background:#f6f8fa;padding:16px;border-radius:6px;overflow-x:auto}
code{background:#f6f8fa;padding:2px 4px;border-radius:3px;font-size:90%}
pre code{background:none;padding:0;font-size:87%}
a{color:#0366d6}
h1,h2,h3{border-bottom:1px solid #eaecef;padding-bottom:.3em}
blockquote{border-left:4px solid #dfe2e5;margin:0;padding:0 16px;color:#6a737d}
table{border-collapse:collapse;width:100%}
th,td{border:1px solid #dfe2e5;padding:6px 12px}
th{background:#f6f8fa;text-align:left}
td.size{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
td.date{white-space:nowrap;color:#586069}
img{max-width:100%}
</style>"""

PAGE_WIDTHS = {'letter': '6.5in', 'a4': '170mm'}


def _read_width_config():
    """Read content width from ~/.fre-preview-width.
    Values: a number 10-100 (viewport %), 'letter', 'a4', or missing for default 800px."""
    try:
        with open(os.path.expanduser('~/.fre-preview-width')) as f:
            val = f.read().strip().lower()
        if val in PAGE_WIDTHS:
            return PAGE_WIDTHS[val]
        return f'{max(10, min(100, int(val)))}%'
    except Exception:
        return '800px'


def _human_size(b):
    """Return human-readable file size (e.g. 1.2 M, 34 K, 512 B)."""
    if b < 1024:
        return f'{b} B'
    for unit in ('K', 'M', 'G', 'T'):
        b /= 1024
        if b < 1024:
            return f'{b:.1f} {unit}'
    return f'{b:.1f} T'


def _code_page(title, content, width):
    """Wrap pre-formatted text in a styled HTML page (used for JSON and YAML)."""
    css = CSS.replace('CONTENT_WIDTH', width)
    body = f'<pre><code>{html_module.escape(content)}</code></pre>'
    return (
        f'<!DOCTYPE html><html><head>'
        f'<meta charset="utf-8"><title>{html_module.escape(title)}</title>'
        f'{css}</head><body>{body}</body></html>'
    ).encode('utf-8')


class PreviewHandler(http.server.SimpleHTTPRequestHandler):
    def list_directory(self, path):
        """Override directory listing with a sortable ls -l style table."""
        try:
            entries = list(os.scandir(path))
        except PermissionError:
            self.send_error(403, 'Permission denied')
            return None

        # Directories first, then files; each group sorted case-insensitively
        entries.sort(key=lambda e: (not e.is_dir(), e.name.lower()))

        width = _read_width_config()
        css = CSS.replace('CONTENT_WIDTH', width)
        display_path = html_module.escape(self.path)

        rows = []
        if self.path != '/':
            rows.append(
                '<tr>'
                '<td><a href="../">../</a></td>'
                '<td class="size">—</td>'
                '<td class="date">—</td>'
                '</tr>'
            )

        for entry in entries:
            try:
                stat = entry.stat()
            except OSError:
                continue
            is_dir = entry.is_dir()
            name = html_module.escape(entry.name)
            href = name + ('/' if is_dir else '')
            label = name + ('/' if is_dir else '')
            size = '—' if is_dir else _human_size(stat.st_size)
            mtime = datetime.datetime.fromtimestamp(stat.st_mtime).strftime('%Y-%m-%d %H:%M')
            rows.append(
                f'<tr>'
                f'<td><a href="{href}">{label}</a></td>'
                f'<td class="size">{size}</td>'
                f'<td class="date">{mtime}</td>'
                f'</tr>'
            )

        table = (
            '<table>'
            '<thead><tr>'
            '<th>Name</th>'
            '<th style="text-align:right">Size</th>'
            '<th>Modified</th>'
            '</tr></thead>'
            '<tbody>' + ''.join(rows) + '</tbody>'
            '</table>'
        )

        page = (
            f'<!DOCTYPE html><html><head>'
            f'<meta charset="utf-8"><title>Index of {display_path}</title>'
            f'{css}</head><body>'
            f'<h2>Index of {display_path}</h2>'
            f'{table}'
            f'</body></html>'
        ).encode('utf-8')

        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(page)))
        self.end_headers()
        return io.BytesIO(page)

    def send_head(self):
        width = _read_width_config()
        path = self.translate_path(self.path)

        # Markdown — rendered to HTML
        if HAS_MARKDOWN and os.path.isfile(path) and path.endswith('.md'):
            try:
                with open(path, 'r', encoding='utf-8') as f:
                    source = f.read()
                title = html_module.escape(os.path.basename(path))
                body = markdown.markdown(
                    source,
                    extensions=['fenced_code', 'tables', 'toc'],
                    tab_length=2
                )
                css = CSS.replace('CONTENT_WIDTH', width)
                page = (
                    f'<!DOCTYPE html><html><head>'
                    f'<meta charset="utf-8"><title>{title}</title>'
                    f'{css}</head><body>{body}</body></html>'
                )
                encoded = page.encode('utf-8')
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', str(len(encoded)))
                self.end_headers()
                return io.BytesIO(encoded)
            except Exception:
                pass  # fall through to default handler

        # JSON — parsed and pretty-printed (stdlib json, no extra packages needed)
        if os.path.isfile(path) and path.endswith('.json'):
            try:
                with open(path, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                pretty = json.dumps(data, indent=2, ensure_ascii=False)
                encoded = _code_page(os.path.basename(path), pretty, width)
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', str(len(encoded)))
                self.end_headers()
                return io.BytesIO(encoded)
            except Exception:
                pass  # fall through to default handler (invalid JSON served raw)

        # YAML — displayed as-is in a styled code block (raw YAML is already readable;
        # re-serializing with pyyaml would change formatting in unexpected ways)
        if os.path.isfile(path) and path.endswith(('.yaml', '.yml')):
            try:
                with open(path, 'r', encoding='utf-8') as f:
                    source = f.read()
                encoded = _code_page(os.path.basename(path), source, width)
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', str(len(encoded)))
                self.end_headers()
                return io.BytesIO(encoded)
            except Exception:
                pass  # fall through to default handler

        return super().send_head()

    def log_message(self, fmt, *args):
        pass  # suppress access logs


if __name__ == '__main__':
    os.chdir('/home/developer/www')
    httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 8080), PreviewHandler)
    httpd.serve_forever()
PREVIEW_SERVER
chmod +x /usr/local/bin/fre-web-preview

cat > /etc/systemd/system/web-preview.service << 'EOF'
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
EOF

systemctl daemon-reload
systemctl enable web-preview.service
systemctl start web-preview.service
echo "Web preview server enabled on port 8080 (markdown rendering active)."

# ---------------------------------------------------------------------------
# Global Claude Code instructions for all sessions on this instance
# ---------------------------------------------------------------------------
mkdir -p /home/developer/.claude
cat > /home/developer/.claude/CLAUDE.md << 'EOF'
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
EOF

chown -R developer:developer /home/developer/.claude
echo "Global Claude Code instructions written."
