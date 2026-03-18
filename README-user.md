# User Guide

Your AWS development environment is already set up — your admin has provisioned a dedicated EC2 instance just for you. This guide walks you through the one-time setup needed to connect to it.

**Time to complete: about 10 minutes.**

> **New to this?** Before diving in, [How it works](README-how-it-works.md) explains the mental model — two places, three services, and why you log in differently to each one.

---

## What You Need

| Requirement | Notes |
|-------------|-------|
| **Mac** | These instructions are Mac-specific |
| **Container runtime** | [Docker Desktop](https://www.docker.com/products/docker-desktop/), [OrbStack](https://orbstack.dev), or [Rancher Desktop](https://rancherdesktop.io) — install one if you haven't already |
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

Install one of the following container runtimes if you haven't already:

- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- [OrbStack](https://orbstack.dev) *(lighter weight, recommended for Mac)*
- [Rancher Desktop](https://rancherdesktop.io)

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
~/fre-aws/user.sh start      # start your instance (if it's stopped)
~/fre-aws/user.sh connect    # connect to your instance
~/fre-aws/user.sh stop       # stop your instance manually (optional — see below)
```

**Instances stop automatically when idle.** When you exit Claude and close your tmux session, the instance detects no active sessions and shuts itself down after about 10 minutes. A stopped instance doesn't incur compute charges, but your files are preserved on disk. You can also stop it manually at any time with `./user.sh stop`.

---

## Your session menu

Each time you connect, you'll see a menu:

- **Locally-cloned repos** — any repos in `~/repos` appear numbered at the top; select one to open Claude Code in that project
- **`c` — Clone a GitHub repo** — authenticates with GitHub if needed (browser code flow, one-time per instance), then shows a numbered list of your repos to choose from; clone the selected repo with one keypress
- **`n` — New project** — prompts for a name, creates a new empty directory in `~/repos`
- **`s` — Shell** — drops you into bash without launching Claude Code

### Session persistence

Each repo opens in a named **tmux** session. If your SSH connection drops (or you close your laptop), the session keeps running on the instance. The next time you connect and select the same repo, you'll be reattached to the same session — Claude Code and your conversation history right where you left them.

`claude --continue` is used automatically on every launch, so your conversation context is always restored even after a fresh connect.

### Cloning private repos

When you choose "Clone a GitHub repo", you'll be prompted to authenticate with GitHub the first time using a browser-based code flow — the same kind of flow used for AWS SSO and Claude login. Your OAuth token is stored on your instance, so subsequent sessions skip the prompt. Private repos you have access to appear in the numbered list automatically.

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
Your instance may be stopped. Run `~/fre-aws/user.sh start`, wait about 30 seconds, then try `~/fre-aws/user.sh connect` again. If it's still not found, contact your admin — your instance may not have been provisioned yet.

**`ForbiddenException: No access` after SSO login**
The browser login succeeded but your AWS user hasn't been granted access to the account — this is an admin-side setup step. Contact your admin and ask them to verify you're assigned the `DeveloperAccess` permission set in IAM Identity Center.

**`ERROR: No SSH key found`**
The installer normally places your SSH key at `~/fre-aws/.ssh/fre-claude`. If it's missing, re-run the installer from Step 3. If the link has expired, ask your admin to run `./admin.sh publish-installer <your-username>` to generate a fresh one. If re-running the installer doesn't help, ask your admin to run `./admin.sh update-user-key <your-username>` to generate a new key and send a new installer link.

**`kex_exchange_identification: Connection closed by remote host`**
The SSH tunnel through SSM failed. Most common causes:
1. Credentials aren't valid — run `~/fre-aws/user.sh sso-login` and try again
2. Instance isn't running — run `~/fre-aws/user.sh start` first
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
