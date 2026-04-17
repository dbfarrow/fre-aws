# CLI User Guide

Your AWS development environment is already set up — your admin has provisioned a dedicated EC2 instance just for you. This guide walks you through the one-time setup needed to connect to it.

**Time to complete: about 10 minutes.**

> **Browser path available.** If your admin sent you a link instead of a setup zip, you can connect entirely from a browser — no Docker, no install required. See the [Browser Access Guide](README-user-web.md) instead.

> **New to this?** Before diving in, [How it works](README-how-it-works.md) explains the mental model — two places, three services, and why you log in differently to each one.

---

## Two ways to interact

**Via `user.sh` (default):** Every command runs inside a Docker container — AWS CLI, the SSM plugin, rsync, and all scripts are packaged in the image. The only local requirement is Docker. This is the default and works for everyone out of the box.

**Directly:** If you already have the required tools installed locally (AWS CLI v2, SSM Session Manager plugin, SSH client), you can call the scripts in `~/fre-aws/scripts/` without going through Docker. Same config files, same behaviour, less overhead.

```bash
# Docker-wrapped
~/fre-aws/user.sh connect

# Direct (requires local AWS CLI + SSM plugin)
~/fre-aws/scripts/connect.sh
```

Both approaches read from `config/user.env` — no config changes needed when switching between them.

---

## What You Need

