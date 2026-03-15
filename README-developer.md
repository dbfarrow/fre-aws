# Getting Started with Claude Code

Your AWS development environment is already set up — your admin has provisioned a dedicated EC2 instance just for you. This guide walks you through the one-time setup needed to connect to it.

**Time to complete: about 15 minutes.**

---

## Setup Steps at a Glance

1. [Clone this repository](#step-1--clone-this-repository)
2. [Create your SSH key](#step-2--create-your-ssh-key) — and send the public key to your admin
3. [Set up AWS credentials](#step-3--set-up-aws-credentials)
4. [Create your developer config](#step-4--create-your-developer-config)
5. [Connect](#step-5--connect)

---

## What You Need

| Requirement | Notes |
|-------------|-------|
| **Mac** | These instructions are Mac-specific |
| **Container runtime** | [Docker Desktop](https://www.docker.com/products/docker-desktop/), [OrbStack](https://orbstack.dev), or [Rancher Desktop](https://rancherdesktop.io) — install one if you haven't already |
| **`git`** | Pre-installed on macOS. If missing: `xcode-select --install` |
| **From your admin** | SSO Start URL, your username, AWS region, project name |

---

## Step 1 — Clone this repository

```bash
git clone <repo-url>
cd fre-aws
```

---

## Step 2 — Create your SSH key

This key gives you SSH access to your EC2 instance and lets git push/pull to GitHub work from the instance — without ever storing your private key on the remote machine.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/fre-claude -C "fre-claude"
```

You'll be prompted for a passphrase. Setting one is recommended — you'll only need to enter it once per session when connecting.

### Add the public key to GitHub

This is what enables `git clone`, `git push`, and `git pull` from your EC2 instance:

1. Copy your public key to the clipboard:
   ```bash
   cat ~/.ssh/fre-claude.pub | pbcopy
   ```

2. In GitHub: **Settings → SSH and GPG keys → New SSH key**
   - Title: `fre-claude`
   - Key type: **Authentication Key**
   - Paste the key and save

### Send the public key to your admin

Your admin needs your public key to install it on your EC2 instance.

```bash
cat ~/.ssh/fre-claude.pub
```

Copy that output and send it to your admin. They'll confirm when your instance is ready.

---

## Step 3 — Set up AWS credentials

Your admin will give you a **SSO Start URL** and a username for the AWS access portal.

1. Create your AWS config file from the provided template:
   ```bash
   mkdir -p ~/.aws
   cp config/aws-config-sso-developer.example ~/.aws/config
   ```

2. Open `~/.aws/config` in any text editor and replace the four `UPPER_CASE` values:

   | Placeholder | What to put there |
   |-------------|-------------------|
   | `YOUR_12_DIGIT_ACCOUNT_ID` | Your admin's AWS account ID (they'll provide this) |
   | `YOUR_PORTAL_ID` | The ID from your SSO Start URL (e.g. `d-abc12345` from `https://d-abc12345.awsapps.com/start`) |
   | `YOUR_SSO_REGION` | The region in your SSO URL, or ask your admin |
   | `YOUR_DEPLOY_REGION` | The AWS region your admin deployed to (e.g. `us-west-2`) |

   > **Important:** The `[profile claude-code]` line must start at the very beginning of the line with no leading spaces. If you use TextEdit, choose **Format → Make Plain Text** before saving.

---

## Step 4 — Create your developer config

```bash
cp config/developer.env.example config/developer.env
```

Open `config/developer.env` and fill in your values:

```bash
MY_USERNAME=yourname        # ← the username your admin told you
AWS_PROFILE=claude-code     # leave as-is (matches ~/.aws/config)
AWS_REGION=us-west-2        # ← the region your admin told you
PROJECT_NAME=fre-aws        # ← the project name your admin told you
GIT_USER_NAME=Your Name     # ← your name for git commits
GIT_USER_EMAIL=you@co.com   # ← your email for git commits
```

---

## Step 5 — Connect

Once your admin confirms your instance is ready:

```bash
./dev.sh connect
```

The first time you run this, you'll be prompted to log in to AWS:
- A URL and a short code will be printed in the terminal
- Open the URL in your browser, enter the code, and approve the request
- The terminal will automatically continue once you approve

You'll then be prompted for your SSH key passphrase — enter it once and you're in.

**You should see a menu like this:**

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
./dev.sh start      # start your instance (if it's stopped)
./dev.sh connect    # connect to your instance
./dev.sh stop       # stop your instance when done for the day
```

**Stop your instance when you're not using it.** A stopped instance doesn't incur compute charges, but your data is preserved on disk.

### Your session menu

Each time you connect, you'll see a menu:

- **Locally-cloned repos** — any repos in `~/repos` appear here; select one to launch Claude Code in that project
- **Clone a GitHub repo** — prompts for owner/repo (e.g. `mycompany/my-project`), clones via SSH
- **Create a new project** — prompts for a name, creates a new empty directory
- **Open a shell** — drops you into bash without launching Claude Code

### Cloning a private repo

When you choose "Clone a GitHub repo", your local SSH key is forwarded to the EC2 instance. As long as the key you created in Step 2 is added to your GitHub account, cloning private repos will work automatically.

---

## Troubleshooting

**`ERROR: No instance found for user '...'`**
Your instance may be stopped. Run `./dev.sh start`, wait about 30 seconds, then try `./dev.sh connect` again.

**`ERROR: Could not export credentials`**
Your AWS SSO session has expired. Run `./dev.sh connect` again — it will prompt you to log in through your browser.

**`ERROR: SSH key not found at ~/.ssh/fre-claude`**
Complete Step 2 (create the SSH key) and make sure it's saved at `~/.ssh/fre-claude`.

**Instance feels slow or unresponsive**
Some projects (especially those involving browser automation or large builds) need more RAM than the default instance provides. Let your admin know — they can resize your instance.

**Lost your work**
Your files live on an EBS volume that persists even when the instance is stopped. They are only deleted if your admin explicitly destroys the environment. If something seems missing, check `~/repos` after connecting.

---

## That's it

Once you're connected, Claude Code is ready to use. Type `claude` at any time to start a session, or it will launch automatically when you select a project from the menu.
