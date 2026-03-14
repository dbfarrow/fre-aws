# Claude Code AWS Environment

A Docker-packaged toolset for provisioning and managing an EC2-based development environment on AWS, running the Claude Code CLI. Designed for non-technical Mac users — if you can run Docker and have an AWS account, you can use this.

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

This project uses **no long-lived access keys** by default. The recommended path is AWS IAM Identity Center (SSO), which gives you short-lived credentials and MFA enforcement.

### Option A: IAM Identity Center (Recommended)

IAM Identity Center is AWS's modern SSO system. It works with a single AWS account — you do not need AWS Organizations.

1. In the AWS Console, search for **IAM Identity Center** and enable it
2. Create a **user** for yourself (use your email)
3. Create a **permission set** — choose the `AdministratorAccess` managed policy for now
4. Assign the permission set to your user and your account
5. Note the **AWS access portal URL** shown in the IAM Identity Center dashboard
6. On your Mac, configure the AWS CLI:
   ```bash
   aws configure sso
   ```
   You'll be prompted for the portal URL, region, and a profile name. Use `claude-code` as the profile name.
7. Test it:
   ```bash
   aws sso login --profile claude-code
   aws sts get-caller-identity --profile claude-code
   ```

### Option B: IAM User with Access Keys (Simpler, Less Secure)

If IAM Identity Center feels like too much setup right now, you can use a traditional IAM user. Be aware that access keys are long-lived credentials — treat them like passwords.

1. In the AWS Console, go to **IAM → Users → Create user**
2. Attach the `AdministratorAccess` managed policy
3. Under **Security credentials**, create an **Access key** (choose "CLI" use case)
4. Download the CSV — you will not see the secret key again
5. On your Mac:
   ```bash
   aws configure --profile claude-code
   ```
   Enter the access key ID, secret key, default region, and output format (`json`).
6. Enable MFA on the IAM user (IAM → Users → your user → Security credentials → MFA)

> Regardless of which option you choose, use the profile name `claude-code`. The scripts in this project default to that profile name.

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
1. Create AWS account + enable root MFA          ← manual, one time
2. Set up IAM credentials (Option A or B above)  ← manual, one time
3. Install Docker on your Mac                    ← manual, one time
4. Clone this repo                               ← git clone ...
5. Run bootstrap.sh                              ← creates S3 + DynamoDB for Terraform state
6. Run up.sh                                     ← provisions all AWS infrastructure
7. Run connect.sh                                ← opens a shell on your EC2 instance
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

- No inbound ports open on EC2
- No SSH keys used or stored
- EC2 instance has no public IP (private subnet, default config)
- All connections via SSM (encrypted, IAM-controlled, auditable)
- IMDSv2 enforced (prevents credential theft via SSRF)
- All storage encrypted at rest (KMS)
- CloudTrail and VPC Flow Logs not enabled by default (cost); enable manually for production use

---

## For Developers

See [CLAUDE.md](CLAUDE.md) for architecture decisions, Terraform module conventions, testing strategy, and development workflow.
