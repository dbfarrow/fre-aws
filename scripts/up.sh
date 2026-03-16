#!/usr/bin/env bash
# up.sh — Runs terraform init + plan + apply to create or update infrastructure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/admin.env"
BACKEND_CONFIG_FILE="${SCRIPT_DIR}/../config/backend.env"
TF_DIR="${SCRIPT_DIR}/../terraform"

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config/admin.env not found." >&2
  echo "       Copy the example and fill in your values:" >&2
  echo "         cp config/admin.env.example config/admin.env" >&2
  exit 1
fi
source "$CONFIG_FILE"

if [[ ! -f "$BACKEND_CONFIG_FILE" ]]; then
  echo "ERROR: config/backend.env not found. Run './admin.sh bootstrap' first." >&2
  exit 1
fi
source "$BACKEND_CONFIG_FILE"

# shellcheck source=scripts/users-s3.sh
source "${SCRIPT_DIR}/users-s3.sh"

: "${PROJECT_NAME:?}" "${AWS_REGION:?}" "${AWS_PROFILE:?}"
: "${TF_BACKEND_BUCKET:?}" "${TF_BACKEND_KEY:?}" "${TF_BACKEND_DYNAMODB_TABLE:?}" "${TF_BACKEND_REGION:?}"

# ---------------------------------------------------------------------------
# Export credentials for Terraform
# Terraform's Go SDK cannot consume the AWS CLI SSO token cache directly.
# Exporting as standard env vars bridges the gap for both SSO and key-based profiles.
# ---------------------------------------------------------------------------
echo "--- exporting AWS credentials ---"
eval "$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env-no-export 2>/dev/null | sed 's/^/export /')" || {
  echo "ERROR: Could not export credentials for profile '${AWS_PROFILE}'." >&2
  echo "       If using SSO, run './admin.sh sso-login' first." >&2
  exit 1
}
echo ""

# ---------------------------------------------------------------------------
# Download user registry from S3 and render to tfvars
# ---------------------------------------------------------------------------
USERS_JSON=$(mktemp)
USERS_TFVARS=$(mktemp)
trap 'rm -f "${USERS_JSON}" "${USERS_TFVARS}"' EXIT

users_s3_download "${USERS_JSON}"
users_render_tfvars "${USERS_JSON}" "${USERS_TFVARS}"

echo "=== fre-aws up ==="
echo "  Project:  ${PROJECT_NAME}"
echo "  Region:   ${AWS_REGION}"
echo "  Network:  ${NETWORK_MODE:-public}"
echo ""

# ---------------------------------------------------------------------------
# terraform init
# ---------------------------------------------------------------------------
echo "--- terraform init ---"
terraform -chdir="${TF_DIR}" init \
  -backend-config="bucket=${TF_BACKEND_BUCKET}" \
  -backend-config="key=${TF_BACKEND_KEY}" \
  -backend-config="region=${TF_BACKEND_REGION}" \
  -backend-config="dynamodb_table=${TF_BACKEND_DYNAMODB_TABLE}" \
  -reconfigure
echo ""

# ---------------------------------------------------------------------------
# terraform plan
# ---------------------------------------------------------------------------
echo "--- terraform plan ---"
terraform -chdir="${TF_DIR}" plan \
  -var="project_name=${PROJECT_NAME}" \
  -var="aws_region=${AWS_REGION}" \
  -var="instance_type=${INSTANCE_TYPE:-t3.micro}" \
  -var="use_spot=${USE_SPOT:-true}" \
  -var="network_mode=${NETWORK_MODE:-public}" \
  -var="ebs_volume_size_gb=${EBS_VOLUME_SIZE_GB:-30}" \
  -var="owner_email=${OWNER_EMAIL:-}" \
  -var="billing_alert_email=${BILLING_ALERT_EMAIL:-}" \
  -var="monthly_budget_usd=${MONTHLY_BUDGET_USD:-10}" \
  -var="budget_alert_threshold_percent=${BUDGET_ALERT_THRESHOLD_PERCENT:-80}" \
  -var="anomaly_threshold_usd=${ANOMALY_THRESHOLD_USD:-5}" \
  -var="enable_anomaly_detection=${ENABLE_ANOMALY_DETECTION:-true}" \
  -var-file="${USERS_TFVARS}" \
  -out="${TF_DIR}/.tfplan"
echo ""

# ---------------------------------------------------------------------------
# Confirmation prompt
# ---------------------------------------------------------------------------
read -r -p "Apply the above plan? [y/N] " CONFIRM
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  rm -f "${TF_DIR}/.tfplan"
  exit 0
fi
echo ""

# ---------------------------------------------------------------------------
# terraform apply
# ---------------------------------------------------------------------------
echo "--- terraform apply ---"
terraform -chdir="${TF_DIR}" apply "${TF_DIR}/.tfplan"
rm -f "${TF_DIR}/.tfplan"
echo ""

# ---------------------------------------------------------------------------
# Print outputs
# ---------------------------------------------------------------------------
echo "=== Environment ready ==="
terraform -chdir="${TF_DIR}" output -json | jq -r '
  "  Network mode:    \(.network_mode.value)",
  "",
  "  Users deployed:",
  (.instance_ids.value | to_entries[] | "    \(.key)  →  \(.value)"),
  "",
  "  To connect:      ./admin.sh connect <username>",
  "",
  .billing_alerts.value
'
