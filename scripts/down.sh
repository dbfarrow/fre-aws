#!/usr/bin/env bash
# down.sh — Destroys user EC2 instances and optionally base infrastructure.
#
# Usage: down.sh [username]
#   No username: destroys ALL user instances, then the base (full teardown).
#   With username: destroys only that user's instance; base is preserved.
#
# WARNING: Destruction is irreversible. All EBS data will be permanently deleted.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/admin.env"
BACKEND_CONFIG_FILE="${SCRIPT_DIR}/../config/backend.env"
TF_BASE_DIR="${SCRIPT_DIR}/../terraform"
TF_USER_DIR="${SCRIPT_DIR}/../terraform/user"

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
: "${TF_BACKEND_BUCKET:?}" "${TF_BACKEND_REGION:?}" "${TF_BACKEND_DYNAMODB_TABLE:?}"

TARGET_USER="${1:-}"
BASE_KEY="${PROJECT_NAME}/base/terraform.tfstate"

# ---------------------------------------------------------------------------
# Download user registry
# ---------------------------------------------------------------------------
USERS_JSON=$(mktemp)
trap 'rm -f "${USERS_JSON}"' EXIT

users_s3_download "${USERS_JSON}"

# Determine destroy scope
if [[ -n "${TARGET_USER}" ]]; then
  DESTROY_BASE=false
  DESTROY_USERS=("${TARGET_USER}")
else
  DESTROY_BASE=true
  mapfile -t DESTROY_USERS < <(jq -r 'keys[]' "${USERS_JSON}")
fi

# ---------------------------------------------------------------------------
# Confirmation — single prompt before any destruction begins.
# Set SKIP_DOWN_CONFIRM=true to bypass (e.g. when called from remove-user.sh
# which has already collected its own confirmation).
# ---------------------------------------------------------------------------
if [[ "${SKIP_DOWN_CONFIRM:-}" != "true" ]]; then
  echo "=== fre-aws down ==="
  echo ""

  if [[ -n "${TARGET_USER}" ]]; then
    echo "WARNING: This will DESTROY ${TARGET_USER}'s EC2 instance and all associated resources."
    echo "         The user's EBS data will be permanently deleted."
    echo "         Base infrastructure (VPC, KMS, security groups) will be preserved."
    echo ""
    echo "  User:    ${TARGET_USER}"
    echo "  Project: ${PROJECT_NAME}"
    echo "  Region:  ${AWS_REGION}"
    echo ""
    read -r -p "Type the username to confirm [${TARGET_USER}]: " CONFIRM
    if [[ "${CONFIRM}" != "${TARGET_USER}" ]]; then
      echo "Confirmation did not match. Aborted."
      exit 0
    fi
  else
    echo "WARNING: This will DESTROY all user EC2 instances AND all base AWS resources."
    echo "         All user EBS data will be permanently deleted."
    echo ""
    echo "  Project: ${PROJECT_NAME}"
    echo "  Region:  ${AWS_REGION}"
    echo ""
    read -r -p "Type the project name to confirm [${PROJECT_NAME}]: " CONFIRM
    if [[ "${CONFIRM}" != "${PROJECT_NAME}" ]]; then
      echo "Confirmation did not match. Aborted."
      exit 0
    fi
  fi
  echo ""
fi

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

# ---------------------------------------------------------------------------
# Read base outputs (best-effort — fall back to placeholders for destroy).
# Terraform destroy reads resource identity from state, so variable values
# only need to satisfy type constraints; they do not affect what gets deleted.
# ---------------------------------------------------------------------------
BASE_OUTPUTS=$(terraform -chdir="${TF_BASE_DIR}" output -json 2>/dev/null || echo "{}")
SUBNET_ID=$(echo "${BASE_OUTPUTS}"         | jq -r '.subnet_id.value         // "placeholder"')
ASSOC_PUBLIC_IP=$(echo "${BASE_OUTPUTS}"   | jq -r '.associate_public_ip.value // true')
SECURITY_GROUP_ID=$(echo "${BASE_OUTPUTS}" | jq -r '.security_group_id.value  // "placeholder"')
KMS_KEY_ARN=$(echo "${BASE_OUTPUTS}"       | jq -r '.kms_key_arn.value        // "arn:aws:kms:us-east-1:000000000000:key/placeholder"')

