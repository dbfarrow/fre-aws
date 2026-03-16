# CLAUDE.md — Claude Code AWS Environment

## Project Purpose

This project creates and maintains an AWS environment using Infrastructure as Code (IaC). It provisions EC2 instances that serve as development environments running the Claude Code CLI. The entire toolchain is packaged as a Docker image so that non-technical Mac users can manage their AWS dev environment with minimal local setup.

## Host Machine Requirements (Mac)

- A container runtime (Docker Desktop, OrbStack, Rancher Desktop, etc.)
- `git`
- AWS credentials via IAM Identity Center (SSO) — **no long-lived access keys**

## Development Workflow

Always use plan mode before writing any code. Use `EnterPlanMode` to explore the codebase, understand the existing patterns, and design an approach before making any changes. Get user approval on the plan before implementing.

## Core Principles

### Zero Trust Architecture
This project applies Zero Trust principles where free-tier AWS constraints allow:

| Principle | Applied | Notes |
|-----------|---------|-------|
| No SSH / no port 22 | ✅ | All EC2 access via SSM Session Manager |
| No EC2 public IP | ⚠️ | Default mode (`public`) gives EC2 a public IP; `private_nat` removes it |
| No long-lived credentials | ❌ Free-tier compromise | IAM Identity Center requires AWS Organizations, which is not available on a free-tier standalone account. IAM user access keys are used instead. Mitigate with MFA and key rotation. Upgrade to IAM Identity Center when AWS Organizations becomes available. |
| Least-privilege IAM | ⚠️ | `AdministratorAccess` used initially for the IAM user; EC2 instance role is scoped to SSM only |
| IMDSv2 enforced | ✅ | `http_tokens = "required"` on all instances |
| Encryption at rest | ✅ | KMS-backed EBS and S3 |
| Security groups deny by default | ✅ | No ingress rules on EC2 |
| Audit logging | ❌ Deferred | CloudTrail and VPC Flow Logs not enabled (cost); add before production |

