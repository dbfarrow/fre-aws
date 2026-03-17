# User Guide

Your AWS development environment is already set up — your admin has provisioned a dedicated EC2 instance just for you. This guide walks you through the one-time setup needed to connect to it.

**Time to complete: about 15 minutes.**

---

## What You Need

| Requirement | Notes |
|-------------|-------|
| **Mac** | These instructions are Mac-specific |
| **Container runtime** | [Docker Desktop](https://www.docker.com/products/docker-desktop/), [OrbStack](https://orbstack.dev), or [Rancher Desktop](https://rancherdesktop.io) — install one if you haven't already |
| **`git`** | Pre-installed on macOS. If missing: `xcode-select --install` |
| **Onboarding email** | Sent by your admin — contains your SSH key, AWS config, and user.env |

---

## Setup Steps at a Glance

1. [Clone this repository](#step-1--clone-this-repository)
2. [Save the files from your onboarding email](#step-2--save-your-onboarding-files)
3. [Log in to AWS](#step-3--log-in-to-aws)
4. [Connect](#step-4--connect)

---

## Step 1 — Clone this repository

```bash
git clone <repo-url>
cd fre-aws
```

---

## Step 2 — Save your onboarding files

Your admin sends you an email with three attachments. Save them as follows:

**SSH key** (if included — skip if you supplied your own public key):
```bash
cp ~/Downloads/fre-claude ~/.ssh/fre-claude
chmod 600 ~/.ssh/fre-claude
```

Then add the public key to GitHub so git push/pull works from your instance:
1. Copy the public key: `ssh-keygen -y -f ~/.ssh/fre-claude | pbcopy`
2. In GitHub: **Settings → SSH and GPG keys → New SSH key** → paste it

**AWS config:**
```bash
mkdir -p ~/.aws
cp ~/Downloads/aws-config ~/.aws/config
```

**User config:**
```bash
cp ~/Downloads/user.env config/user.env
```

---

## Step 3 — Log in to AWS

```bash
./user.sh sso-login
```

A URL and a short code will be printed in your terminal. Open the URL in your browser, enter the code, and approve the request. The terminal will continue automatically once you approve.

> You'll need to do this once per day — SSO sessions expire after 8–12 hours.

---

## Step 4 — Connect

Once your admin confirms your instance is ready:

```bash
./user.sh connect
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
./user.sh sso-login  # log in to AWS (once per day, when your session expires)
./user.sh start      # start your instance (if it's stopped)
./user.sh connect    # connect to your instance
./user.sh stop       # stop your instance when done for the day
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

When you choose "Clone a GitHub repo", your local SSH key is forwarded to the EC2 instance. As long as the key you saved in Step 2 is added to your GitHub account, cloning private repos works automatically — no setup needed on the instance.

---

## Troubleshooting

**`ERROR: Could not export credentials`**
Your AWS SSO session has expired. Run `./user.sh sso-login` to re-authenticate, then try again.

**`ERROR: No instance found for user '...'`**
Your instance may be stopped. Run `./user.sh start`, wait about 30 seconds, then try `./user.sh connect` again. If it's still not found, contact your admin — your instance may not have been provisioned yet.

**`ForbiddenException: No access` after SSO login**
The browser login succeeded but your AWS user hasn't been granted access to the account — this is an admin-side setup step. Contact your admin and ask them to verify you're assigned the `DeveloperAccess` permission set in IAM Identity Center.

**`ERROR: SSH key not found at ~/.ssh/fre-claude`**
Complete Step 2 — the SSH key must be saved at exactly `~/.ssh/fre-claude`.

**`kex_exchange_identification: Connection closed by remote host`**
The SSH tunnel through SSM failed. Most common causes:
1. Credentials aren't valid — run `./user.sh sso-login` and try again
2. Instance isn't running — run `./user.sh start` first
3. Instance is unhealthy — contact your admin

**Instance feels slow or unresponsive**
Some workloads (browser automation, large builds) need more RAM than the default instance. Let your admin know — they can resize it.

**Lost your work**
Your files live on an EBS volume that persists even when the instance is stopped. They're only deleted if your admin explicitly destroys the environment. Check `~/repos` after connecting.

---

## That's it

Once you're connected, Claude Code is ready. Type `claude` at any time to start a session, or it will launch automatically when you select a project from the menu.
