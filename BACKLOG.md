# Backlog

## gh-based session launcher

Replace the SSH-based "Clone a GitHub repo" option in `session_start.sh` with a `gh`-powered flow:

1. On session start, check `gh auth status` — if not authenticated, run `gh auth login` (device code flow, same UX as SSO login)
2. Replace the freeform "owner/repo" prompt with `gh repo list` to show the user's available repos in a numbered menu
3. Clone the selected repo with `gh repo clone` (uses HTTPS + OAuth token — no SSH key in GitHub required)
4. Launch Claude Code in the cloned directory

This eliminates the "add SSH key to GitHub" prerequisite for users and replaces it with the same browser device-code flow they already do for AWS SSO and Claude login. Requires `gh` CLI to be installed on the EC2 instance (add to `user_data_main.sh`).

## Billing / cost visibility improvements

The `stat` command has a basic billing section (MTD spend, forecast, per-service breakdown via Cost Explorer). Things worth expanding:

- **Per-user cost breakdown** — tag EC2 instances with Username and use Cost Explorer `GROUP BY TAG` to show how much each user's instance is costing. Useful for chargebacks or just understanding who's running hot.
- **Savings summary** — if spot is enabled, estimate actual savings vs what on-demand would have cost (Cost Explorer has an `USAGE_TYPE` dimension that can distinguish spot vs on-demand).
- **Free tier tracker** — show how much of the Free Tier allowances are consumed (EC2 hours, EBS GB, S3 requests). The `get-cost-and-usage` API can filter by `RECORD_TYPE = Credit` or use the Free Tier API (`freetier:GetFreeTierUsage`, available since 2023).
- **Anomaly alerts** — if `ENABLE_ANOMALY_DETECTION=true`, surface any active anomalies from `ce:GetAnomalies` in the stat output so the admin sees them without logging into the console.
- **Historical trend** — show last 3 months of spend alongside current month for context (one more `get-cost-and-usage` call with a wider time period).
- **Right-sizing suggestions** — compare actual CPU/memory utilization (from CloudWatch) against instance type and flag instances that are consistently under 10% CPU (candidate for downsizing).
