#!/usr/bin/env bash
# down.sh — Destroys all AWS infrastructure managed by Terraform.
# WARNING: This deletes all user EC2 instances and associated resources.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/defaults.env"
BACKEND_CONFIG_FILE="${SCRIPT_DIR}/../config/backend.env"
TF_DIR="${SCRIPT_DIR}/../terraform"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config/defaults.env not found." >&2
  echo "       Copy the example and fill in your values:" >&2
  echo "         cp config/defaults.env.example config/defaults.env" >&2
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

: "${TF_BACKEND_BUCKET:?}" "${TF_BACKEND_REGION:?}"

# ---------------------------------------------------------------------------
# Download user registry from S3 and render to tfvars
# ---------------------------------------------------------------------------
USERS_JSON=$(mktemp)
USERS_TFVARS=$(mktemp)
trap 'rm -f "${USERS_JSON}" "${USERS_TFVARS}"' EXIT

users_s3_download "${USERS_JSON}"
users_render_tfvars "${USERS_JSON}" "${USERS_TFVARS}"

echo "=== fre-aws down ==="
echo ""
echo "WARNING: This will DESTROY all user EC2 instances and all associated AWS resources."
echo "         All user EBS data will be permanently deleted."
echo ""
echo "  Project: ${PROJECT_NAME}"
echo "  Region:  ${AWS_REGION}"
echo ""
read -r -p "Type the project name to confirm destruction [${PROJECT_NAME}]: " CONFIRM

if [[ "${CONFIRM}" != "${PROJECT_NAME}" ]]; then
  echo "Confirmation did not match. Aborted."
  exit 0
fi
echo ""

# ---------------------------------------------------------------------------
# Export credentials for Terraform
# ---------------------------------------------------------------------------
echo "--- exporting AWS credentials ---"
eval "$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env-no-export 2>/dev/null | sed 's/^/export /')" || {
  echo "ERROR: Could not export credentials for profile '${AWS_PROFILE}'." >&2
  echo "       If using SSO, run './admin.sh sso-login' first." >&2
  exit 1
}
echo ""

echo "--- terraform init ---"
terraform -chdir="${TF_DIR}" init \
  -backend-config="bucket=${TF_BACKEND_BUCKET}" \
  -backend-config="key=${TF_BACKEND_KEY}" \
  -backend-config="region=${TF_BACKEND_REGION}" \
  -backend-config="dynamodb_table=${TF_BACKEND_DYNAMODB_TABLE}" \
  -reconfigure
echo ""

echo "--- terraform destroy ---"
terraform -chdir="${TF_DIR}" destroy \
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
  -var-file="${USERS_TFVARS}"

echo ""
echo "=== Infrastructure destroyed ==="
echo "Note: The S3 state bucket, DynamoDB table, and KMS key created by"
echo "bootstrap.sh were NOT deleted. Remove them manually if no longer needed."
