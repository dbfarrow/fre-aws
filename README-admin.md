# Admin Guide

This guide covers everything an admin needs to set up and manage the fre-aws environment.

---

## Table of Contents

- [What You Need](#what-you-need)
- [SSH Key](#ssh-key)
- [Credential Setup](#credential-setup)
  - [Option A: IAM Identity Center (Recommended)](#option-a-iam-identity-center-recommended)
  - [Option B: IAM User with Access Keys (Free Tier)](#option-b-iam-user-with-access-keys-free-tier)
  - [Upgrading from Option B to Option A](#upgrading-from-option-b-to-option-a)
- [Email Setup (AWS SES)](#email-setup-aws-ses)
- [Local Configuration](#local-configuration)
- [Cost Considerations](#cost-considerations)
- [First-Time Setup](#first-time-setup)
- [Managing Users](#managing-users)
- [Browser App (Optional)](#browser-app-optional)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)

---

## What You Need

### On your machine

| Requirement | Notes |
|-------------|-------|
| Container runtime | **macOS**: [Docker Desktop](https://www.docker.com/products/docker-desktop/), [OrbStack](https://orbstack.dev), or [Rancher Desktop](https://rancherdesktop.io) — **Windows**: [Docker Desktop](https://www.docker.com/products/docker-desktop/) with WSL2 backend (see Windows/WSL2 note below) |
| `git` | Pre-installed on macOS (`xcode-select --install` if missing). Windows: use git inside WSL2 (`sudo apt install git`). |
| SSH key + GitHub account | You almost certainly have these already — see [SSH Key](#ssh-key) below |

> **Windows/WSL2 users:** This tooling runs inside WSL2. Before proceeding:
> 1. Install WSL2: run `wsl --install` in PowerShell (requires Windows 10 2004+ or Windows 11)
> 2. Install [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/) and enable the WSL2 backend (Settings → General → "Use the WSL 2 based engine")
> 3. Clone this repo **inside the WSL2 filesystem** (e.g. `~/fre-aws`) — do **not** clone under `/mnt/c/`; line endings and file permissions behave incorrectly there
> 4. Keep your SSH keys in `~/.ssh/` **within WSL2** — not in the Windows user profile
> 5. Run all `./admin.sh` commands from your WSL2 terminal

### In AWS

| Requirement | Notes |
|-------------|-------|
| AWS account | Any account — free tier, personal, or organizational |
| AdministratorAccess | Needed to run the initial `./admin.sh bootstrap`. Bootstrap creates a tighter `ProjectAdminAccess` permission set automatically — you'll switch to that for all ongoing work. See [Credential Setup](#credential-setup). |
| Root MFA | Strongly recommended. AWS Console → top-right menu → Security credentials → MFA. |

> **What bootstrap creates automatically**: S3 state bucket, DynamoDB lock table, KMS key, IAM permission sets (`ProjectAdminAccess` and `DeveloperAccess`).
>
> **What `up` creates automatically**: VPC, subnets, NAT Gateway (if configured), security groups, per-user EC2 instances and IAM roles, SSM access.

### Per user (cannot be automated)

Each person using an instance needs to set up two accounts before their first session — neither can be provisioned by the admin:

| Account | Why | Where |
|---------|-----|--------|
| **Claude Code** | Required to use Claude Code on their instance | [claude.ai/code](https://claude.ai/code) |
| **GitHub** | Required to clone and push to private repos | [github.com](https://github.com) |

Let users know to sign up for both before their onboarding email arrives. The session launcher handles GitHub authentication via a browser code flow on first use — no SSH key setup required, just an account.

---

## SSH Key

Admin connections use SSH tunneled through SSM. Your public key is injected into every user instance at provision time (and can be pushed to existing instances with `./admin.sh push-admin-keys`).

### Authentication (preferred: ssh-agent forwarding)

The preferred way to authenticate is to have your SSH key loaded in your `ssh-agent` before running any `./admin.sh` command. The tooling detects a running agent automatically and forwards its socket into the Docker container — no key file is mounted, no passphrase is prompted.

```bash
ssh-add ~/.ssh/id_ed25519   # load your key once per session
./admin.sh connect <user>   # connects with no further prompts
```

**macOS:** If you use macOS's built-in agent (Keychain), your key may already be loaded automatically and no `ssh-add` is needed at all.

**WSL2:** There is no automatic agent on WSL2. Add `eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519` to your `~/.bash_profile` or `~/.bashrc` to start an agent on each shell session, or run it manually before connecting.

### Fallback: key file

If no agent is running, the tooling falls back to mounting `~/.ssh` into the container and prompting for the key passphrase. The key is looked up in this order: `SSH_KEY_FILE` in `config/admin.env` → `~/.ssh/id_ed25519` → `~/.ssh/id_rsa`.

---

## Credential Setup

`./admin.sh bootstrap` requires **AdministratorAccess** — broad enough to create IAM roles, permission sets, S3 buckets, KMS keys, and more. Once bootstrap completes, it creates a tighter `ProjectAdminAccess` permission set scoped to what this project actually needs. After that one-time step, you reassign yourself to `ProjectAdminAccess` and drop AdministratorAccess — bootstrap is the only time you need the broader permissions.

The two options below describe how you hold that initial AdministratorAccess:

| | Option A: IAM Identity Center | Option B: IAM User (Free Tier) |
|---|---|---|
| **Requires** | AWS Organizations | Nothing beyond Docker and a text editor |
| **Credentials** | Short-lived, auto-expiring | Long-lived access keys |
| **MFA enforcement** | Built-in | Manual (strongly recommended) |
| **Best for** | Teams, any paid account | Free tier, solo development |

---

### Option A: IAM Identity Center (Recommended)

IAM Identity Center provides short-lived credentials and enforces MFA by design. It requires AWS Organizations, which is not available on free-tier standalone accounts but is available on any paid account.

> **No AWS CLI required on your machine.** All operations run inside Docker. Setup only requires the AWS Console and creating one text file.

**Steps:**

1. In the AWS Console, go to **AWS Organizations → Create an organization** (if not already done)

2. Search for **IAM Identity Center** and click **Enable**

3. Under **Users**, create a user for yourself:
   - **Username** — what you type at the portal login prompt
   - **Email address** — used for the activation link and password resets

   You will receive an email to activate the account and set a password.

4. **Create a temporary admin permission set** to run the initial bootstrap:
   - IAM Identity Center → Permission sets → Create → **Predefined policy** → `AdministratorAccess`
   - Under **AWS accounts**, assign yourself → `AdministratorAccess`

   > `./admin.sh bootstrap` will create `ProjectAdminAccess` (a tighter set) and `DeveloperAccess` automatically.
   > After bootstrap, you can reassign yourself to `ProjectAdminAccess` and drop `AdministratorAccess`.

5. Collect these values from the AWS Console:

   | Value | Where to find it |
   |-------|-----------------|
   | **SSO Start URL** | IAM Identity Center → Dashboard → **AWS access portal URL** |
   | **SSO Region** | IAM Identity Center → Settings → **Identity source** |
   | **Account ID** | Top-right corner of any AWS Console page (12-digit number) |

6. **Create `~/.aws/config`**:
   ```bash
   mkdir -p ~/.aws
   cp config/aws-config-sso.example ~/.aws/config
   ```
   Open `~/.aws/config` and replace the `UPPER_CASE` placeholders. Set `sso_role_name = AdministratorAccess` for now.

   > **WSL2 note:** `~/.aws` means the WSL2 home directory (e.g. `/home/<user>/.aws`), not the Windows path `C:\Users\...\.aws`. All AWS config used by this tooling lives inside WSL2.

7. **Log in**:
   ```bash
   ./admin.sh sso-login
   ```

8. **Verify**:
   ```bash
   ./admin.sh verify
   ```

> SSO sessions expire (typically 8–12 hours). Run `./admin.sh sso-login` again when prompted.

> **After running bootstrap**: Reassign yourself to `ProjectAdminAccess` in IAM Identity Center → AWS accounts, then update `sso_role_name = ProjectAdminAccess` in `~/.aws/config` and re-run `./admin.sh sso-login`.

---

### Option B: IAM User with Access Keys (Free Tier)

> **No AWS CLI required on your machine.** Setup only requires the AWS Console and creating two plain text files.

**Steps:**

1. **Do not use the root user.**

2. In the AWS Console, go to **IAM → Users → Create user**
   - Username: your name or `fre-aws-admin`
   - Leave "Provide user access to the AWS Management Console" **unchecked**

3. Attach `AdministratorAccess` policy directly

4. Open the user → **Security credentials** tab → **Create access key**
   - Use case: **Command Line Interface (CLI)**
   - Download the CSV — **the secret key is shown exactly once**

5. **Enable MFA** on the IAM user (Security credentials → MFA → Authenticator app)

6. **Create the AWS credentials files**:
   ```bash
   mkdir -p ~/.aws
   cp config/aws-credentials-keys.example ~/.aws/credentials
   cp config/aws-config-keys.example ~/.aws/config
   ```
   Fill in the `UPPER_CASE` placeholders in each file.

   > **WSL2 note:** `~/.aws` means the WSL2 home directory (e.g. `/home/<user>/.aws`), not the Windows path `C:\Users\...\.aws`.

7. **Verify**:
   ```bash
   ./admin.sh verify
   ```

---

### Upgrading from Option B to Option A

1. Enable AWS Organizations
2. Enable IAM Identity Center and follow the Option A steps
3. Delete `~/.aws/credentials`
4. Create `~/.aws/config` with the SSO profile
5. Run `./admin.sh sso-login`

No changes to Terraform or scripts needed — only the credential source changes.

---

## Email Setup (AWS SES)

`add-user` delivers SSH keys and AWS configs to new users via email. To enable it:

1. Add `SENDER_EMAIL=you@example.com` to `config/admin.env`
2. Run `./admin.sh bootstrap` — it triggers the SES verification email automatically
3. Click the link in the verification email from AWS

**SES sandbox**: New AWS accounts can only send to verified addresses. `add-user` and `publish-installer` handle this automatically:
- If the recipient is not yet verified, AWS sends them a verification email and the command exits cleanly with instructions
- Once the user clicks the verification link, run `./admin.sh publish-installer <username>` to send the onboarding email
- To send to *any* address without per-recipient verification: AWS Console → SES → Account dashboard → **Request production access** (takes 24–48 hours)

> If `SENDER_EMAIL` is not set (or `--no-email` is passed), `add-user` still completes but skips the email step. The installer bundle is available in S3 — generate a pre-signed URL with `./admin.sh publish-installer <username> --no-email`.

Two optional config variables customise the email appearance:
- `LOGO_URL` — HTTPS URL of a banner image shown at the top of the email. Omit for a clean text header.
- `REPO_URL` — Git clone URL included in admin onboarding emails so new admins know where to clone from.

---

## Local Configuration

`config/admin.env` is your personal admin settings file — **gitignored**, never committed.

```bash
cp config/admin.env.example config/admin.env
# Edit config/admin.env with your values
```

User configuration is stored in S3 (`<project>-tfstate/<project>/users.json`) and managed through the CLI — no manual file editing.

---

## Cost Considerations

### What is Free Tier eligible
- **EC2 t3.micro**: 750 hours/month for the first 12 months
- **EBS storage**: 30 GB/month free
- **S3**: 5 GB storage + limited requests free
- **DynamoDB**: 25 GB + 25 WCU/RCU free

### What is NOT free (costs money from day one)

| Resource | Approximate Cost | Notes |
|----------|-----------------|-------|
| **NAT Gateway** | ~$0.045/hr + data ≈ $33/month | Required for `private_nat` mode |
| **VPC endpoints (SSM)** | ~$0.01/hr × 3 ≈ $22/month | Alternative to NAT Gateway |
| **Spot instance** (after free tier) | 60–90% off on-demand | Default; significant savings |
| **KMS key** | $1/month per key | One key shared across all users |
| **Multiple EC2 instances** | Multiplied by number of users | Each user has their own instance |

### Browser app costs (when `ENABLE_WEB_APP=true`)

All three resources have generous free tiers and will cost effectively nothing for small teams:

| Resource | Free Tier | Beyond Free Tier |
|----------|-----------|-----------------|
| **Lambda** (API) | 1M requests/month | ~$0.20 per million |
| **API Gateway** | 1M requests/month (first 12 months) | ~$1 per million |
| **CloudFront** (static HTML) | 1 TB transfer + 10M requests/month | ~$0.01/GB |
| **SSM Parameter Store** | Standard parameters free | — |

For a team of 10 users each opening the dashboard a few times a day, monthly cost is negligible (cents or zero).

### Network configuration options

Controlled by `NETWORK_MODE` in `config/admin.env`. Applies to all instances.

| Mode | Cost | Security | Notes |
|------|------|----------|-------|
| `public` | $0 extra | Good | Default. EC2 has public IP but all inbound blocked by security group. |
| `private_nat` | ~$33/month | Better | EC2 in private subnet, outbound via NAT Gateway. |
| `private_endpoints` | ~$22/month | Best | Private subnet + VPC endpoints. EC2 cannot reach internet. |

**Recommendation**: Use `public` mode during development. Switch to `private_nat` before sharing with a wider team or handling sensitive data.

### Keeping costs low

- **Instances stop automatically when idle** — each instance runs an autoshutdown timer that monitors tmux session count. When a user exits Claude and closes their session, the instance shuts itself down after ~10 minutes of inactivity. A midnight Lambda provides a safety net for sessions that are detached but forgotten. No manual `stop` required under normal use.
- **Stop instances manually when needed** — `./admin.sh stop <username>`. A stopped EC2 incurs no compute charges.
- **Spot instances are on by default** — saves 60–90% once free tier expires.
- For heavy workloads (browser automation, large builds), use `INSTANCE_TYPE=t3.small` (2 GB RAM) or larger.

---

## First-Time Setup

```
1.  AWS account with AdministratorAccess                    ← any account; free tier works
    Enable root MFA while you're there                      ← AWS Console → Security credentials → MFA
2.  Set up credentials (Option A or B above)                ← one time
3.  Install Docker                                          ← one time (Mac: Docker Desktop/OrbStack/Rancher; Windows: Docker Desktop with WSL2 backend)
4.  Confirm SSH key in ssh-agent                            ← ssh-add ~/.ssh/id_ed25519; see SSH Key above
5.  Clone this repo                                         ← git clone ...
6.  cp config/admin.env.example config/admin.env            ← create your admin config
7.  Edit config/admin.env                                   ← set PROJECT_NAME, AWS_REGION,
                                                               SSO_REGION, SSO_START_URL,
                                                               SENDER_EMAIL, etc.
8.  ./admin.sh sso-login                                    ← authenticate (Option A only)
9.  ./admin.sh verify                                       ← confirm credentials work
10. ./admin.sh bootstrap                                    ← creates S3, DynamoDB, KMS,
                                                               permission sets, SES verification
                                                               (runs as AdministratorAccess)
11. Switch to ProjectAdminAccess                            ← bootstrap just created this set;
    (Option A) IAM Identity Center → AWS accounts              assign yourself to it, update
               assign yourself to ProjectAdminAccess            sso_role_name in ~/.aws/config,
               re-run ./admin.sh sso-login                      re-run sso-login
    (Option B) no action needed                             ← IAM user access keys are unchanged;
                                                               ProjectAdminAccess is for SSO users
12. ./admin.sh add-user                                     ← interactive wizard: adds a user,
                                                               creates IAM Identity Center account
                                                               and emails credentials (managed mode);
                                                               S3 registry entry only (external mode)
13. ./admin.sh up                                           ← provisions all AWS infrastructure
14. ./admin.sh connect <username>                           ← verify it works
```

---

## Managing Users

User configuration is stored in S3 and shared across all admins. The CLI keeps it in sync.

### Adding a user

```bash
./admin.sh add-user
```

The interactive wizard prompts for: username, full name, email, role (`user` or `admin`), SSH key (generate or provide), git name, and git email.

The wizard automatically:
- Creates an IAM Identity Center user and assigns the appropriate permission set(s) *(managed mode only)*
- Generates or accepts an SSH key pair for EC2 access *(external mode: own key required; no auto-generate)*
- Generates `user.env` and `~/.aws/config` files ready for the new user *(managed mode only)*
- Uploads onboarding files to S3 and builds a self-contained installer zip *(managed mode only)*
- Sends an onboarding email via SES (if `SENDER_EMAIL` is set; handles SES sandbox verification automatically) *(managed mode only)*

User and admin emails differ:
- **Users** receive a 72-hour pre-signed installer download link and step-by-step setup instructions
- **Admins** receive an email with the deployment-specific config values to paste into their `.env` file, the full `~/.aws/config` stanza (both profiles, inlined — no file to copy), and the repo clone URL

The user installs with a single `curl + unzip + bash` one-liner — no `git` required on their Mac.

After `add-user`, run `./admin.sh up` to provision their EC2 instance.

**Note** *(managed mode)*: `SSO_REGION` and `SSO_START_URL` must be set in `config/admin.env`. `SENDER_EMAIL` is required unless you pass `--no-email`. In external mode (`IDENTITY_MODE=external`), none of these are required — only S3 registry and EC2 operations run.

Pass `--no-email` to skip sending and print the installer URL to the console instead:

```bash
./admin.sh add-user --no-email
./admin.sh add-user <file> --no-email
```

#### Admin vs user role

| Role | Permission sets | `admin.sh` access | `user.sh` access |
|------|----------------|-------------------|------------------|
| `user` | `DeveloperAccess` | None | Connect, start, stop |
| `admin` | `ProjectAdminAccess` + `DeveloperAccess` | Full | Connect, start, stop |

Admin users receive a two-profile `~/.aws/config`: `claude-code` (ProjectAdminAccess, for `admin.sh`) and `claude-code-dev` (DeveloperAccess, for `connect`). Running `./admin.sh verify` confirms both profiles are active.

### Updating a user's SSH key

```bash
./admin.sh update-user-key <username>
```

Two modes:

- **Auto-generate (default)** — creates a fresh ed25519 key pair, stores the passphrase in Secrets Manager, pushes the new public key directly to the running instance via SSM, and generates a new installer bundle. A new pre-signed URL is printed — send it to the user so they can re-run the installer. **No `./admin.sh up` required.**
- **Provide a public key** — accepts a key the user supplies (e.g. they manage their own key). Updates the registry and pushes to the running instance via SSM.

### Removing a user

```bash
./admin.sh remove-user <username>
```

`remove-user` destroys the user's EC2 instance and EBS volume, then removes them from the registry in a single step. Their IAM Identity Center account is also deleted unless you pass `--keep-sso` (useful when you want to re-add the same username later without re-doing AWS account setup).

### Re-sending the installer link

The pre-signed installer URL expires after 72 hours. To generate a fresh one:

```bash
./admin.sh publish-installer <username>
./admin.sh publish-installer <username> --no-email   # print URL only, skip email
```

This uploads a new `latest.zip` to S3, re-sends the onboarding email (if `SENDER_EMAIL` is set), and prints the pre-signed URL. Useful after the initial link expires or after scripts are updated.

### Sending a browser app link

If the browser app is enabled (`ENABLE_WEB_APP=true` and `WEB_APP_URL` set in `config/admin.env`), you can send a user a signed browser access link instead of (or in addition to) the installer:

```bash
./admin.sh publish-app-link <username>
./admin.sh publish-app-link <username> --no-email    # print URL only, skip email
```

This generates a 72-hour signed magic link and prints the URL. If `SENDER_EMAIL` is set in `config/admin.env`, it also emails the link to the user automatically.

The link logs the user in without a password and redirects to their personal dashboard. They can start their instance and open an SSM terminal entirely from the browser — no Docker or AWS credentials required.

> **WEB_APP_URL must be set** in `config/admin.env` before running this command. See [Browser App](#browser-app-optional) below for setup instructions.

### Pushing admin SSH key to existing instances

New instances get the admin's SSH public key injected automatically via `user_data` at provision time. For instances that were created before you set up your SSH key, or when adding a new admin:

```bash
./admin.sh push-admin-keys             # push to all running instances
./admin.sh push-admin-keys <username>  # push to one instance
```

This uses SSM `send-command` — no existing SSH access required. Safe to run multiple times (idempotent).

### Pushing instance configuration updates

After editing `scripts/session_start.sh`, `config/tmux.conf`, or any instance-side config:

```bash
./admin.sh refresh <username>
```

No down/up needed. `refresh` pushes the following in one shot:

| What | When it takes effect |
|------|---------------------|
| `session_start.sh` — session launcher | Next connect |
| `.tmux.conf` — tmux key bindings and status bar | Next new tmux session |
| Autoshutdown timer (systemd) | Immediately — active on the running instance |
| `.bash_profile` TMUX guard | Next connect |
| `web-preview.service` — static file server on port 8080 | Immediately — restarted on the running instance |
| `~/.claude/CLAUDE.md` — file sharing instructions for Claude | Next Claude session |

### Pushing script updates to users

After updating any script in `scripts/`:

```bash
./admin.sh publish-installer <username>
```

Then ask the user to run `~/fre-aws/user.sh update` to pull the latest scripts from S3.

---

## Browser App (Optional)

The browser app gives users a zero-install path to their instance: a personal dashboard where they can start/stop their instance and open an SSM terminal in a browser tab. No Docker, no AWS credentials, no local setup required on the user side.

### Enabling the browser app

1. Set `ENABLE_WEB_APP=true` in `config/admin.env`

2. Run `./admin.sh up` — this provisions:
   - A Lambda function (API)
   - An API Gateway HTTP API
   - An S3 bucket + CloudFront distribution (serves the dashboard HTML)
   - An SSM session preferences document (starts the terminal as `developer`)
   - An IAM federation role (scoped to the user's specific instance)
   - An SSM parameter for the signing secret

3. Capture the app URL from the Terraform output:
   ```
   app_url = "https://d1234abcd.cloudfront.net"
   ```

4. Set `WEB_APP_URL=<app_url>` in `config/admin.env`

5. Send users their access links:
   ```bash
   ./admin.sh publish-app-link <username>
   ```

### Custom domain (optional)

To use a custom domain (e.g. `app.myproject.com`) instead of the auto-generated CloudFront URL:

1. Set `APP_DOMAIN=app.myproject.com` in `config/admin.env`
2. Set `ROUTE53_ZONE_ID=<your-hosted-zone-id>` in `config/admin.env`
3. Run `./admin.sh up` — Terraform provisions the ACM certificate (in `us-east-1`, required by CloudFront), DNS validation record, and Route 53 A record automatically
4. Set `WEB_APP_URL=https://app.myproject.com` in `config/admin.env`

### How the terminal works

Clicking **Open Terminal** in the dashboard:
1. Calls the Lambda API, which assumes a tightly-scoped IAM role restricted to the user's specific instance
2. Exchanges the temporary credentials for a one-time AWS Console sign-in token
3. Returns a URL that opens the AWS SSM Session Manager console pre-connected to the instance
4. The terminal starts as `developer` and fires the session launcher automatically

The signed terminal URL is single-use and expires after one hour.

### After updating infrastructure

After every `./admin.sh up`, the CloudFront cache is invalidated automatically so users always get the latest dashboard HTML.

---

## Command Reference

### User management
```bash
./admin.sh add-user                     # interactive wizard: add a user
./admin.sh remove-user <username>       # destroy EC2 instance + remove from registry
./admin.sh update-user-key <username>   # replace a user's SSH public key
./admin.sh publish-installer <username> # regenerate installer zip and print new pre-signed URL
./admin.sh publish-app-link <username>  # generate a 72h browser app access link (requires ENABLE_WEB_APP=true + WEB_APP_URL)
./admin.sh list                         # list all users and their instance state
./admin.sh list -v                      # verbose: show email, role, SSH key, git config
./admin.sh stat                         # full environment status: identity, billing, infra, users
```

### Infrastructure
```bash
./admin.sh bootstrap                    # one-time: create S3, DynamoDB, KMS, permission sets
./admin.sh up                           # provision base infrastructure + all user instances
./admin.sh up <username>                # provision base (no-op if current) + one user's instance
./admin.sh down --all                   # destroy all user instances, then base (full teardown)
./admin.sh down <username>              # destroy one user's instance only; base is preserved
```

### Instance lifecycle
```bash
./admin.sh start [username]             # start an instance (omit username to start all)
./admin.sh stop  [username]             # stop an instance  (omit username to stop all)
```

### Connecting
```bash
./admin.sh connect <username>           # SSH into an instance (uses DeveloperAccess)
./admin.sh refresh <username>           # push session_start.sh + tmux.conf + autoshutdown timer
./admin.sh ssm     <username>           # direct SSM shell (fallback when SSH isn't working)
./admin.sh push-admin-keys [username]   # append admin SSH key to authorized_keys on one or all
                                        # running instances (idempotent, uses SSM — no SSH needed)
```

### Authentication
```bash
./admin.sh sso-login                    # authenticate via IAM Identity Center
./admin.sh verify                       # confirm credentials are active
./admin.sh verify-email <address>       # pre-verify an SES recipient (sandbox mode only)
```

### Development
```bash
./admin.sh build                        # build (or rebuild) the Docker image
./admin.sh test                         # run BATS tests
./admin.sh shell                        # interactive container shell for debugging
```

---

## Troubleshooting

### `ForbiddenException: No access` (GetRoleCredentials)

**Symptom:** `./admin.sh verify` or `./user.sh connect` fails with:
```
An error occurred (ForbiddenException) when calling the GetRoleCredentials operation: No access
```

The SSO token is valid, but the user hasn't been assigned to the AWS account with the required permission set. Being in the IAM Identity Center directory is not enough.

**Fix:** IAM Identity Center → AWS accounts → select your account → Assign users or groups → find the user → assign `ProjectAdminAccess` (for admins) or `DeveloperAccess` (for users).

**Diagnostic** (run inside `./admin.sh shell`):
```bash
# Confirm which accounts the token can see
TOKEN=$(jq -r 'select(.accessToken) | .accessToken' ~/.aws/sso/cache/*.json | head -1)
aws sso list-accounts --access-token "$TOKEN"

# Check what roles are assigned on a specific account
aws sso list-account-roles --account-id <account-id> --access-token "$TOKEN"
```
The `roleName` returned must exactly match `sso_role_name` in `~/.aws/config`.

---

### `kex_exchange_identification: Connection closed by remote host`

The SSH tunnel through SSM failed to establish.

1. Verify the instance is running: `./admin.sh list`
2. Verify SSM connectivity: `./admin.sh ssm <username>`
3. Check the SSM agent is running on the instance (it starts automatically on the AMI we use, but can be restarted with `sudo systemctl restart amazon-ssm-agent`)

---

### `EntityAlreadyExists` during `./admin.sh up`

Terraform state is out of sync with what exists in AWS — a resource exists in AWS but is missing from the Terraform state file.

The most common cause is a partial `up` that was interrupted, or a state file that was lost or reset. Because infrastructure is now split into base state and per-user state, you can repair them independently.

**To inspect the base state:**
```bash
./admin.sh shell
terraform -chdir=terraform state list
```

**To inspect a user's state:**
```bash
./admin.sh shell
terraform -chdir=terraform/user init -backend-config="bucket=<bucket>" -backend-config="key=<project>/users/<username>/terraform.tfstate" -backend-config="region=<region>" -backend-config="dynamodb_table=<table>" -reconfigure
terraform -chdir=terraform/user state list
```

**To import a missing resource manually** (example: IAM role for a user):
```bash
terraform -chdir=terraform/user import -var="username=<username>" ... aws_iam_role.user_ec2 <role-name>
```

In many cases the simplest fix is to destroy and reprovision the affected user:
```bash
./admin.sh down <username>   # destroys what's in state and in AWS
./admin.sh up <username>     # reprovisions cleanly
```
