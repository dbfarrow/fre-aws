# CLAUDE.md — Claude Code AWS Environment

## Project Purpose

This project creates and maintains a multi-user AWS environment using Infrastructure as Code (IaC). It provisions individual EC2 instances per user that serve as persistent development environments running the Claude Code CLI. The entire toolchain is packaged as a Docker image so that non-technical Mac users can manage their AWS dev environment with minimal local setup.

## Host Machine Requirements (Mac and Windows/WSL2)

Supported platforms: **macOS** and **Windows with WSL2**.

- A container runtime:
  - macOS: Docker Desktop, OrbStack, or Rancher Desktop
  - Windows: Docker Desktop with WSL2 backend
- `git` (macOS: pre-installed or via Xcode CLI tools; Windows: use git inside WSL2)
- AWS credentials via IAM Identity Center (SSO)
- SSH key (`~/.ssh/fre-claude`) for SSH-over-SSM access

> **Windows users:** Install WSL2 first (`wsl --install`), then Docker Desktop with WSL2 backend. Clone this repo and run all commands from inside the WSL2 terminal. Keep SSH keys in `~/.ssh/` within WSL2.

---

## Development Workflow

Always use plan mode before writing any code. Use `EnterPlanMode` to explore the codebase, understand the existing patterns, and design an approach before making any changes. Get user approval on the plan before implementing.

