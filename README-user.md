# Getting Started with Claude Code

Your AWS development environment is already set up — your admin has provisioned a dedicated EC2 instance just for you. This guide walks you through the one-time setup needed to connect to it.

**Time to complete: about 15 minutes.**

---

## Setup Steps at a Glance

1. [Clone this repository](#step-1--clone-this-repository)
2. [Save the files from your onboarding email](#step-2--save-your-onboarding-files)
3. [Connect](#step-3--connect)

---

## What You Need

| Requirement | Notes |
|-------------|-------|
| **Mac** | These instructions are Mac-specific |
| **Container runtime** | [Docker Desktop](https://www.docker.com/products/docker-desktop/), [OrbStack](https://orbstack.dev), or [Rancher Desktop](https://rancherdesktop.io) — install one if you haven't already |
| **`git`** | Pre-installed on macOS. If missing: `xcode-select --install` |
| **From your admin** | An onboarding email with your SSH key, AWS config, and user.env attached |

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

## Step 3 — Connect

Once your admin confirms your instance is ready (they'll run `./admin.sh up` after adding you):

```bash
./user.sh connect
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
./user.sh start      # start your instance (if it's stopped)
./user.sh connect    # connect to your instance
./user.sh stop       # stop your instance when done for the day
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
Your instance may be stopped. Run `./user.sh start`, wait about 30 seconds, then try `./user.sh connect` again.

**`ERROR: Could not export credentials`**
Your AWS SSO session has expired. Run `./user.sh connect` again — it will prompt you to log in through your browser.

**`ForbiddenException: No access` after SSO login**
The browser login succeeded but your AWS user hasn't been granted access to the account. This is an admin-side setup step — contact your admin and ask them to verify:
- You are assigned to the AWS account (not just the IAM Identity Center directory) with the `DeveloperAccess` permission set
- The `sso_role_name` in your `~/.aws/config` matches the permission set name exactly

While waiting, you and your admin can confirm which accounts and roles your SSO token can actually see. Inside `./admin.sh shell` (or anywhere with the AWS CLI):
```bash
TOKEN=$(jq -r 'select(.accessToken) | .accessToken' ~/.aws/sso/cache/*.json | head -1)
aws sso list-accounts --access-token "$TOKEN"
```
If your account appears, check the available role names:
```bash
aws sso list-account-roles --account-id <account-id> --access-token "$TOKEN"
```
The `roleName` returned must match `sso_role_name` in your `~/.aws/config`.

**`ERROR: SSH key not found at ~/.ssh/fre-claude`**
Complete Step 2 (create the SSH key) and make sure it's saved at `~/.ssh/fre-claude`.

**`kex_exchange_identification: Connection closed by remote host`**
The SSH tunnel through SSM failed to establish. Most common causes:
1. AWS credentials aren't valid — run `./user.sh connect` fresh to trigger a new SSO login
2. Your instance isn't running — run `./user.sh start` first
3. Contact your admin to verify your instance is healthy: `./admin.sh ssm <username>`

**Instance feels slow or unresponsive**
Some projects (especially those involving browser automation or large builds) need more RAM than the default instance provides. Let your admin know — they can resize your instance.

**Lost your work**
Your files live on an EBS volume that persists even when the instance is stopped. They are only deleted if your admin explicitly destroys the environment. If something seems missing, check `~/repos` after connecting.

---

## That's it

Once you're connected, Claude Code is ready to use. Type `claude` at any time to start a session, or it will launch automatically when you select a project from the menu.
