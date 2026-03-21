# Backlog

## Onboarding flow improvements

A set of related issues with the user onboarding flow. Should be designed and implemented together.

### Issue 1: Onboarding files must live in S3, not on the admin's local machine

Currently `config/onboarding/<username>/` (containing `user.env`, `aws-config`, and optionally the SSH private key `fre-claude`) exists only on the machine that ran `add-user`. Any admin operation that needs to rebuild the installer — `publish-installer`, `update-user-key` — fails on any other machine.

**Fix:** During `add-user`, upload the user-specific source files to S3:
- `${PROJECT_NAME}/users/<username>/user.env`
- `${PROJECT_NAME}/users/<username>/aws-config`
- `${PROJECT_NAME}/users/<username>/fre-claude` (if generated)

`publish-installer` downloads from S3 to a temp dir and builds the bundle from there. No local bundle dir required.

**Open questions before implementing:**
- What happens to the local `config/onboarding/<username>/` dir? Keep as a convenience artifact of the initial run, or stop creating/relying on it entirely?
- Does `update-user-key` have the same dependency on the local bundle dir? (Read the script before finalising scope.)
- Migration path for existing users whose files are only on disk — options: one-time `push-onboarding-files` command, or document "re-run publish-installer from the original machine first."

### Issue 2: Consolidate CLI and web onboarding into a single email

When `ENABLE_WEB_APP=true`, the admin currently runs two separate commands for a new user: `add-user` (sends CLI installer email) and `publish-app-link` (sends browser link email). The user receives two uncoordinated emails.

**Fix:** `add-user` should send a single email that covers the appropriate path(s) based on config:
- `ENABLE_WEB_APP=false` — CLI installer only (current behavior, unchanged)
- `ENABLE_WEB_APP=true` — one email presenting both paths: browser link at the top (zero-install, start here), CLI installer below (for users who prefer the native experience)

`publish-app-link` can remain as a standalone command for re-sending the magic link to an existing user, but it should no longer be part of the initial onboarding flow when web app is enabled.

**Open questions before implementing:**
- When web app is enabled, does `add-user` need to generate the signed magic link token inline, or can it delegate to the same logic used by `publish-app-link`? (Read both scripts before deciding.)
- Should the unified email always include both paths, or only the web link when web app is enabled (omitting CLI as a secondary option)?

### Issue 3: HTML email with plain-text fallback

Commands like the `curl`/`unzip`/`bash` block are hard to read and error-prone to copy-paste in plain text. The factually incorrect AWS login instruction is also harder to fix cleanly in plain text.

**Fix:**
- Emails should be HTML with a plain-text fallback (standard MIME multipart)
- Commands should be in styled `<pre>`/`<code>` blocks that are clearly copy-pasteable
- Fix the factually incorrect AWS login instruction: the login name in IAM Identity Center is the `username` field (e.g. `alice`), not the email address. The activation step (password reset flow, uses email address) and the login step need to be clearly separated and correctly described.

**Open questions before implementing:**
- What's the minimum viable HTML treatment — full branded template, or just semantic structure with a monospace code block for commands?
- Does `publish-installer` also need the HTML treatment, or just `add-user`?

### Issue 4: `add-user` should auto-verify recipient email in SES sandbox

Many deployments will operate permanently in the SES sandbox (getting out requires an AWS support request). In sandbox mode, SES will only send to verified email addresses. Currently `add-user` attempts to send the onboarding email at the end without checking whether the recipient is verified — it fails or silently drops the email if not.

There is already a standalone `verify-email` command that sends the SES verification email, but it's a separate manual step that's easy to forget.

**Fix:** In `add-user`, after collecting the user's email address, call `aws sesv2 get-email-identity` to check verification status. If unverified:
1. Automatically send the verification email (`aws sesv2 create-email-identity`)
2. Print a clear message: "Verification email sent to {email}. Once the user clicks the verification link, re-run this command to complete onboarding."
3. Exit cleanly

The IAM Identity Center user creation that happened before this point is idempotent — re-running `add-user` for the same username skips SSO user creation and picks up from where it left off. On the second run, verification passes and onboarding completes normally.