**Debug commands:** Always write debug/diagnostic commands as a single line with no line continuations (`\`). Users copy-paste these from the terminal; multi-line commands cause paste errors.

---

## Git Workflow

This project uses **GitHub Flow**. All changes reach `main` through pull requests — no direct pushes to `main`.

### Branch naming
| Prefix | Use for |
|--------|---------|
| `feature/` | new functionality |
| `fix/` | bug fixes |
| `docs/` | documentation only |
| `chore/` | maintenance, refactoring, dependency updates |

Example: `feature/windows-wsl2-support`, `fix/spot-instance-tagging`

### Pull request rules
- **Every change to `main` goes through a PR** — no exceptions
- **Merges are performed in the GitHub UI, never automated from the CLI or from Claude**
- Use **squash-and-merge** to keep `main` history linear and readable
- PR title should be concise; description must explain *what* changed and *why*
- Keep PRs focused: one logical change per PR
- Delete the branch after merge

### Standard flow
```
git checkout -b feature/my-change   # branch from main
# ... make changes, commit frequently ...
git push -u origin feature/my-change
# Open PR in GitHub UI → review → squash-and-merge → delete branch
git checkout main && git pull        # sync local main after merge
```

### PR scope discipline (Claude-specific)
Claude should continuously ask: *has the work in progress grown beyond the reasonable scope of a single PR?* When it has — when uncommitted changes span multiple independent concerns, or when a new direction emerges mid-implementation — Claude will call this out explicitly and propose stopping to open a PR for the current work before continuing. The goal is PRs that are independently reviewable and meaningful, not large mixed-concern diffs.

### Documentation completeness (Claude-specific)
Before declaring any feature PR ready for review, Claude must verify that all documentation is current for the feature. This includes:
- `README-admin.md` — any new commands, config variables, behavioral changes, or operational considerations
- `README-user.md` — anything that affects the user-facing experience
- `CLAUDE.md` — any new architectural decisions, constraints, or development principles
- Inline code comments — anywhere the logic isn't self-evident

A PR is not ready for review if a user or future Claude reading the docs would have an incomplete or inaccurate picture of how the feature works.

---

## Core Principles

### Zero Trust Architecture
This project applies Zero Trust principles where free-tier AWS constraints allow:

| Principle | Applied | Notes |
|-----------|---------|-------|
| No SSH / no port 22 | ✅ | All EC2 access via SSM Session Manager (SSH tunneled over SSM) |
| No EC2 public IP | ⚠️ | Default mode (`public`) gives EC2 a public IP; `private_nat` removes it |
| No long-lived credentials | ✅ | IAM Identity Center (SSO) with short-lived session tokens |
| Least-privilege IAM | ✅ | `{project}-developer-access` and `{project}-admin-access` permission sets scoped per project |
| IMDSv2 enforced | ✅ | `http_tokens = "required"` on all instances |
| Encryption at rest | ✅ | AWS-managed key EBS encryption; S3 state bucket uses SSE |
| Security groups deny by default | ✅ | No ingress rules on EC2 |
| Audit logging | ❌ Deferred | CloudTrail and VPC Flow Logs not enabled (cost); add before production |

### User Data Protection

**Never destroy user data without explicit, specific acknowledgment from the operator.**

User data lives on EBS volumes attached to EC2 instances. Destroying an instance or its EBS volume is permanent and unrecoverable. This principle applies to all code — scripts, Terraform, and automation:

- **Terraform changes**: before implementing any infrastructure change, consider whether it could produce a `ForceNew` replacement of an EC2 instance or EBS volume. If there is any such risk — even in an edge case — the implementation must either eliminate the risk or present the operator with a clear alternative path that avoids destruction.
- **Script changes**: any script operation that could result in instance termination or volume deletion must require explicit typed confirmation (not just `y`), describe exactly what will be destroyed, and make clear the action is irreversible.
- **No silent destruction**: Terraform plan output must be inspected before apply whenever EC2 or EBS resources are in scope. If a plan shows replacement, the operator must be stopped and warned before the apply proceeds — not after.

When reviewing or writing Terraform code, actively check for `ForceNew` attributes on `aws_instance`, `aws_spot_instance_request`, and `aws_ebs_volume` resources. Common triggers: `ami`, `subnet_id`, `key_name`, `user_data` (when `user_data_replace_on_change = true`). If a desired change would trigger any of these, find an alternative approach (targeted apply, state manipulation, separate resource creation before cutover) and present it rather than proceeding.

### Terraform Module Strategy
All AWS resource provisioning uses **community modules from [terraform-aws-modules](https://registry.terraform.io/namespaces/terraform-aws-modules)** (maintained by Anton Babenko). Direct resource blocks are only used when no suitable module exists.

Key modules in use:
| Module | Source |
|--------|--------|
| VPC | `terraform-aws-modules/vpc/aws` |
| EC2 | `terraform-aws-modules/ec2-instance/aws` |
| Security Group | `terraform-aws-modules/security-group/aws` |
| IAM Role | `terraform-aws-modules/iam/aws//modules/iam-assumable-role` |
| S3 (state bucket) | `terraform-aws-modules/s3-bucket/aws` |

Always pin modules to a specific version tag (`?ref=vX.Y.Z`) — never use `latest` or an unversioned ref.

---

## Project Architecture

```
.
├── Dockerfile                   # Self-contained image: terraform, aws-cli, SSM plugin, scripts
├── docker-compose.yml           # Convenience wrapper for docker run
├── run.sh                       # Host-side entry point; dispatches all commands into Docker
├── terraform/
│   ├── main.tf                  # Base module: VPC, security groups, billing, web app
│   ├── variables.tf
│   ├── outputs.tf               # Exports: subnet_id, security_group_id, etc.
│   ├── backend.tf               # S3 + DynamoDB remote state (encrypted, KMS)
│   ├── versions.tf              # Terraform and provider version pins
│   ├── user_data_main.sh        # EC2 bootstrap: installs Claude, tmux, autoshutdown timer
│   ├── user_data_tail.sh        # EC2 bootstrap tail: .bash_profile session launcher hook
│   ├── user/                    # Per-user module (called once per user by up.sh / down.sh)
│   │   ├── main.tf              # EC2 instance, IAM role/profile, tags
│   │   ├── variables.tf         # username, ssh_public_key, base outputs as inputs
│   │   ├── outputs.tf           # instance_id, instance_state
│   │   ├── backend.tf           # Empty S3 backend; keys injected at runtime
│   │   └── versions.tf          # AWS provider only
│   └── tests/                   # terraform test files (*.tftest.hcl)
├── scripts/
│   ├── bootstrap.sh             # One-time: S3 state bucket, DynamoDB, canonical settings.json
│   ├── configure.sh             # Second-admin onboarding: validate admin.env + regenerate backend.env
│   ├── up.sh                    # Two-phase: base apply, then per-user apply loop
│   ├── down.sh                  # Per-user destroy; optionally tears down base
│   ├── start.sh                 # Start a stopped EC2 instance
│   ├── stop.sh                  # Stop a running EC2 instance
│   ├── connect.sh               # SSH over SSM tunnel → session_start.sh menu
│   ├── refresh.sh               # Push config to running instance without rebuild
│   ├── session_start.sh         # EC2-side: tmux launcher menu (source of truth)
│   ├── stat.sh                  # Full environment status: identity, billing, instances (skips IC enumeration in external mode)
│   ├── list.sh                  # Users + EC2 instance state summary (skips IC enumeration in external mode)
│   ├── add-user.sh              # Add user to S3 registry; creates Identity Center user in managed mode
│   ├── remove-user.sh           # Destroy EC2 instance + remove from registry (and optionally Identity Center in managed mode)
│   └── users-s3.sh              # Library: S3 user registry read/write functions
├── config/
│   ├── admin.env                # Admin config: region, profile, project name (gitignored)
│   ├── admin.env.example        # Tracked template for admin.env
│   ├── backend.env              # Generated by bootstrap; Terraform backend config
│   ├── defaults.env             # Per-instance defaults: instance type, EBS size (gitignored)
│   ├── defaults.env.example     # Tracked template for defaults.env
│   └── tmux.conf                # tmux config deployed to all instances
└── CLAUDE.md
```

---

## Multi-User Model

Each user gets their own EC2 instance and S3 registry entry. In managed mode (`IDENTITY_MODE=managed`), an IAM Identity Center user is also created. Users are managed via:

```
./admin.sh bootstrap               # One-time setup: S3, DynamoDB, permission sets, canonical settings.json
./admin.sh configure               # Second-admin onboarding: validate admin.env + regenerate backend.env
./admin.sh add-user <username>     # S3 registry entry + Identity Center user (managed mode only)
./admin.sh remove-user <username>  # Destroy EC2 instance + remove user (--keep-sso to preserve Identity Center)
./admin.sh list                    # Show all users + instance state + timestamps
./admin.sh stat                    # Full environment status including billing
./admin.sh up <username>           # Provision EC2 instance for user
./admin.sh down <username>         # Destroy EC2 instance for user
./admin.sh start <username>        # Start stopped instance
./admin.sh stop <username>         # Stop running instance
./admin.sh connect <username>      # Connect via SSH over SSM
./admin.sh refresh <username>      # Push config updates to running instance (no rebuild)
```

**User registry** lives in S3 (not tfvars). Each entry stores: `user_email`, `role`, `git_user_name`, `git_user_email`, `ssh_public_key`.

---

## EC2 Session Flow

### Connection
`connect.sh` starts an ssh-agent inside Docker, loads `~/.ssh/fre-claude`, and opens SSH over an SSM tunnel (no inbound port 22). Agent forwarding (`ssh -A`) allows git operations on the EC2 using the local key.

### Session Launcher (`session_start.sh`)
On connect, `.bash_profile` fires `session_start.sh` (guarded: only on interactive SSH, never inside tmux). The menu shows:
- Numbered list of repos in `~/repos` — selecting one reattaches or creates a named tmux session
- `c` — clone a GitHub repo (prompts owner/repo, clones via SSH agent)
- `n` — create a new project directory
- `s` — open a plain shell

Each repo option launches: `claude --continue 2>/dev/null || claude; exec bash` inside a named tmux session. `--continue` resumes the last conversation; the `|| claude` fallback handles new projects with no history. `exec bash` keeps the window open after Claude exits.

### Session Persistence
tmux named sessions survive SSH/SSM disconnects. Reconnecting and selecting the same repo reattaches to the existing session — Claude picks up exactly where it left off.

### Autoshutdown
A systemd timer (`autoshutdown.timer`) runs every 5 minutes:
- **tmux sessions exist** → reset idle timer, do nothing (user is working or session is detached)
- **0 tmux sessions for 10+ minutes** → `sudo shutdown -h now`

This means: deliberately exiting Claude → `exit` the bash shell → tmux session ends → instance stops itself in ~10–15 minutes. A midnight Lambda provides a safety net for forgotten detached sessions.

**`./admin.sh refresh`** installs the autoshutdown timer live on a running instance (no rebuild needed). It also pushes `session_start.sh`, `.tmux.conf`, and patches `.bash_profile`.

---

## Key Technologies

| Tool | Purpose |
|------|---------|
| Terraform (~1.9+) | IaC provisioning via terraform-aws-modules |
| AWS CLI (v2) | SSO authentication, EC2 lifecycle, SSM sessions |
| AWS SSM Session Manager | Secure shell access — SSH tunneled over SSM, no port 22 |
| IAM Identity Center | Per-user SSO with `{project}-developer-access` + `{project}-admin-access` permission sets |
| tmux | Session persistence across SSH disconnects |
| Python 3 + zoneinfo | Timestamp formatting (AWS ISO 8601 → local timezone) |
| Bash | All user-facing scripts |
| Docker | Packages all tooling; users install nothing locally |

---

## Dockerfile Notes

- Base image: `debian:bookworm-slim`
- Includes: terraform, aws-cli v2, SSM session-manager-plugin, bats, openssh-client, python3, **tzdata**
- `tzdata` is required for Python `zoneinfo` to resolve named timezones (e.g. `America/Los_Angeles`)
- `run.sh` detects the host timezone and passes it as `TZ` env var into all containers
- Nothing sensitive is baked in — AWS credentials and config are mounted at runtime

---

## AWS Infrastructure

### Network
- **VPC** with public and private subnets (via `terraform-aws-modules/vpc/aws`)
- Default mode: EC2 in public subnet with public IP, all inbound traffic blocked by security group
- `private_nat` mode: EC2 in private subnet + NAT Gateway (~$33/month extra)
- VPC Flow Logs: not enabled (cost); add before production

### EC2 Instance
- Deployed via `terraform-aws-modules/ec2-instance/aws`
- **Spot instances by default** — significant cost savings; falls back to on-demand if unavailable
- `user_data_replace_on_change = false` — prevents accidental instance replacement on user_data edits
- **No security group ingress rules** — only egress allowed
- **IMDSv2 required** (`http_tokens = "required"`)
- EBS volumes encrypted with the AWS-managed key (`aws/ebs`)
- `developer` user has `NOPASSWD:ALL` sudo (required for autoshutdown `shutdown -h now`)

### State Management
- Remote state in **S3 with versioning, KMS encryption, public access block**
- State locking via **DynamoDB table**
- Bucket and table names include the AWS account ID for global uniqueness: `${PROJECT_NAME}-${ACCOUNT_ID}-tfstate` / `${PROJECT_NAME}-${ACCOUNT_ID}-tflock`
- Terraform state bucket is in us-east-1 (bootstrap ran there); EC2 resources are in us-west-2 — intentional
- State is split: base state at `<project>/base/terraform.tfstate`; per-user state at `<project>/users/<username>/terraform.tfstate`
- `up.sh` runs two phases: base apply (shared infra, fast no-op if converged), then per-user loop
- `down <username>` destroys only that user's state; base is preserved. `down` with no argument tears down all users then base.

### Canonical Configuration (Multi-Admin Synchronization)
- Bootstrap writes `${PROJECT_NAME}/settings.json` to S3 after every run (idempotent). Stores: `aws_region`, `network_mode`, `use_spot`, `ebs_volume_size_gb`, `identity_mode`.
- `up.sh` fetches `settings.json` and compares it against local `admin.env`. If drift is found, it prints each mismatch and prompts `Continue anyway? [y/N]` before proceeding. Silently skipped when `settings.json` is absent (projects bootstrapped before this feature).
- Second admins use `./admin.sh configure` to validate their local `admin.env`, check for drift, and regenerate `config/backend.env` — without running `bootstrap` themselves.
- `SSO_PROFILE` in `admin.env` allows IC API calls (`sso-admin`, `identitystore`) to use a different AWS profile than `AWS_PROFILE` for cross-account Identity Center setups.

### Scheduled Stop (Lambda)
- Midnight Lambda stops all running instances to prevent overnight charges
- Safety net for detached tmux sessions the autoshutdown timer doesn't catch

---

## Testing Strategy

### Terraform Validation (no AWS required)
```bash
terraform fmt --check
terraform validate
terraform plan
```

### Shell Script Tests (BATS)
- Test files in `tests/bats/*.bats`
- BATS is installed in the Docker image
- Run with: `./admin.sh test`

### Known Account Limits
- `ENABLE_ANOMALY_DETECTION=false` required in `config/defaults.env` (account hit dimensional monitor limit)

---

## Debugging Tips

- **Always write debug commands as a single line** — users copy-paste from the terminal; line continuations break paste
- Check autoshutdown timer: `systemctl status autoshutdown.timer`
- Check autoshutdown logs: `journalctl -u autoshutdown.service --no-pager -n 20`
- Check idle file: `cat ~/.autoshutdown-idle-since`
- Check tmux sessions: `tmux list-sessions`
- Timestamp issues: AWS `LaunchTime` is ISO 8601 with `+00:00` offset; `date -d` silently fails on this — use Python `datetime.fromisoformat` instead
- IFS gotcha: `IFS=$'\t' read` collapses consecutive tabs (bash treats tab as whitespace). Use `|` as jq output delimiter with `IFS='|' read` to handle empty fields correctly

---

## Security Checklist (enforce before every PR)

- [ ] No hardcoded AWS account IDs, ARNs with account IDs, or credentials
- [ ] No SSH key pairs referenced anywhere (SSH is only via SSM tunnel)
- [ ] No security group ingress rules on EC2
- [ ] All S3 buckets have `block_public_acls = true` and `block_public_policy = true`
- [ ] All EBS volumes use `encrypted = true`
- [ ] All EC2 instances have `http_tokens = "required"` (IMDSv2)
- [ ] All IAM policies use least-privilege (no `*` actions or resources unless justified)
- [ ] Terraform module versions are pinned to specific tags

---

## Open Decisions / Future Work

- [ ] Pre-built AMI with Claude Code to minimize boot time (currently installs on first boot)
- [ ] Automatic SSO re-authentication flow when token expires mid-session
- [ ] GitHub Actions CI for automated plan/apply
- [ ] CloudTrail + VPC Flow Logs (deferred for cost; add before production use)
