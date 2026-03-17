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
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)

---

## What You Need

### On Your Mac

| Requirement | Notes |
|-------------|-------|
| Container runtime | [Docker Desktop](https://www.docker.com/products/docker-desktop/), [OrbStack](https://orbstack.dev), or [Rancher Desktop](https://rancherdesktop.io) |
| `git` | Pre-installed on macOS, or: `xcode-select --install` |
| SSH key + GitHub account | You almost certainly have these already — see [SSH Key](#ssh-key) below |

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

Each person using an instance needs their own [Claude Code account](https://claude.ai/code). This is not something the admin can provision — each user must create their own account before their first session. Let users know they should sign up before their onboarding email arrives.

---

## SSH Key

Admin connections use SSH tunneled through SSM with **agent forwarding** — your existing GitHub SSH key is used automatically. No new key is required.

The tooling looks for your key in this order: `SSH_KEY_FILE` in `config/admin.env` → `~/.ssh/id_ed25519` → `~/.ssh/id_rsa`. If you use a standard location, no configuration is needed. Agent forwarding means your private key never leaves your Mac — `git push` and `git pull` work on EC2 instances through the forwarded agent without copying the key to the instance.

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

> **No AWS CLI required on your Mac.** All operations run inside Docker. Setup only requires the AWS Console and creating one text file.

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

6. **Create `~/.aws/config` on your Mac**:
   ```bash
   mkdir -p ~/.aws
   cp config/aws-config-sso.example ~/.aws/config
   ```
   Open `~/.aws/config` and replace the `UPPER_CASE` placeholders. Set `sso_role_name = AdministratorAccess` for now.

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

**SES sandbox**: New AWS accounts can only send to verified addresses. To send to any user:
- AWS Console → SES → Account dashboard → **Request production access**
- Takes 24–48 hours; required before onboarding external users

> If `SENDER_EMAIL` is not set, `add-user` still completes but skips the email step. Credentials are saved to `config/onboarding/<username>/` — forward the files manually.

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

### Network configuration options

Controlled by `NETWORK_MODE` in `config/admin.env`. Applies to all instances.

| Mode | Cost | Security | Notes |
|------|------|----------|-------|
| `public` | $0 extra | Good | Default. EC2 has public IP but all inbound blocked by security group. |
| `private_nat` | ~$33/month | Better | EC2 in private subnet, outbound via NAT Gateway. |
| `private_endpoints` | ~$22/month | Best | Private subnet + VPC endpoints. EC2 cannot reach internet. |

**Recommendation**: Use `public` mode during development. Switch to `private_nat` before sharing with a wider team or handling sensitive data.

### Keeping costs low

- **Stop instances when not in use** — `./admin.sh stop <username>`. A stopped EC2 incurs no compute charges.
- **Spot instances are on by default** — saves 60–90% once free tier expires.
- For heavy workloads (browser automation, large builds), use `INSTANCE_TYPE=t3.small` (2 GB RAM) or larger.

---

## First-Time Setup

```
1.  AWS account with AdministratorAccess                    ← any account; free tier works
    Enable root MFA while you're there                      ← AWS Console → Security credentials → MFA
2.  Set up credentials (Option A or B above)                ← one time
3.  Install Docker on your Mac                              ← one time
4.  Confirm SSH key + GitHub account                        ← ~/.ssh/id_ed25519 works; see SSH Key above
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
                                                               creates IAM Identity Center account,
                                                               emails credentials
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
- Creates an IAM Identity Center user and assigns the appropriate permission set(s)
- Generates or accepts an SSH key pair for EC2 access
- Generates `user.env` and `~/.aws/config` files ready for the new user
- Saves an onboarding bundle to `config/onboarding/<username>/`
- Builds a self-contained installer zip and uploads it to S3
- Emails a 72-hour pre-signed download link to the user via SES (if `SENDER_EMAIL` is set)

The user installs with a single `curl + unzip + bash` one-liner — no `git` required on their Mac.

After `add-user`, run `./admin.sh up` to provision their EC2 instance.

**Note**: `SSO_REGION`, `SSO_START_URL`, and `SENDER_EMAIL` must be set in `config/admin.env`.

#### Admin vs user role

| Role | Permission sets | `admin.sh` access | `user.sh` access |
|------|----------------|-------------------|------------------|
| `user` | `DeveloperAccess` | None | Connect, start, stop |
| `admin` | `ProjectAdminAccess` + `DeveloperAccess` | Full | Connect, start, stop |

Admin users receive a two-profile `~/.aws/config` (`claude-code` for admin operations, `claude-code-dev` for instance access).

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
./admin.sh up
```

`remove-user` removes the user from the registry and warns you that their instance and EBS data will be destroyed on the next `up`. Their IAM Identity Center account remains — revoke it manually in the AWS Console if needed.

### Re-sending the installer link

The pre-signed installer URL expires after 72 hours. To generate a fresh one:

```bash
./admin.sh publish-installer <username>
```

This uploads a new `latest.zip` to S3 and prints a new pre-signed URL. Send it to the user manually (or copy into an email). Useful after the initial link expires or after scripts are updated.

### Pushing session launcher updates

After editing `scripts/session_start.sh`:

```bash
./admin.sh refresh <username>
```

No down/up needed. Changes take effect on their next connect.

### Pushing script updates to users

After updating any script in `scripts/`:

```bash
./admin.sh publish-installer <username>
```

Then ask the user to run `~/fre-aws/user.sh update` to pull the latest scripts from S3.

---

## Command Reference

### User management
```bash
./admin.sh add-user                     # interactive wizard: add a user
./admin.sh remove-user <username>       # remove a user (destroys instance on next up)
./admin.sh update-user-key <username>   # replace a user's SSH public key
./admin.sh publish-installer <username> # regenerate installer zip and print new pre-signed URL
./admin.sh list                         # list all users and their instance state
./admin.sh list -v                      # verbose: show email, role, SSH key, git config
```

### Infrastructure
```bash
./admin.sh bootstrap                    # one-time: create S3, DynamoDB, KMS, permission sets
./admin.sh up                           # terraform apply (provisions/updates all instances)
./admin.sh down                         # terraform destroy (destroys everything — use with care)
./admin.sh repair-state [--dry-run]     # import AWS resources missing from Terraform state
```

### Instance lifecycle
```bash
./admin.sh start [username]             # start an instance (omit username to start all)
./admin.sh stop  [username]             # stop an instance  (omit username to stop all)
```

### Connecting
```bash
./admin.sh connect <username>           # SSH into an instance (uses DeveloperAccess)
./admin.sh refresh <username>           # push updated session_start.sh to a running instance
./admin.sh ssm     <username>           # direct SSM shell (fallback when SSH isn't working)
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

Terraform state is out of sync with what exists in AWS. Run:

```bash
./admin.sh repair-state [--dry-run] [username]
```

This imports the existing resources into Terraform state without recreating them.