**Open questions:**
- Should this check also be present in `publish-installer` (re-sending the onboarding email)? Verification could lapse if SES identity is deleted and re-created.
- Should the standalone `verify-email` command be kept, removed, or just documented as "now handled automatically by add-user"?

---

### Issue 5: Email sending should be suppressible

Several commands send emails to end users as a side effect: `add-user`, `publish-installer`, `publish-app-link`, and possibly `update-user-key`. During development, testing, or re-publishing without re-onboarding, sending the email is disruptive and confusing.

**Recommendation: `--no-email` flag on all email-sending commands.** Default behavior (sends email) is preserved for the normal onboarding workflow. The flag suppresses sending when you just want to regenerate credentials or test the flow. The pre-signed URL / magic link is always printed to stdout regardless, so the admin can share it manually if needed.

Affects:
- `./admin.sh add-user` — `--no-email` to provision without sending
- `./admin.sh publish-installer <user>` — `--no-email` to refresh the S3 bundle and get the URL without re-emailing the user
- `./admin.sh publish-app-link <user>` — `--no-email` to get the magic link URL without emailing
- `./admin.sh update-user-key <user>` — verify whether this also sends email; apply same flag if so

The flag should be passed through from `run.sh` dispatch into each script via an env var (consistent with how `--keep-sso` is handled for `remove-user`).

---

## Per-user Terraform state

**Supersedes:** multi-environment `--env` flag (per-user isolation is a more direct solution to the same problem).

Split the monolithic Terraform state into separate state files per user, plus a shared base state for infrastructure common to all users.

**Motivation:** Currently `./admin.sh down` destroys every user's instance in one shot — there is no way to tear down or rebuild one user's environment without affecting others. Per-user state makes each user's resources independently manageable.

**Architecture:**
- `terraform/base/` — shared infra: VPC, subnets, security groups, KMS, IAM permission sets, scheduled stop Lambda, web app Lambda/CloudFront/S3 (if enabled). Applied once per project.
- `terraform/user/` — per-user infra: EC2 instance, IAM instance role, EBS volume, SSM parameters. Parameterised by username. References base outputs via remote state data sources.

**Operations:**
- `./admin.sh up` — applies base, then applies user module for each registered user
- `./admin.sh up <username>` — applies base (if needed) then just that user's module
- `./admin.sh down <username>` — destroys only that user's resources
- `./admin.sh down` — destroys all users, then base

**Enables lifecycle testing without a separate environment:** stand up a throwaway user, run the full up → connect → down → up cycle, leave other users untouched.

**Migration:** not supported. Existing environments must be rebuilt (down → up). No state migration tooling will be provided.

**Open questions before implementing:**
- How does `up.sh` orchestrate base + N users? Sequential loop, or parallel?
- Does `down` without a username require explicit confirmation per-user or one top-level confirmation?
- How are base outputs (VPC ID, subnet IDs, security group IDs) passed into the user module — remote state data source or output variables written to S3?

---

## Billing / cost visibility improvements

The `stat` command has a basic billing section (MTD spend, forecast, per-service breakdown via Cost Explorer). Things worth expanding:

- **Per-user cost breakdown** — tag EC2 instances with Username and use Cost Explorer `GROUP BY TAG` to show how much each user's instance is costing. Useful for chargebacks or just understanding who's running hot.
- **Savings summary** — if spot is enabled, estimate actual savings vs what on-demand would have cost (Cost Explorer has an `USAGE_TYPE` dimension that can distinguish spot vs on-demand).
- **Free tier tracker** — show how much of the Free Tier allowances are consumed (EC2 hours, EBS GB, S3 requests). The `get-cost-and-usage` API can filter by `RECORD_TYPE = Credit` or use the Free Tier API (`freetier:GetFreeTierUsage`, available since 2023).
- **Anomaly alerts** — if `ENABLE_ANOMALY_DETECTION=true`, surface any active anomalies from `ce:GetAnomalies` in the stat output so the admin sees them without logging into the console.
- **Historical trend** — show last 3 months of spend alongside current month for context (one more `get-cost-and-usage` call with a wider time period).
- **Right-sizing suggestions** — compare actual CPU/memory utilization (from CloudWatch) against instance type and flag instances that are consistently under 10% CPU (candidate for downsizing).
