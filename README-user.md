# User Guide

Your AWS development environment is already set up — your admin has provisioned a dedicated EC2 instance just for you. This guide walks you through the one-time setup needed to connect to it.

**Time to complete: about 10 minutes.**

---

## What You Need

| Requirement | Notes |
|-------------|-------|
| **Mac** | These instructions are Mac-specific |
| **Container runtime** | [Docker Desktop](https://www.docker.com/products/docker-desktop/), [OrbStack](https://orbstack.dev), or [Rancher Desktop](https://rancherdesktop.io) — install one if you haven't already |
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
- Install your SSH key at `~/.ssh/fre-claude`
- Install your AWS config at `~/.aws/config`

> **Add your SSH key to GitHub** so git push/pull works from your instance:
> 1. Copy your public key: `ssh-keygen -y -f ~/.ssh/fre-claude | pbcopy`
> 2. In GitHub: **Settings → SSH and GPG keys → New SSH key** → paste it

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

You'll be prompted for your SSH key passphrase — enter it once and you're in.

**You should see a session launcher like this:**

```
╔═══════════════════════════════════════════╗
║     Claude Code — Session Launcher        ║
╚═══════════════════════════════════════════╝

  No repos found in ~/repos yet.

   1) Clone a GitHub repo
   2) Create a new project
   3) Open a shell

Enter choice [1]:
```

---

## Daily use

```bash
~/fre-aws/user.sh sso-login  # log in to AWS (once per day, when your session expires)
~/fre-aws/user.sh start      # start your instance (if it's stopped)
~/fre-aws/user.sh connect    # connect to your instance
~/fre-aws/user.sh stop       # stop your instance when done for the day
```

**Stop your instance when you're not using it.** A stopped instance doesn't incur compute charges, but your files are preserved on disk.

---

## Your session menu

Each time you connect, you'll see a menu:

- **Locally-cloned repos** — any repos in `~/repos` appear at the top; select one to launch Claude Code in that project
- **Clone a GitHub repo** — prompts for owner/repo (e.g. `mycompany/my-project`), clones via SSH
- **Create a new project** — prompts for a name, creates a new empty directory in `~/repos`
- **Open a shell** — drops you into bash without launching Claude Code

### Cloning private repos

When you choose "Clone a GitHub repo", your local SSH key is forwarded to the EC2 instance. As long as the key installed in Step 3 is added to your GitHub account, cloning private repos works automatically — no setup needed on the instance.

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

**`ERROR: SSH key not found at ~/.ssh/fre-claude`**
The installer places this file automatically. Re-run the installer from Step 3, or copy it manually from the bundle.

**`kex_exchange_identification: Connection closed by remote host`**
The SSH tunnel through SSM failed. Most common causes:
1. Credentials aren't valid — run `~/fre-aws/user.sh sso-login` and try again
2. Instance isn't running — run `~/fre-aws/user.sh start` first
3. Instance is unhealthy — contact your admin

**Instance feels slow or unresponsive**
Some workloads (browser automation, large builds) need more RAM than the default instance. Let your admin know — they can resize it.

**Lost your work**
Your files live on an EBS volume that persists even when the instance is stopped. They're only deleted if your admin explicitly destroys the environment. Check `~/repos` after connecting.

---

## That's it

Once you're connected, Claude Code is ready. Type `claude` at any time to start a session, or it will launch automatically when you select a project from the menu.