# ---------------------------------------------------------------------------
# Per-user destroy
# ---------------------------------------------------------------------------
if [[ ${#DESTROY_USERS[@]} -gt 0 ]]; then
  echo "=== Destroying user instances ==="
  echo ""

  for username in "${DESTROY_USERS[@]}"; do
    USER_KEY="${PROJECT_NAME}/users/${username}/terraform.tfstate"
    SSH_PUBLIC_KEY=$(jq -r --arg u "${username}" '.[$u].ssh_public_key // "placeholder"'        "${USERS_JSON}")
    GIT_USER_NAME=$(jq -r --arg u "${username}"  '.[$u].git_user_name  // "placeholder"'        "${USERS_JSON}")
    GIT_USER_EMAIL=$(jq -r --arg u "${username}" '.[$u].git_user_email // "placeholder@example.com"' "${USERS_JSON}")

    echo "--- ${username}: terraform init ---"
    terraform -chdir="${TF_USER_DIR}" init \
      -backend-config="bucket=${TF_BACKEND_BUCKET}" \
      -backend-config="key=${USER_KEY}" \
      -backend-config="region=${TF_BACKEND_REGION}" \
      -backend-config="dynamodb_table=${TF_BACKEND_DYNAMODB_TABLE}" \
      -reconfigure
    echo ""

    echo "--- ${username}: terraform destroy ---"
    terraform -chdir="${TF_USER_DIR}" destroy \
      -var="username=${username}" \
      -var="ssh_public_key=${SSH_PUBLIC_KEY}" \
      -var="git_user_name=${GIT_USER_NAME}" \
      -var="git_user_email=${GIT_USER_EMAIL}" \
      -var="project_name=${PROJECT_NAME}" \
      -var="aws_region=${AWS_REGION}" \
      -var="instance_type=${INSTANCE_TYPE:-t3.micro}" \
      -var="use_spot=${USE_SPOT:-false}" \
      -var="ebs_volume_size_gb=${EBS_VOLUME_SIZE_GB:-30}" \
      -var="owner_email=${OWNER_EMAIL:-}" \
      -var="subnet_id=${SUBNET_ID}" \
      -var="associate_public_ip=${ASSOC_PUBLIC_IP}" \
      -var="security_group_id=${SECURITY_GROUP_ID}" \
      -var="kms_key_arn=${KMS_KEY_ARN}" \
      -auto-approve
    echo ""
  done
fi

# ---------------------------------------------------------------------------
# Base destroy (full teardown only)
# ---------------------------------------------------------------------------
if [[ "${DESTROY_BASE}" == true ]]; then
  echo "=== Destroying base infrastructure ==="
  echo ""

  echo "--- terraform init (base) ---"
  terraform -chdir="${TF_BASE_DIR}" init \
    -backend-config="bucket=${TF_BACKEND_BUCKET}" \
    -backend-config="key=${BASE_KEY}" \
    -backend-config="region=${TF_BACKEND_REGION}" \
    -backend-config="dynamodb_table=${TF_BACKEND_DYNAMODB_TABLE}" \
    -reconfigure
  echo ""

  echo "--- terraform destroy (base) ---"
  terraform -chdir="${TF_BASE_DIR}" destroy \
    -var="project_name=${PROJECT_NAME}" \
    -var="aws_region=${AWS_REGION}" \
    -var="network_mode=${NETWORK_MODE:-public}" \
    -var="owner_email=${OWNER_EMAIL:-}" \
    -var="billing_alert_email=${BILLING_ALERT_EMAIL:-}" \
    -var="monthly_budget_usd=${MONTHLY_BUDGET_USD:-10}" \
    -var="budget_alert_threshold_percent=${BUDGET_ALERT_THRESHOLD_PERCENT:-80}" \
    -var="anomaly_threshold_usd=${ANOMALY_THRESHOLD_USD:-5}" \
    -var="enable_anomaly_detection=${ENABLE_ANOMALY_DETECTION:-true}" \
    -var="enable_scheduled_stop=${ENABLE_SCHEDULED_STOP:-true}" \
    -var="enable_web_app=${ENABLE_WEB_APP:-false}" \
    -var="app_domain=${APP_DOMAIN:-}" \
    -var="route53_zone_id=${ROUTE53_ZONE_ID:-}" \
    -auto-approve
  echo ""
fi

echo "=== Infrastructure destroyed ==="
if [[ "${DESTROY_BASE}" == true ]]; then
  echo "Note: The S3 state bucket, DynamoDB table, and KMS key created by"
  echo "bootstrap.sh were NOT deleted. Remove them manually if no longer needed."
else
  echo "Note: Base infrastructure (VPC, KMS, security groups) is preserved."
  echo "      Run './admin.sh up ${TARGET_USER}' to reprovision the instance."
fi
