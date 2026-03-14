# Claude Code AWS Environment

A Docker-packaged toolset for provisioning and managing an EC2-based development environment on AWS, running the Claude Code CLI. Designed for non-technical Mac users — if you can run Docker and have an AWS account, you can use this.

---

## Table of Contents

- [What This Project Does](#what-this-project-does)
- [What You Need Before Starting](#what-you-need-before-starting)
- [Credential Setup](#credential-setup)
  - [Option A: IAM Identity Center (Recommended)](#option-a-iam-identity-center-recommended)
  - [Option B: IAM User with Access Keys (Free Tier)](#option-b-iam-user-with-access-keys-free-tier)
  - [Upgrading from Option B to Option A](#upgrading-from-option-b-to-option-a)
- [Cost Considerations](#cost-considerations)
  - [What is Free Tier eligible](#what-is-free-tier-eligible)
  - [What is NOT free](#what-is-not-free-costs-money-from-day-one)
  - [Network Configuration Options](#network-configuration-options)
  - [Keeping costs low](#keeping-costs-low)
- [Order of Operations (First-Time Setup)](#order-of-operations-first-time-setup)
- [Architecture Overview](#architecture-overview)
- [Security Model](#security-model)
- [For Developers](#for-developers)

---

## What This Project Does

- Provisions a private EC2 instance on AWS using Terraform
- Installs Claude Code CLI on the instance automatically
- Provides simple scripts to start, stop, and connect to your dev environment
- Packages all tooling (Terraform, AWS CLI) inside a Docker image — nothing to install locally beyond Docker and Git

---

## What You Need Before Starting

### On Your Mac

| Requirement | Notes |
|-------------|-------|
| Container runtime | [Docker Desktop](https://www.docker.com/products/docker-desktop/), [OrbStack](https://orbstack.dev), or [Rancher Desktop](https://rancherdesktop.io) |
| `git` | Pre-installed on macOS, or install via Xcode Command Line Tools: `xcode-select --install` |

### In AWS

Everything in the table below must exist **before running any scripts in this project**. The scripts do not create these — they are the foundation everything else builds on.

| Requirement | What It Is | How To Set It Up |
|-------------|-----------|------------------|
| AWS account | A free-tier AWS account | [Create one here](https://aws.amazon.com/free) |
| Root MFA | Multi-factor authentication on the root user | AWS Console → top-right menu → Security credentials → MFA |
| IAM credentials | An identity this project authenticates as | See [Credential Setup](#credential-setup) below |
| Configured AWS CLI profile | `~/.aws/` config pointing at your credentials | Done as part of credential setup |

> **What this project creates automatically** (you do not set these up manually):
> S3 state bucket, DynamoDB lock table, KMS key, VPC, subnets, NAT Gateway, security groups, EC2 instance, IAM instance role, SSM access.

---

## Credential Setup

Two options are documented below. Use Option A if you have AWS Organizations available; use Option B if you are on a free-tier standalone account.

| | Option A: IAM Identity Center | Option B: IAM User (Free Tier) |
|---|---|---|
| **Requires** | AWS Organizations | Nothing beyond Docker and a text editor |
| **Mac prerequisites** | Docker + git (same as everyone) | Docker + git (same as everyone) |
| **Credentials** | Short-lived, auto-expiring | Long-lived access keys |
| **MFA enforcement** | Built-in | Manual (strongly recommended) |
| **Zero Trust alignment** | ✅ Full | ⚠️ Partial |
| **Best for** | Teams, production, any paid account | Free tier, solo development |

---

### Option A: IAM Identity Center (Recommended)

IAM Identity Center provides short-lived credentials and enforces MFA by design. It requires AWS Organizations, which is not available on free-tier standalone accounts but is available on any paid account.

> **No AWS CLI required on your Mac.** Login runs inside the Docker container. Setup only requires creating one text file and using the AWS Console.

**Steps:**

1. In the AWS Console, go to **AWS Organizations → Create an organization** (if not already done)

2. Search for **IAM Identity Center** and click **Enable**

3. Under **Users**, create a user for yourself. Two fields matter here:
   - **Username** — this is what you type at the portal login prompt. Pick something simple and memorable (e.g. your first name). **This is not necessarily your email address**, despite what AWS documentation often implies.
   - **Email address** — used to send the activation link and for password resets. Must be valid.

   You will receive an email to activate the account and set a password.

4. Under **Permission sets**, create a new permission set:
   - Type: **Predefined permission set**
   - Policy: `AdministratorAccess`
   - Name: `AdministratorAccess` (default)

5. Under **AWS accounts**, select your account → **Assign users or groups** → assign your user with the `AdministratorAccess` permission set.

6. Collect the following values from the AWS Console — you will need them in the next step:

   | Value | Where to find it |
   |-------|-----------------|
   | **SSO Start URL** | IAM Identity Center → Dashboard → **AWS access portal URL** (e.g. `https://xxxxx.awsapps.com/start`) |
   | **SSO Region** | The region shown in IAM Identity Center → Settings → **Identity source** |
   | **Account ID** | Top-right corner of any AWS Console page (12-digit number) |

7. **Create `~/.aws/config` on your Mac** using the template file included in this repo:

   ```bash
   mkdir -p ~/.aws
   cp config/aws-config-sso.example ~/.aws/config
   ```

   Open `~/.aws/config` in any text editor and replace the four `UPPER_CASE` placeholders with the values you collected in the previous step. The file already contains comments explaining where to find each value.

   > **Important:** Section headers like `[profile claude-code]` must start at the very beginning of the line with no leading spaces. If you use TextEdit, choose **Format → Make Plain Text** before saving.

8. **Log in** using the Docker container:
   ```bash
   ./run.sh sso-login
   ```
   The container will print a URL and a short code. Open the URL in your Mac browser, enter the code, and approve the request. The container will automatically continue once you complete it.

9. **Verify:**
   ```bash
   ./run.sh verify
   ```

> SSO sessions expire (typically after 8–12 hours). Run `./run.sh sso-login` again when prompted. The token is cached in `~/.aws/` on your Mac and reused by all subsequent commands.

---

### Option B: IAM User with Access Keys (Free Tier)

Free-tier standalone accounts do not support AWS Organizations, which means IAM Identity Center cannot manage AWS account access on them. IAM user access keys are the correct approach for free-tier use.

Access keys are long-lived credentials. MFA and key rotation reduce the risk of a leaked key but do not eliminate it. This is an accepted tradeoff for solo development; switch to Option A when moving to a paid or team account.

> **No AWS CLI required on your Mac.** Credential setup only requires the AWS Console and creating two plain text files.

**Steps:**

1. **Do not use the root user.** The root account should only be used for initial account setup.

2. In the AWS Console, go to **IAM → Users → Create user**
   - Username: your name or `fre-aws-admin`
   - Leave "Provide user access to the AWS Management Console" **unchecked** (programmatic access only)

3. On the **Set permissions** page, choose **Attach policies directly** and select `AdministratorAccess`

   > `AdministratorAccess` is broad but appropriate while you are the sole user of a development account. Before sharing the account or going to production, replace it with a policy scoped to EC2, VPC, S3, DynamoDB, KMS, IAM, and SSM.

4. Complete user creation, then open the user → **Security credentials** tab → **Create access key**
   - Use case: **Command Line Interface (CLI)**
   - Download the CSV — **the secret key is shown exactly once and cannot be retrieved again**

5. **Enable MFA on the IAM user** (same Security credentials tab → **MFA → Authenticator app**)
   - Without MFA, a leaked access key gives full account access

6. **Create the AWS credentials files on your Mac** using the templates included in this repo:

   ```bash
   mkdir -p ~/.aws
   cp config/aws-credentials-keys.example ~/.aws/credentials
   cp config/aws-config-keys.example ~/.aws/config
   ```

   Open each file in a text editor and replace the `UPPER_CASE` placeholders:
   - In `~/.aws/credentials`: paste your Access Key ID and Secret Access Key from the CSV
   - In `~/.aws/config`: set `YOUR_DEPLOY_REGION` to your AWS region (e.g. `us-east-1`)

   > **Important:** Section headers like `[claude-code]` must start at the very beginning of the line with no leading spaces. If you use TextEdit, choose **Format → Make Plain Text** before saving.

7. **Verify the credentials work** using the Docker container:
   ```bash
   ./run.sh verify
   ```
   You should see a table showing your AWS Account ID, user ID, and ARN. If it fails, check that the key values were copied correctly with no extra spaces.

> The scripts in this project use the profile name `claude-code` by default. This can be changed in `config/defaults.env`.

### Upgrading from Option B to Option A

When you move beyond a free-tier single account (e.g. adding team members or a production environment):

1. Enable AWS Organizations
2. Enable IAM Identity Center and follow the Option A steps above
3. Delete `~/.aws/credentials` (the IAM user key file)
4. Create `~/.aws/config` with the SSO profile as shown in Option A
5. Run `./run.sh sso-login` to authenticate

No changes to the Terraform or scripts are needed — only the credential source changes.

---

## Cost Considerations

This project is designed to run cheaply on a free-tier AWS account, but a few things are worth knowing upfront.

### What is Free Tier eligible
- **EC2 t3.micro**: 750 hours/month for the first 12 months — enough to run one instance continuously
- **EBS storage**: 30 GB/month free
- **S3**: 5 GB storage + limited requests free
- **DynamoDB**: 25 GB + 25 WCU/RCU free (more than enough for state locking)
- **Data transfer out**: 100 GB/month free

### What is NOT free (costs money from day one)
| Resource | Approximate Cost | Notes |
|----------|-----------------|-------|
| **NAT Gateway** | ~$0.045/hr + data = ~$33/month | Required for private subnet → internet |
| **VPC endpoints (SSM)** | ~$0.01/hr × 3 = ~$22/month | Alternative to NAT Gateway; keeps SSM traffic off public internet |
| **Spot instance** (if not free tier) | 60–90% off on-demand | After 12-month free tier ends |
| **KMS key** | $1/month per key | One key used for all encryption |

### Network Configuration Options

There are three ways to configure the network, with different cost and security tradeoffs. This is controlled by `var.network_mode` in `config/defaults.env`.

#### Option 1: Private subnet + NAT Gateway (`network_mode = "private_nat"`) — Most secure, ~$33/month
- EC2 lives in a private subnet with no public IP
- All outbound traffic (package installs, Claude API) routes through a NAT Gateway
- No route from the internet to the EC2 instance exists at the network level — even a misconfigured security group cannot expose the instance
- SSM traffic travels over the public internet (encrypted via TLS)
- **Two independent layers of protection**: routing (no inbound route) + security group (deny all inbound)

#### Option 2: Private subnet + VPC endpoints (`network_mode = "private_endpoints"`) — Most secure for SSM, ~$22/month
- EC2 lives in a private subnet with no public IP (same as Option 1)
- No NAT Gateway; outbound internet access is restricted
- SSM traffic uses private VPC endpoints and **never leaves the AWS network** — the most hardened option for the connection path
- Tradeoff: the EC2 instance cannot reach the general internet (no package installs, no Claude API calls unless additional endpoints are added)
- Best suited for locked-down environments; likely too restrictive for a general dev machine

#### Option 3: Public subnet + public IP (`network_mode = "public"`) — **Default (free tier)**, $0 extra/month
- EC2 has a public IP but **all inbound traffic is blocked by security group**
- Outbound traffic goes directly to the internet via Internet Gateway (no NAT cost)
- SSM traffic travels over the public internet (encrypted via TLS), same as Option 1
- **Is this as secure as Option 1?** Mostly, but not equally:
  - Security groups in AWS are enforced at the hypervisor level and are reliable — a closed security group is genuinely effective
  - However, Option 1 provides **defense in depth**: two independent controls (routing + security group) must both fail for exposure to occur; Option 3 relies on a single control (security group alone)
  - The EC2's public IP is routable and visible on the internet, making it a more discoverable target
  - For a single-developer free tier dev machine, the practical risk difference is low — but it is not the same level of security
- **Recommendation**: Use `public` mode during free tier / development. Switch to `private_nat` before sharing with others or handling sensitive data.

### Keeping costs low
- **Stop the instance when not in use** — use `stop.sh`. A stopped EC2 instance does not incur compute charges.
- **Spot instances are on by default** — saves 60–90% on compute vs on-demand once free tier expires
- The NAT Gateway runs continuously while the VPC exists — tear down with `down.sh` when not needed for extended periods

---

## Order of Operations (First-Time Setup)

```
1. Create AWS account + enable root MFA           ← AWS Console, one time
2. Set up credentials (Option A or B above)       ← one time
3. Install Docker on your Mac                     ← one time
4. Clone this repo                                ← git clone ...
5. ./run.sh verify                                ← confirm credentials work
6. ./run.sh bootstrap                             ← creates S3 + DynamoDB for Terraform state
7. ./run.sh up                                    ← provisions all AWS infrastructure
8. ./run.sh connect                               ← opens a shell on your EC2 instance
```

After first-time setup, daily use is just:
```
start.sh    → start the instance
connect.sh  → get a shell
stop.sh     → stop the instance when done
```

---

## Architecture Overview

```
Your Mac
  └── Docker container (terraform + aws-cli + scripts)
        └── AWS account
              ├── VPC (private subnet + NAT Gateway)
              │     └── EC2 t3.micro (spot)
              │           ├── Claude Code CLI
              │           └── SSM Agent (for connect.sh)
              ├── S3 bucket (Terraform state)
              ├── DynamoDB table (state locking)
              └── KMS key (encryption)
```

All access to the EC2 instance goes through **AWS SSM Session Manager** — no SSH keys, no open ports.

---

## Security Model

| Control | Status | Notes |
|---------|--------|-------|
| No inbound ports on EC2 | ✅ Always | Security group has no ingress rules |
| No SSH keys | ✅ Always | SSM Session Manager only |
| No public IP on EC2 | ⚠️ Optional | Default (`public` mode) gives EC2 a public IP; switch to `private_nat` for full isolation |
| IMDSv2 enforced | ✅ Always | Prevents SSRF-based credential theft |
| Storage encrypted at rest | ✅ Always | KMS-backed EBS and S3 |
| Short-lived AWS credentials | ❌ Free tier | IAM user access keys are long-lived; mitigate with MFA and key rotation |
| CloudTrail / VPC Flow Logs | ❌ Deferred | Not enabled by default (cost); add before going to production |

---

## For Developers

See [CLAUDE.md](CLAUDE.md) for architecture decisions, Terraform module conventions, testing strategy, and development workflow.