### Terraform Module Strategy
All AWS resource provisioning uses **community modules from [terraform-aws-modules](https://registry.terraform.io/namespaces/terraform-aws-modules)** (maintained by Anton Babenko). Direct resource blocks are only used when no suitable module exists.

Key modules in use:
| Module | Source |
|--------|--------|
| VPC | `terraform-aws-modules/vpc/aws` |
| EC2 | `terraform-aws-modules/ec2-instance/aws` |
| Security Group | `terraform-aws-modules/security-group/aws` |
| IAM Role | `terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks` or `iam-assumable-role` |
| S3 (state bucket) | `terraform-aws-modules/s3-bucket/aws` |
| KMS | `terraform-aws-modules/kms/aws` |

Always pin modules to a specific version tag (`?ref=vX.Y.Z`) — never use `latest` or an unversioned ref.

---

## Project Architecture

```
.
├── Dockerfile                  # Self-contained image: terraform, aws-cli, scripts
├── docker-compose.yml          # Convenience wrapper for docker run
├── terraform/
│   ├── main.tf                 # Root module: calls all submodules
│   ├── variables.tf
│   ├── outputs.tf
│   ├── backend.tf              # S3 + DynamoDB remote state (encrypted)
│   ├── versions.tf             # Terraform and provider version pins
│   └── tests/                  # terraform test files (*.tftest.hcl)
├── scripts/
│   ├── bootstrap.sh            # One-time: S3 bucket, DynamoDB, KMS key for state
│   ├── up.sh                   # terraform init + apply
│   ├── down.sh                 # terraform destroy (with confirmation)
│   ├── start.sh                # Start stopped EC2 instance
│   ├── stop.sh                 # Stop running EC2 instance
│   └── connect.sh              # Open SSM Session Manager session (no SSH)
├── config/
│   └── defaults.env            # Default variables: region, instance type, project name
├── README.md
└── CLAUDE.md
```

---

## Key Technologies

| Tool | Purpose |
|------|---------|
| Terraform (~1.9+) | IaC provisioning via terraform-aws-modules |
| AWS CLI (v2) | SSO authentication, EC2 lifecycle, SSM sessions |
| AWS SSM Session Manager | Secure shell access — replaces SSH entirely |
| Bash | User-facing scripts inside the container |
| Docker | Packages all tooling; user installs nothing locally |

---

## Docker Image Design

- **Base image**: `alpine` or `debian:slim` — install terraform and aws-cli explicitly
- **Includes**: terraform, aws-cli v2, session-manager-plugin, the `scripts/` directory
- **Nothing sensitive is baked in** — all config is mounted or passed at runtime:
  - AWS SSO config via `-v ~/.aws:/root/.aws:ro`
  - No SSH keys (SSM Session Manager is used instead)
  - Project config via `-v "$(pwd)/config:/workspace/config:ro"`

### Example Docker Run Pattern

```bash
docker run --rm -it \
  -v ~/.aws:/root/.aws:ro \
  -v "$(pwd)/terraform:/workspace/terraform" \
  -v "$(pwd)/config:/workspace/config:ro" \
  claude-code-aws <command>
```

All user-facing scripts (`bootstrap.sh`, `up.sh`, etc.) are thin wrappers that invoke this pattern transparently.

---

## AWS Infrastructure (Zero Trust Design)

### Network
- **VPC** with public and private subnets (via `terraform-aws-modules/vpc/aws`)
- EC2 instances deploy to **private subnets only** — no public IP, no internet gateway route
- NAT Gateway for outbound-only internet access (package installs, Claude API calls)
- VPC Flow Logs: **not enabled initially** (cost); add when moving to production

### EC2 Instance
- Deployed via `terraform-aws-modules/ec2-instance/aws`
- **Spot instances by default** — uses `instance_market_options` with `spot` type; falls back to on-demand if spot capacity unavailable
- Default instance type: `t3.micro` (Free Tier eligible: 750 hrs/month for first 12 months)
- **No security group ingress rules** — only egress allowed
- **IMDSv2 required** (`http_tokens = "required"` in metadata options)
- EBS volumes encrypted with a project-managed KMS key
- IAM instance profile with only: SSM core permissions + any required AWS API access
- User data installs Claude Code CLI on first boot

> **Spot instance note**: Spot instances can be interrupted with 2-minute notice when AWS reclaims capacity. For a dev environment this is acceptable — the instance state is preserved on EBS and can be restarted. If interruption tolerance is unacceptable for a user, expose a `use_spot = false` variable to opt into on-demand.

### Access
- **AWS SSM Session Manager only** — `connect.sh` runs `aws ssm start-session`
- No key pairs, no port 22, no bastion hosts
- SSM access controlled by IAM policy (only the instance's SSM role + authorized user roles)

### IAM
- Users authenticate via **IAM Identity Center (SSO)** — no IAM user access keys
- EC2 instance role: `AmazonSSMManagedInstanceCore` + scoped custom policies
- Terraform execution role: least-privilege, assumed via IAM Identity Center permission set
- All roles use `aws:MultiFactorAuthPresent` conditions where applicable

### State Management
- Remote state in **S3 with versioning, encryption (KMS), and public access block**
- State locking via **DynamoDB table with encryption**
- State bucket and DynamoDB created by `bootstrap.sh` before Terraform is initialized
- State bucket managed by `terraform-aws-modules/s3-bucket/aws`

---

## Testing Strategy

### Terraform Validation (no AWS required, runs in CI)
```bash
terraform fmt --check          # formatting
terraform validate             # syntax + schema
terraform plan                 # dry-run (requires AWS credentials)
```

### Terraform Tests (built-in framework, Terraform 1.6+)
- Test files in `terraform/tests/*.tftest.hcl`
- Use `mock_provider` blocks for pure unit tests (no AWS calls)
- Integration tests run against the **single project AWS account** using a short-lived test workspace; resources are destroyed immediately after the test run
- Run with: `terraform test`

### Shell Script Tests (BATS)
- Test files in `tests/bats/*.bats`
- Tests cover: argument validation, error handling, output formatting, safety prompts
- BATS is installed in the Docker image
- Run with: `bats tests/bats/`

### Local Development Without AWS Costs
- **LocalStack** (optional): mock AWS services for fast iteration on Terraform logic
- Use `TF_VAR_use_localstack=true` to redirect the AWS provider endpoint
- Note: SSM Session Manager behavior cannot be fully mocked; integration tests need real AWS

### CI Strategy
> **Single-account setup**: This project uses one AWS account for both development and CI. There is no separate test/staging account.

- **On PR** (no AWS required): `terraform fmt --check`, `terraform validate`, `bats` tests, `terraform plan` with `mock_provider`
- **Integration tests** (require AWS): run manually or gated behind a label/workflow trigger to avoid uncontrolled AWS spend; use a dedicated Terraform workspace (`test-<pr-number>`) that is always destroyed after the run
- **On merge to main**: `terraform apply` updates the real environment; no separate staging environment at this stage

---

## User-Facing Scripts

### `bootstrap.sh`
One-time setup run before any Terraform commands. Creates:
- KMS key for encryption
- S3 bucket for Terraform state (versioned, encrypted, blocked from public access)
- DynamoDB table for state locking

Prompts for: AWS profile (SSO), region, unique project name.

### `up.sh`
Runs `terraform init` → `terraform plan` → confirmation prompt → `terraform apply`.
Outputs: instance ID, private IP, SSM connect command.

### `down.sh`
Runs `terraform destroy` with an explicit confirmation prompt. Warns if state contains resources.

### `start.sh`
`aws ec2 start-instances` for the managed instance. Waits until running.

### `stop.sh`
`aws ec2 stop-instances` for the managed instance.

### `connect.sh`
Opens an SSM Session Manager session. No SSH key required.
```bash
aws ssm start-session --target <instance-id> --profile <sso-profile>
```

---

## Development Commands

```bash
# Build the Docker image
docker build -t claude-code-aws .

# Validate Terraform inside the container
docker run --rm -v "$(pwd)/terraform:/workspace/terraform" \
  claude-code-aws terraform -chdir=/workspace/terraform validate

# Run BATS tests
docker run --rm -v "$(pwd):/workspace" claude-code-aws bats /workspace/tests/bats/

# Format check
docker run --rm -v "$(pwd)/terraform:/workspace/terraform" \
  claude-code-aws terraform -chdir=/workspace/terraform fmt --check
```

---

## Security Checklist (enforce before every PR)

- [ ] No hardcoded AWS account IDs, ARNs with account IDs, or credentials
- [ ] No SSH key pairs referenced anywhere
- [ ] No security group ingress rules on EC2
- [ ] All S3 buckets have `block_public_acls = true` and `block_public_policy = true`
- [ ] All EBS volumes use `encrypted = true` with a KMS key
- [ ] All EC2 instances have `http_tokens = "required"` (IMDSv2)
- [ ] All IAM policies use least-privilege (no `*` actions or resources unless justified)
- [ ] Terraform module versions are pinned to specific tags

---

## Open Decisions / Future Work

- [ ] Multi-user support (separate EC2 per user, separate IAM roles)
- [ ] Pre-built AMI with Claude Code to minimize boot time
- [ ] Automatic re-authentication flow when SSO token expires
- [ ] GitHub Actions CI for automated plan/apply
