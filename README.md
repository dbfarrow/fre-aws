# fre-aws — Claude Code on AWS

A self-hosted development environment that gives each team member a dedicated EC2 instance running [Claude Code](https://claude.ai/code). One command to connect; your admin handles everything else.

Supported host platforms: **macOS** and **Windows (WSL2)**. See the [Admin Guide](README-admin.md) or [User Guide](README-user.md) for platform-specific setup instructions.

---

## What it does

Each user gets their own EC2 instance in your AWS account. The admin provisions and manages the infrastructure using Docker-packaged tooling — no Terraform or AWS CLI required on any machine. Users connect with a single command and land in a session launcher that lets them open projects, clone repos, or drop into a shell.

```
Your machine (Mac or Windows/WSL2)
  └── Docker container (terraform + aws-cli + ssh)
        └── AWS account
              ├── VPC (shared)
              │     ├── EC2 — alice   (running Claude Code)
              │     ├── EC2 — bob     (running Claude Code)
              │     └── EC2 — carol   (stopped, data preserved)
              ├── S3 bucket  (Terraform state)
              ├── DynamoDB   (state locking)
              └── KMS key    (encryption)
```

---

## How access works

There are two ways for users to reach their instance:

### CLI path (default)

Connections use SSH tunneled through [AWS SSM Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html):

- **No open ports** — EC2 instances have no inbound firewall rules, no public IP required
- **No GitHub SSH keys on instances** — GitHub access uses OAuth via `gh auth login`; no SSH key needs to be added to GitHub
- **No VPN** — SSM handles the tunnel; the only requirement is valid AWS credentials
- **Requires**: Docker (or OrbStack/Rancher Desktop) installed on the user's machine

### Browser path (optional)

When the admin enables the web app (`ENABLE_WEB_APP=true`), users get a zero-install alternative:

- **No Docker, no AWS credentials, no local install** — just a browser
- User clicks a signed link from their onboarding email → lands on a personal dashboard
- Dashboard shows instance status and provides **Start**, **Stop**, and **Open Terminal** buttons
- **Open Terminal** opens an interactive AWS SSM browser terminal directly in a new tab

The admin enables this once per project; users receive individual signed links via `./admin.sh publish-app-link`.

---

## The two roles

### Admin

Manages the AWS environment. Uses `./admin.sh`.

Responsibilities:
- One-time setup: provision the VPC, S3 state bucket, IAM permission sets
- Add and remove users (creates IAM Identity Center accounts, provisions EC2 instances)
- Start, stop, and connect to any instance
- Handle billing, updates, and infrastructure changes

**→ [Admin Guide](README-admin.md)**

---

### User

Uses their assigned instance.

**CLI path** — uses `./user.sh` (requires Docker):
- Log in to AWS once per day (`./user.sh sso-login`)
- Connect to their instance (`./user.sh connect`)

**Browser path** — uses a signed URL (no install required):
- Open the dashboard link from their onboarding email
- Start the instance and open a terminal from the browser

**→ [CLI User Guide](README-user.md) · [Browser User Guide](README-user-web.md)**

---

> **Claude Code account required per user.** Each person using an instance needs their own [Claude Code account](https://claude.ai/code). Account creation is a per-user step that cannot be automated — each user must set it up themselves before their first session.

---

## Security model

| Control | Status | Notes |
|---------|--------|-------|
| No inbound ports on EC2 | ✅ | Security group has no ingress rules |
| SSH private key stays on your machine | ✅ | Agent forwarding; key never copied to instance |
| Per-user EC2 isolation | ✅ | Dedicated instance per user; no shared filesystem |
| SSH key isolation | ✅ | Each instance accepts its owner's key; admin key(s) are also injected at provision time for support access |
| IMDSv2 enforced | ✅ | Prevents SSRF-based credential theft |
| Storage encrypted at rest | ✅ | KMS-backed EBS and S3 |
| No public IP on EC2 | ⚠️ Optional | Default (`public` mode) assigns a public IP; `private_nat` removes it |
| Short-lived AWS credentials | ⚠️ Depends on auth method | **Option A (IAM Identity Center):** credentials auto-expire every 8–12 hours — fully satisfied. **Option B (IAM user access keys):** keys are permanent until manually rotated and don't auto-expire — weaker posture; mitigate with MFA and regular rotation. See [Credential Setup](README-admin.md#credential-setup). |
| CloudTrail / VPC Flow Logs | ❌ Deferred | Not enabled by default (cost); recommended before production use |