| Requirement | Notes |
|-------------|-------|
| **Mac or Windows** | macOS or Windows with WSL2 — see note below for Windows setup |
| **Container runtime** | **macOS**: [Docker Desktop](https://www.docker.com/products/docker-desktop/), [OrbStack](https://orbstack.dev), or [Rancher Desktop](https://rancherdesktop.io) — **Windows**: [Docker Desktop](https://www.docker.com/products/docker-desktop/) with WSL2 backend |
| **Claude Code account** | Create your account at [claude.ai/code](https://claude.ai/code) before your first session — your admin cannot do this for you |
| **GitHub account** | Needed to clone and push to private repos — create one at [github.com](https://github.com) if you don't have one. Your admin cannot do this for you. No SSH key setup required — authentication uses a browser-based code flow. |
| **Onboarding email** | Sent by your admin — contains a one-time installer download link |

> **No `git` required.** The installer handles everything.

---

## Setup Steps at a Glance

1. [Install Docker](#step-1--install-docker)
2. [Activate your AWS account](#step-2--activate-your-aws-account)
3. [Run the installer](#step-3--run-the-installer)
4. [Log in to AWS](#step-4--log-in-to-aws)
5. [Connect](#step-5--connect)

---

## Step 1 — Install Docker

**macOS:** Install one of the following container runtimes if you haven't already:

- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- [OrbStack](https://orbstack.dev) *(lighter weight, recommended for Mac)*
- [Rancher Desktop](https://rancherdesktop.io)

**Windows:** Set up WSL2 first, then install Docker Desktop with the WSL2 backend:

1. Open PowerShell as Administrator and run: `wsl --install`
2. Restart your computer when prompted
3. Install [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/) and enable the WSL2 backend (Settings → General → "Use the WSL 2 based engine")
4. Run all subsequent steps from your **WSL2 terminal**, not PowerShell or CMD

> **Windows only:** Run the installer and all `~/fre-aws/user.sh` commands from inside the WSL2 terminal.

---

## Step 2 — Activate your AWS account

Your onboarding email includes the AWS SSO portal URL and your username. Before you can log in:

1. Go to the portal URL from your email
2. Click **"Forgot password"**
3. Enter your email address
4. Check your inbox for a verification email from AWS and follow the link to set your password

> Your AWS login name is your **username** (e.g. `alice`) — not your email address.

---

## Step 3 — Run the installer

Your onboarding email includes a download link that expires in **72 hours**. Copy the three commands from the email and run them in Terminal:

```bash
curl -fsSL '<url-from-your-email>' -o /tmp/fre-setup.zip
unzip -d /tmp/fre-setup /tmp/fre-setup.zip
bash /tmp/fre-setup/install.sh
```

The installer will:
- Copy everything into `~/fre-aws/`
- Install your SSH key at `~/fre-aws/.ssh/fre-claude`
- Install your AWS config at `~/fre-aws/.aws/config` (kept separate from `~/.aws` — your other AWS profiles are untouched)

> **Link expired?** Contact your admin and ask them to run `./admin.sh publish-installer <your-username>` to generate a new one.

---

## Step 4 — Log in to AWS

```bash
~/fre-aws/user.sh sso-login
```

A URL and a short code will be printed in your terminal. Open the URL in your browser, enter the code, and approve the request. The terminal will continue automatically once you approve.

> You'll need to do this once per day — SSO sessions expire after 8–12 hours.

---

## Step 5 — Connect

Once your admin confirms your instance is ready:

```bash
~/fre-aws/user.sh connect
```

Your SSH key passphrase is handled automatically — no prompt needed.

**You should see a session launcher like this (first connect — no repos yet):**

```
╔═══════════════════════════════════════╗
║     Claude Code Development Env       ║
╚═══════════════════════════════════════╝

   c) Clone a GitHub repo
   n) New project
   s) Shell

Choose [c]:
```

**After cloning a repo, it appears at the top by number:**

```
╔═══════════════════════════════════════╗
║     Claude Code Development Env       ║
╚═══════════════════════════════════════╝

   1) my-project

   c) Clone a GitHub repo
   n) New project
   s) Shell

Choose [1]:
```

---

## Daily use

```bash
~/fre-aws/user.sh sso-login  # log in to AWS (once per day, when your session expires)
~/fre-aws/user.sh connect    # connect to your instance (offers to start it if stopped)
~/fre-aws/user.sh stop       # stop your instance manually (optional — see below)
```

**Instances stop automatically when idle.** When you exit Claude and close your tmux session, the instance detects no active sessions and shuts itself down after the idle period (30 minutes by default). A stopped instance doesn't incur compute charges, but your files are preserved on disk. You can also stop it manually at any time with `./user.sh stop`.

---

## Your session menu

Each time you connect, you'll see a menu:

- **Locally-cloned repos** — any repos in `~/repos` appear numbered at the top; select one to open Claude Code in that project
- **`c` — Clone a GitHub repo** — authenticates with GitHub if needed (browser code flow, one-time per instance), then shows a numbered list of your repos to choose from; clone the selected repo with one keypress
- **`n` — New project** — prompts for a name, creates a new empty directory in `~/repos`
- **`s` — Shell** — drops you into bash without launching Claude Code

### Session persistence

Each repo opens in a named **tmux** session. If your SSH connection drops (or you close your laptop), the session keeps running on the instance. The next time you connect, if you only have one active session running, you'll be reattached to it automatically — no menu, no selection needed. If you have multiple sessions running, the menu appears and you pick which one to rejoin. Either way, Claude Code and your conversation history are right where you left them.

`claude --continue` is used automatically on every launch, so your conversation context is always restored even after a fresh connect.

### Cloning private repos

When you choose "Clone a GitHub repo", you'll be prompted to authenticate with GitHub the first time using a browser-based code flow — the same kind of flow used for AWS SSO and Claude login. Your OAuth token is stored on your instance, so subsequent sessions skip the prompt. Private repos you have access to appear in the numbered list automatically.

---

## Web preview and file sharing

While you're connected, a web server is running on your instance and forwarded to your browser. Open **http://localhost:8080** to see a directory listing of your projects.

### Viewing Claude's output

When you ask Claude to create a web page, chart, or any visual output, it writes to the **web root** for your project (`~/www/<project>/`). Files there are immediately available at:

```
http://localhost:8080/<project>/
```

Claude will tell you the URL — just open it in your browser.

### Uploading files to Claude

To share a screenshot, image, reference file, or entire directory with Claude, use:

```bash
~/fre-aws/user.sh upload <file-or-directory>
```

If you have multiple projects, you'll see a numbered menu to pick which one. Or specify it directly:

```bash
~/fre-aws/user.sh upload screenshot.png my-project
~/fre-aws/user.sh upload reference-images/ my-project
```

Files land in `~/uploads/<project>/` on your instance. Directories are synced with rsync — re-uploading the same directory only transfers what changed. Everything uploaded is also browseable at `http://localhost:8080/<project>/uploads/`. Once uploaded, tell Claude "I uploaded a file" — it will check that directory.

### Running programs locally

Some programs need to run on your Mac — to reach local files, local services, or local credentials that EC2 can't access. The `run` command handles this: it downloads the project from EC2, runs the script in a Docker container on your machine, and uploads the output back to EC2 for Claude to read.

```bash
~/fre-aws/user.sh run <project> <script-path> [options] [-- script-args...]
```

Examples:

```bash
~/fre-aws/user.sh run myproject scripts/analyze.py
~/fre-aws/user.sh run myproject scripts/fetch.py --mount ~/Documents/data:/data
~/fre-aws/user.sh run myproject scripts/process.py --env-file ~/.secrets/myproject.env
~/fre-aws/user.sh run myproject scripts/analyze.py --mount ~/Downloads/input:/input -- --verbose
~/fre-aws/user.sh run myproject app.js --mount ~/Desktop/output:/output
```

**Options:**

| Option | Description |
|--------|-------------|
| `--mount local:container` | Mount a local path into the container (repeat for multiple mounts) |
| `--env-file <file>` | Load environment variables from a local `.env` file (KEY=VALUE format) |
| `--local` | Run without uploading output to EC2 — useful for testing |
| `--tty` | Allocate a TTY for interactive or TUI programs (output is not captured or uploaded) |
| `--` | Everything after `--` is passed as arguments to your script |

The runner is detected automatically from the file extension: `.py` → `python3`, `.js` → `node`, `.ts` → `npx ts-node`, `.sh` → `bash`. Other extensions are executed directly (requires a shebang line).

Output is streamed to your terminal and saved to `~/uploads/<project>/run-output.txt` on your instance. When Claude asks you to run something, it will tell you the exact command. After running, just say **"done"** — Claude will check the output file automatically.

**Python and Node dependencies** are installed automatically from `requirements.txt`, `uv.lock`, `pyproject.toml`, or `package.json` — nothing extra needed. If your project requires additional system packages (compiled libraries, native extensions), Claude will create a `.fre-run.dockerfile` that adds them via `apt-get`.

### Local shell (power users)

If you want to run programs interactively — editing files, running commands, inspecting output — without the full `run` round-trip, use `local-shell`. It drops you into a persistent Docker container that feels like your normal terminal: your shell (`$SHELL`), your dotfiles (`.zshrc`/`.bashrc`, `.vimrc`, `.vim/`, `.tmux.conf`), and your tools (`vim`, `tmux`, `uv`, `pip`, `node`, `npm`) are all there. Two short commands let you sync code and push results back to Claude.

```bash
~/fre-aws/user.sh local-shell <project>
```

Inside the shell:

```bash
csync                                 # pull latest project state from EC2
python scripts/analyze.py             # run directly — output goes to terminal
python scripts/analyze.py > output.txt && cpush   # capture and push to Claude
```

After `cpush`, tell Claude **"done"** — it will read `~/uploads/<project>/run-output.txt`.

**Dependency installation:** `csync` can install project dependencies automatically after syncing (`uv.lock`, `pyproject.toml`, `requirements.txt`, `package.json` — whichever is present). This is opt-in: set `LOCAL_SHELL_AUTO_INSTALL=true` in `user.env` to enable. The venv lives in the project directory on your Mac and is activated automatically the next time you enter the shell.

**Configuration (in `config/user.env`):**

| Variable | Description |
|----------|-------------|
| `LOCAL_SYNC_DIR` | Where projects are synced locally (default: `~/claude`). Projects land at `${LOCAL_SYNC_DIR}/<project>/`. |
| `LOCAL_SHELL_AUTO_INSTALL` | Set to `true` to automatically install dependencies after `csync` (default: `false`). |
| `LOCAL_MOUNTS_<project>` | Extra host paths to mount into the shell. Use the project name with hyphens replaced by underscores. Space-separated `host:container` pairs. |

Example `user.env` additions:

```bash
LOCAL_SYNC_DIR=~/myprojects
LOCAL_MOUNTS_sqrt_analysis=~/.sqrt:~/.sqrt
```

---

## Keeping your tools up to date

When your admin releases an update to the scripts, run:

```bash
~/fre-aws/user.sh update
```

This downloads the latest scripts from S3 and updates `~/fre-aws/scripts/` in place.

---

## Troubleshooting

**Link expired before I could install**
Contact your admin and ask them to run `./admin.sh publish-installer <your-username>` to generate a fresh link.

**`ERROR: Could not export credentials`**
Your AWS SSO session has expired. Run `~/fre-aws/user.sh sso-login` to re-authenticate, then try again.

**`ERROR: No instance found for user '...'`**
Your instance hasn't been provisioned yet. Contact your admin and ask them to run `./admin.sh up <your-username>`.

**`ForbiddenException: No access` after SSO login**
The browser login succeeded but your AWS user hasn't been granted access to the account — this is an admin-side setup step. Contact your admin and ask them to verify you're assigned the correct permission set in IAM Identity Center.

**`ERROR: No SSH key found`**
The installer normally places your SSH key at `~/fre-aws/.ssh/fre-claude`. If it's missing, re-run the installer from Step 3. If the link has expired, ask your admin to run `./admin.sh publish-installer <your-username>` to generate a fresh one. If re-running the installer doesn't help, ask your admin to run `./admin.sh update-user-key <your-username>` to generate a new key and send a new installer link.

**`kex_exchange_identification: Connection closed by remote host`**
The SSH tunnel through SSM failed. Most common causes:
1. Credentials aren't valid — run `~/fre-aws/user.sh sso-login` and try again
2. Instance isn't running — run `~/fre-aws/user.sh connect` again (it will offer to start it), or `~/fre-aws/user.sh start` first
3. Instance is unhealthy — contact your admin

**Instance feels slow or unresponsive**
Some workloads (browser automation, large builds) need more RAM than the default instance. Let your admin know — they can resize it.

**"Clone failed" when trying to clone a GitHub repo**
Your GitHub authentication may have expired or the repo name may be wrong. From a shell on the instance, run `gh auth status` to check. If not authenticated, run `gh auth login --git-protocol https` to re-authenticate.

**Lost your work**
Your files live on an EBS volume that persists even when the instance is stopped. They're only deleted if your admin explicitly destroys the environment. Check `~/repos` after connecting.

---

## That's it

Once you're connected, Claude Code launches automatically when you select a project from the menu. It opens with `--continue` so your conversation history is always restored.

> **First time only:** Claude Code will prompt you to log in with your Claude account the first time you run it. Make sure you've created your [Claude Code account](https://claude.ai/code) before connecting.
