# Backlog

## Onboarding flow improvements

A set of related issues with the user onboarding flow. Should be designed and implemented together.

### ~~Issue 1: Onboarding files must live in S3, not on the admin's local machine~~ ✅ Resolved (PR #5)

`add-user` now uploads `user.env`, `aws-config`, and `fre-claude` (if generated) to S3 under `${PROJECT_NAME}/users/<username>/` immediately after writing local files. `publish-installer`, `update-user-key`, and `_create_installer_bundle` all download from S3 — no local bundle dir required.

Local `config/onboarding/<username>/` is still written during `add-user` as a convenience artifact but is no longer required by any subsequent command.

Migration path for existing users: auto-migrate. When `_create_installer_bundle` is called with a local bundle dir and S3 files are absent, it copies local → S3 transparently (one-time, no manual step).

### ~~Issue 2: Consolidate CLI and web onboarding into a single email~~ ✅ Resolved (PR #6)

`add-user` now generates a browser app link when `WEB_APP_URL` is set and sends a single unified email: browser link section at the top (large button, no-install path), CLI installer steps below. The app link token generation is shared via `scripts/app-link.sh` (`_generate_app_link_url()`), which both `add-user` and `publish-app-link` source. `publish-app-link` remains available for re-sending the magic link to existing users.

### ~~Issue 3: HTML email with plain-text fallback~~ ✅ Resolved (PR #6)

All onboarding emails now send `multipart/alternative` (plain text + HTML). Styled card layout with inline CSS (Gmail-safe): white card on grey background, monospace `<pre>` command blocks, optional HTTPS banner image via `LOGO_URL` in `admin.env`. The AWS activation instructions were also corrected: username entry comes first on the SSO portal login page (before "Forgot password"), and the password reset is sent automatically — the user never types their email address.

### ~~Issue 4: `add-user` should auto-verify recipient email in SES sandbox~~ ✅ Resolved (PR #5)

Both `add-user` and `publish-installer` now check SES verification status before sending. If the recipient is unverified, they trigger the AWS verification email and exit cleanly with a message directing the admin to run `./admin.sh publish-installer <username>` once the user clicks the link. All prior steps (IAM user, registry, installer bundle) are already complete at that point.

Note: the re-entry point is `publish-installer`, not `add-user` re-run (the registry already has the user so `add-user` would error). The standalone `verify-email` command remains available for manual pre-verification.

---

### ~~Issue 5: Email sending should be suppressible~~ ✅ Resolved (PR #6)

`--no-email` flag added to `add-user`, `publish-installer`, and `publish-app-link`. Skips SES send and prints the URL(s) to the console instead. `SENDER_EMAIL` is not required when `--no-email` is passed to `add-user`. Passed into containers via `NO_EMAIL_SEND` env var, consistent with the `--keep-sso` / `KEEP_SSO_USER` pattern.

`update-user-key` does not send email (verified: it only uploads key files to S3 and updates the registry), so no flag needed there.

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

## Merge `list` and `stat` commands

`list` and `stat` serve overlapping purposes and share duplicated code: identical `format_time()` / `format_reason()` helpers, the same EC2 `describe-instances` query, and the same SSO orphan detection block. The user table in `stat` is essentially a superset of `list`.

**Proposal:** Make `stat` the single command (it already includes everything `list` shows, plus identity, config, billing, and infrastructure status). Keep `list` as an alias or a thin wrapper that calls `stat --users-only` to preserve the fast daily-use case without the billing API calls.

**Options:**
- `stat` — full output (current behavior)
- `stat --users` or `list` — users table only, skip billing/infra sections (fast path, no Cost Explorer call)
- `list -v` verbose mode → `stat --users --verbose` or just fold into `stat --verbose`

**What to deduplicate:**
- `format_time()` and `format_reason()` — extract to a shared lib (e.g. `scripts/lib.sh`) sourced by both
- EC2 `describe-instances` call — already identical in both files
- SSO orphan detection block — ~20 lines, identical in both files

**Migration:** `list` command in `run.sh` can remain as an alias to `stat --users` so existing muscle memory works.

---

## Billing / cost visibility improvements

The `stat` command has a basic billing section (MTD spend, forecast, per-service breakdown via Cost Explorer). Things worth expanding:

- **Per-user cost breakdown** — tag EC2 instances with Username and use Cost Explorer `GROUP BY TAG` to show how much each user's instance is costing. Useful for chargebacks or just understanding who's running hot.
- **Savings summary** — if spot is enabled, estimate actual savings vs what on-demand would have cost (Cost Explorer has an `USAGE_TYPE` dimension that can distinguish spot vs on-demand).
- **Free tier tracker** — show how much of the Free Tier allowances are consumed (EC2 hours, EBS GB, S3 requests). The `get-cost-and-usage` API can filter by `RECORD_TYPE = Credit` or use the Free Tier API (`freetier:GetFreeTierUsage`, available since 2023).
- **Anomaly alerts** — if `ENABLE_ANOMALY_DETECTION=true`, surface any active anomalies from `ce:GetAnomalies` in the stat output so the admin sees them without logging into the console.
- **Historical trend** — show last 3 months of spend alongside current month for context (one more `get-cost-and-usage` call with a wider time period).
- **Right-sizing suggestions** — compare actual CPU/memory utilization (from CloudWatch) against instance type and flag instances that are consistently under 10% CPU (candidate for downsizing).
