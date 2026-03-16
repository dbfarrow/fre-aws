# Claude Code AWS Environment — Admin Guide

A Docker-packaged toolset for provisioning and managing EC2-based development environments on AWS. Each developer gets their own dedicated EC2 instance running the Claude Code CLI. The admin provisions and manages the environment; developers use a single command (`./dev.sh connect`) to get to work.

---

## Table of Contents

- [Architecture](#architecture)
- [What You Need Before Starting](#what-you-need-before-starting)
- [SSH Key Setup (Admin)](#ssh-key-setup-admin)
- [Credential Setup](#credential-setup)
  - [Option A: IAM Identity Center (Recommended)](#option-a-iam-identity-center-recommended)
  - [Option B: IAM User with Access Keys (Free Tier)](#option-b-iam-user-with-access-keys-free-tier)
  - [Upgrading from Option B to Option A](#upgrading-from-option-b-to-option-a)
- [Local Configuration](#local-configuration)
- [Cost Considerations](#cost-considerations)
  - [What is Free Tier eligible](#what-is-free-tier-eligible)
  - [What is NOT free](#what-is-not-free-costs-money-from-day-one)
  - [Network Configuration Options](#network-configuration-options)
  - [Keeping costs low](#keeping-costs-low)
- [First-Time Setup](#first-time-setup)
- [Managing Users](#managing-users)
- [Developer Onboarding](#developer-onboarding)
- [Security Model](#security-model)
- [Troubleshooting](#troubleshooting)
- [For Developers](#for-developers)

---

## Architecture

One shared AWS environment (VPC, KMS key, state bucket) supports multiple users, each with their own isolated EC2 instance.

```
Your Mac (admin)
  └── Docker container (terraform + aws-cli + ssh + scripts)
        │     mounts: ~/.aws (credentials), ~/.ssh (key read-only), config/
        └── AWS account
              ├── VPC (shared)
              │     ├── EC2 t3.micro — alice (running Claude Code)
              │     ├── EC2 t3.micro — bob   (running Claude Code)
              │     └── EC2 t3.micro — carol (stopped)
              ├── S3 bucket (Terraform state)
              ├── DynamoDB table (state locking)
              └── KMS key (encryption)
```

Each EC2 instance:
- Has a dedicated IAM role (SSM access only)
- Is tagged `Username=<name>` for IAM-based access scoping
- Runs SSH over SSM — no inbound port 22, no public IP required

Connections: SSH tunneled through AWS SSM Session Manager. No firewall rules. SSH key agent-forwarding enables GitHub push/pull without storing private keys on the instance.

---

## What You Need Before Starting

### On Your Mac

| Requirement | Notes |
|-------------|-------|
| Container runtime | [Docker Desktop](https://www.docker.com/products/docker-desktop/), [OrbStack](https://orbstack.dev), or [Rancher Desktop](https://rancherdesktop.io) |
| `git` | Pre-installed on macOS, or install via Xcode Command Line Tools: `xcode-select --install` |
| SSH key (`~/.ssh/fre-claude`) | Used for GitHub access from EC2 instances. See [SSH Key Setup](#ssh-key-setup-admin) below. |

### In AWS

| Requirement | What It Is | How To Set It Up |
|-------------|-----------|------------------|
| AWS account | A free-tier AWS account | [Create one here](https://aws.amazon.com/free) |
| Root MFA | Multi-factor authentication on the root user | AWS Console → top-right menu → Security credentials → MFA |
| IAM credentials | An identity this project authenticates as | See [Credential Setup](#credential-setup) below |
| Configured AWS CLI profile | `~/.aws/` config pointing at your credentials | Done as part of credential setup |

> **What this project creates automatically**: S3 state bucket, DynamoDB lock table, KMS key, VPC, subnets, NAT Gateway, security groups, per-user EC2 instances and IAM roles, SSM access.

---

## SSH Key Setup (Admin)

This project connects to EC2 instances via SSH tunneled through AWS SSM — no open ports, no firewall rules. The SSH key enables **agent forwarding**: your local GitHub SSH key is available on remote instances without ever copying your private key there.

The key **must be named `fre-claude`**.

### Create the key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/fre-claude -C "fre-claude"
```

### Add the public key to GitHub

This allows `git push` and `git pull` to work from EC2 instances:

1. Copy your public key:
   ```bash
   cat ~/.ssh/fre-claude.pub | pbcopy
   ```

2. In GitHub: **Settings → SSH and GPG keys → New SSH key**
   - Title: `fre-claude`
   - Key type: **Authentication Key**
   - Paste the public key

### How it works at connect time

When you run `./admin.sh connect <username>`:

1. `admin.sh` checks that `~/.ssh/fre-claude` exists on your Mac — exits with instructions if not
2. The Docker container mounts `~/.ssh` read-only so it can access the key
3. Inside the container, `connect.sh` starts a fresh `ssh-agent` and runs `ssh-add` — **one passphrase prompt**
4. `connect.sh` opens an SSH session to the EC2 instance with `-A` (agent forwarding)
5. On the EC2 instance, `git` operations use your forwarded agent — your private key never leaves your Mac

---

## Credential Setup

Two options are documented below.

| | Option A: IAM Identity Center | Option B: IAM User (Free Tier) |
|---|---|---|
| **Requires** | AWS Organizations | Nothing beyond Docker and a text editor |
| **Credentials** | Short-lived, auto-expiring | Long-lived access keys |
| **MFA enforcement** | Built-in | Manual (strongly recommended) |
| **Zero Trust alignment** | ✅ Full | ⚠️ Partial |
| **Best for** | Teams, any paid account | Free tier, solo development |

---

### Option A: IAM Identity Center (Recommended)

IAM Identity Center provides short-lived credentials and enforces MFA by design. It requires AWS Organizations, which is not available on free-tier standalone accounts but is available on any paid account.

> **No AWS CLI required on your Mac.** All operations run inside the Docker container. Setup only requires creating one text file and using the AWS Console.

**Steps:**

1. In the AWS Console, go to **AWS Organizations → Create an organization** (if not already done)

2. Search for **IAM Identity Center** and click **Enable**

3. Under **Users**, create a user for yourself:
   - **Username** — what you type at the portal login prompt (e.g. your first name)
   - **Email address** — used for the activation link and password resets

   You will receive an email to activate the account and set a password.

4. **Create a temporary admin permission set** for yourself to run the initial bootstrap:
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

6. **Create `~/.aws/config` on your Mac**:
   ```bash
   mkdir -p ~/.aws
   cp config/aws-config-sso.example ~/.aws/config
   ```
   Open `~/.aws/config` and replace the `UPPER_CASE` placeholders. Set `sso_role_name = AdministratorAccess` for now — you'll switch to `ProjectAdminAccess` after bootstrap.

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

> **No AWS CLI required on your Mac.** Setup only requires the AWS Console and creating two plain text files.

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

6. **Create the AWS credentials files on your Mac**:
   ```bash
   mkdir -p ~/.aws
   cp config/aws-credentials-keys.example ~/.aws/credentials
   cp config/aws-config-keys.example ~/.aws/config
   ```
   Fill in the `UPPER_CASE` placeholders in each file.

7. **Verify**:
   ```bash
   ./admin.sh verify
   ```

### Upgrading from Option B to Option A

1. Enable AWS Organizations
2. Enable IAM Identity Center and follow the Option A steps
3. Delete `~/.aws/credentials`
4. Create `~/.aws/config` with the SSO profile
5. Run `./admin.sh sso-login`

No changes to Terraform or scripts needed — only the credential source changes.

---

## Local Configuration

`config/defaults.env` is your personal admin settings file — **gitignored**, never committed.

```bash
cp config/defaults.env.example config/defaults.env
# Edit config/defaults.env with your values
```

User configuration is stored in S3 (not as a local file) and managed through the CLI — see [Managing Users](#managing-users).

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
| **NAT Gateway** | ~$0.045/hr + data = ~$33/month | Required for private subnet → internet |
| **VPC endpoints (SSM)** | ~$0.01/hr × 3 = ~$22/month | Alternative to NAT Gateway |
| **Spot instance** (after free tier) | 60–90% off on-demand | Default; significant savings |
| **KMS key** | $1/month per key | One key shared across all users |
| **Multiple EC2 instances** | Multiplied by number of users | Each user gets their own instance |

### Network Configuration Options

Controlled by `NETWORK_MODE` in `config/defaults.env`. Applies to all user instances.

| Mode | Cost | Security | Notes |
|------|------|----------|-------|
| `public` | $0 extra | Single control layer | Default. EC2 has public IP but all inbound blocked by SG. |
| `private_nat` | ~$33/month | Defense in depth | EC2 in private subnet, outbound via NAT Gateway. |
| `private_endpoints` | ~$22/month | Highest (no internet) | Private subnet + VPC endpoints. EC2 cannot reach internet. |

**Recommendation**: Use `public` mode during development. Switch to `private_nat` before sharing with a wider team or handling sensitive data.

### Keeping costs low
- **Stop instances when not in use** — `./admin.sh stop <username>`. A stopped EC2 incurs no compute charges.
- **Spot instances are on by default** — saves 60–90% once free tier expires
- For heavy workloads (browser automation, large builds), use `INSTANCE_TYPE=t3.small` (2GB RAM) or larger

---

## First-Time Setup

```
1.  Create AWS account + enable root MFA                    ← AWS Console, one time
2.  Set up credentials (Option A or B above)                ← one time
3.  Install Docker on your Mac                              ← one time
4.  Create SSH key + add public key to GitHub               ← see SSH Key Setup above
5.  Clone this repo                                         ← git clone ...
6.  cp config/defaults.env.example config/defaults.env      ← create your admin config
7.  Edit config/defaults.env                                ← set AWS_REGION, PROJECT_NAME, SSO_REGION, etc.
8.  ./admin.sh verify                                       ← confirm AWS credentials work
9.  ./admin.sh bootstrap                                    ← creates S3, DynamoDB, KMS, permission sets
10. (Option A) reassign yourself to ProjectAdminAccess      ← IAM Identity Center → AWS accounts
                                                            ← update sso_role_name in ~/.aws/config
                                                            ← re-run ./admin.sh sso-login
11. ./admin.sh add-user                                     ← interactive prompt, adds first user
12. ./admin.sh up                                           ← provisions all AWS infrastructure
13. ./admin.sh connect <username>                           ← test that it works
```

---

## Managing Users

User configuration is stored in S3 (`<project>-tfstate/<project>/users.json`) and shared across all admins. The CLI keeps the registry in sync — no manual file editing.

### Adding a user

1. Get their SSH public key (`~/.ssh/fre-claude.pub` from their Mac)
2. Run the interactive wizard:
   ```bash
   ./admin.sh add-user
   ```
   It will prompt for username, SSH public key, git name, and git email.
3. Run `./admin.sh up` — provisions a new EC2 instance for them

### Removing a user

1. Run:
   ```bash
   ./admin.sh remove-user <username>
   ```
   You'll be warned that their instance and EBS data will be destroyed, and asked to confirm by typing their username.
2. Run `./admin.sh up` — destroys their EC2 instance and EBS volume
3. Revoke their IAM Identity Center access in the AWS Console

### Updating session_start.sh for a user

After editing `scripts/session_start.sh`:
```bash
./admin.sh refresh <username>
```
No down/up needed. Changes take effect on their next connect.

### Admin commands

```bash
./admin.sh add-user             # interactive wizard: add a user to the registry
./admin.sh remove-user <name>   # remove a user (destroys instance on next up)
./admin.sh list                 # list all users and their instance state
./admin.sh start   <username>   # start a stopped instance
./admin.sh stop    <username>   # stop a running instance
./admin.sh connect <username>   # SSH into an instance (admin access)
./admin.sh refresh <username>   # push updated session_start.sh
./admin.sh ssm     <username>   # direct SSM shell (fallback when SSH isn't working)
./admin.sh up                   # apply Terraform changes (add/remove users, config updates)
./admin.sh down                 # destroy all infrastructure
./admin.sh sso-login            # re-authenticate (SSO sessions expire after ~8-12 hours)
```

---

## Developer Onboarding

When a new developer is ready to use their environment:

1. **Get their SSH public key** — they run `cat ~/.ssh/fre-claude.pub` and send it to you

2. **Add them to the registry**:
   ```bash
   ./admin.sh add-user
   ```

3. **Provision their instance**:
   ```bash
   ./admin.sh up
   ```

4. **Create an IAM Identity Center user** for them:
   - IAM Identity Center → Users → Add user
   - Under **AWS accounts**, assign them to your account with the `DeveloperAccess` permission set
   - ⚠️ Adding to the directory is not enough — the account-level assignment is a separate step
   - Both `DeveloperAccess` and `ProjectAdminAccess` are created automatically by `./admin.sh bootstrap`

5. **Send them**:
   - A link to **`README-developer.md`** in this repo
   - The SSO Start URL (IAM Identity Center → Dashboard → AWS access portal URL)
   - Their IAM Identity Center username
   - Their `MY_USERNAME` (what you entered in `add-user`)
   - The `AWS_REGION` and `PROJECT_NAME` from your `config/defaults.env`

That's it. The developer README walks them through everything from there.

---

## Security Model

| Control | Status | Notes |
|---------|--------|-------|
| No inbound ports on EC2 | ✅ Always | Security group has no ingress rules; SSH tunneled through SSM |
| SSH private key stays on Mac | ✅ Always | Agent forwarding; private key never copied to instance |
| Per-user EC2 isolation | ✅ Always | Each user has a dedicated instance; no shared filesystem |
| Developers scoped to own instance | ✅ When using IAM Identity Center | Tag-based IAM policy prevents cross-user access |
| No public IP on EC2 | ⚠️ Optional | Default (`public` mode) gives EC2 a public IP; use `private_nat` for full isolation |
| IMDSv2 enforced | ✅ Always | Prevents SSRF-based credential theft |
| Storage encrypted at rest | ✅ Always | KMS-backed EBS and S3 |
| Short-lived AWS credentials | ❌ Free tier only | IAM user access keys are long-lived; mitigate with MFA and key rotation |
| CloudTrail / VPC Flow Logs | ❌ Deferred | Not enabled by default (cost); add before going to production |

---

## Troubleshooting

### `ForbiddenException: No access` (GetRoleCredentials)

**Symptom:** `./admin.sh verify` (or a developer's `./dev.sh connect`) fails with:
```
An error occurred (ForbiddenException) when calling the GetRoleCredentials operation: No access
```

The SSO login browser flow completed successfully — the token is valid — but the user isn't assigned to the AWS account with the required permission set. Being in the IAM Identity Center directory is not enough; access must be granted at the account level.

**Fix:** IAM Identity Center → AWS accounts → select your account → Assign users or groups → find the user → assign the correct permission set (`ProjectAdminAccess` for admins, `DeveloperAccess` for developers).

**Diagnostic** (run inside `./admin.sh shell`):
```bash
# Step 1: confirm which accounts the token can see
TOKEN=$(jq -r 'select(.accessToken) | .accessToken' ~/.aws/sso/cache/*.json | head -1)
aws sso list-accounts --access-token "$TOKEN"

# Step 2: if the account appears, check what roles are actually assigned
aws sso list-account-roles --account-id <account-id> --access-token "$TOKEN"
```
The `roleName` returned must exactly match `sso_role_name` in `~/.aws/config`.

---

### Developer connect fails silently

**Symptom:** `./dev.sh connect` exits without a clear error.

**Most likely cause:** Expired or invalid SSO credentials. Since the fix in commit `1531fd9`, credential failures now print a clear error message. If the developer sees:
```
ERROR: Could not export credentials for profile 'claude-code'.
       If using SSO, run './dev.sh sso-login' first.
```
→ they need to re-run the SSO login flow.

If they see `kex_exchange_identification: Connection closed by remote host`, the SSH tunnel through SSM failed — use `./admin.sh ssm <username>` to verify the instance is reachable, and check the instance's SSM agent is running.

---

## For Developers

See [CLAUDE.md](CLAUDE.md) for architecture decisions, Terraform module conventions, testing strategy, and development workflow.
