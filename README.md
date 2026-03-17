# fre-aws — Claude Code on AWS

A self-hosted development environment that gives each team member a dedicated EC2 instance running [Claude Code](https://claude.ai/code). One command to connect; your admin handles everything else.

---

## What it does

Each user gets their own EC2 instance in your AWS account. The admin provisions and manages the infrastructure using Docker-packaged tooling — no Terraform or AWS CLI required on any machine. Users connect with a single command and land in a session launcher that lets them open projects, clone repos, or drop into a shell.

```
Your Mac
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

Connections use SSH tunneled through [AWS SSM Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html):

- **No open ports** — EC2 instances have no inbound firewall rules, no public IP required
- **No keys on instances** — SSH agent forwarding means your GitHub key works on the instance without ever being copied there
- **No VPN** — SSM handles the tunnel; the only requirement is valid AWS credentials

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

Uses their assigned instance. Uses `./user.sh`.

Responsibilities:
- Log in to AWS once per day (`./user.sh sso-login`)
- Connect to their instance (`./user.sh connect`)
- Stop their instance when done to avoid unnecessary charges (`./user.sh stop`)

**→ [User Guide](README-user.md)**

---

> **Claude Code account required per user.** Each person using an instance needs their own [Claude Code account](https://claude.ai/code). Account creation is a per-user step that cannot be automated — each user must set it up themselves before their first session.

---

## Security model

| Control | Status | Notes |
|---------|--------|-------|
| No inbound ports on EC2 | ✅ | Security group has no ingress rules |
| SSH private key stays on Mac | ✅ | Agent forwarding; key never copied to instance |
| Per-user EC2 isolation | ✅ | Dedicated instance per user; no shared filesystem |
| SSH key isolation | ✅ | Each instance only accepts its owner's key |
| IMDSv2 enforced | ✅ | Prevents SSRF-based credential theft |
| Storage encrypted at rest | ✅ | KMS-backed EBS and S3 |
| No public IP on EC2 | ⚠️ Optional | Default (`public` mode) assigns a public IP; `private_nat` removes it |
| Short-lived AWS credentials | ⚠️ Depends on auth method | **Option A (IAM Identity Center):** credentials auto-expire every 8–12 hours — fully satisfied. **Option B (IAM user access keys):** keys are permanent until manually rotated and don't auto-expire — weaker posture; mitigate with MFA and regular rotation. See [Credential Setup](README-admin.md#credential-setup). |
| CloudTrail / VPC Flow Logs | ❌ Deferred | Not enabled by default (cost); recommended before production use |
