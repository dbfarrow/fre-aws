#!/usr/bin/env bash
# plan-base.sh — Run terraform plan on the base module and show only resources
# that would be created or already exist (import candidates).
# Run from inside ./admin.sh shell.
set -uo pipefail

source /workspace/config/admin.env
source /workspace/config/backend.env

terraform -chdir=/workspace/terraform init \
  -backend-config="bucket=${TF_BACKEND_BUCKET}" \
  -backend-config="key=fre-aws/base/terraform.tfstate" \
  -backend-config="region=${TF_BACKEND_REGION}" \
  -reconfigure -input=false -no-color 2>&1 | tail -1

export TF_VAR_project_name="fre-aws"
export TF_VAR_aws_region="us-west-2"
export TF_VAR_enable_web_app="${ENABLE_WEB_APP:-false}"
export TF_VAR_enable_scheduled_stop="${ENABLE_SCHEDULED_STOP:-true}"
export TF_VAR_monthly_budget_usd="${MONTHLY_BUDGET_USD:-10}"
export TF_VAR_budget_alert_threshold_percent="${BUDGET_ALERT_THRESHOLD_PERCENT:-80}"
export TF_VAR_anomaly_threshold_usd="${ANOMALY_THRESHOLD_USD:-5}"
export TF_VAR_enable_anomaly_detection="${ENABLE_ANOMALY_DETECTION:-true}"
export TF_VAR_enable_slack_bot="${ENABLE_SLACK_BOT:-false}"
export TF_VAR_slack_command_name="${SLACK_COMMAND_NAME:-fre}"
export TF_VAR_tf_backend_bucket="${TF_BACKEND_BUCKET}"
export TF_VAR_tf_backend_region="${TF_BACKEND_REGION}"
export TF_VAR_billing_alert_email="${BILLING_ALERT_EMAIL:-}"

terraform -chdir=/workspace/terraform plan -no-color 2>&1 | grep -E "will be created|will be updated|will be destroyed|must be replaced|Plan:"
