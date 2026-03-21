#!/usr/bin/env bash
# up.sh — Two-phase provisioning: base infrastructure + per-user EC2 instances.
#
# Phase 1: Apply base module (VPC, KMS, security groups, billing, web app).
# Phase 2: For each user (or the single target user), apply the user module.
#
# Usage: up.sh [username]
#   No username: provision base + all registered users.
#   With username: provision base (fast no-op if converged) + that user only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/admin.env"
BACKEND_CONFIG_FILE="${SCRIPT_DIR}/../config/backend.env"
TF_BASE_DIR="${SCRIPT_DIR}/../terraform"
TF_USER_DIR="${SCRIPT_DIR}/../terraform/user"

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
: "${TF_BACKEND_BUCKET:?}" "${TF_BACKEND_REGION:?}" "${TF_BACKEND_DYNAMODB_TABLE:?}"

TARGET_USER="${1:-}"
BASE_KEY="${PROJECT_NAME}/base/terraform.tfstate"

# ---------------------------------------------------------------------------
# Temp files
# ---------------------------------------------------------------------------
USERS_JSON=$(mktemp)
ADMIN_KEYS_TFVARS=""
trap 'rm -f "${USERS_JSON}" "${ADMIN_KEYS_TFVARS}" "${TF_BASE_DIR}/.tfplan_base" "${TF_USER_DIR}"/.tfplan_* 2>/dev/null || true' EXIT

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
# Download user registry from S3
# ---------------------------------------------------------------------------
users_s3_download "${USERS_JSON}"

# Determine which users to provision
if [[ -n "${TARGET_USER}" ]]; then
  # Verify user exists in registry
  if ! jq -e --arg u "${TARGET_USER}" '.[$u]' "${USERS_JSON}" > /dev/null 2>&1; then
    echo "ERROR: User '${TARGET_USER}' not found in registry." >&2
    echo "       Run './admin.sh add-user' to register the user first." >&2
    exit 1
  fi
  APPLY_USERS=("${TARGET_USER}")
else
  mapfile -t APPLY_USERS < <(jq -r 'keys[]' "${USERS_JSON}")
fi

# Admin SSH public key — passed in by run.sh from the host's .pub file
if [[ -n "${ADMIN_SSH_PUB_KEY:-}" ]]; then
  ADMIN_KEYS_TFVARS=$(mktemp --suffix=.tfvars)
  printf 'admin_ssh_keys = ["%s"]\n' "${ADMIN_SSH_PUB_KEY}" > "${ADMIN_KEYS_TFVARS}"
fi

echo "=== fre-aws up ==="
echo "  Project:  ${PROJECT_NAME}"
echo "  Region:   ${AWS_REGION}"
echo "  Network:  ${NETWORK_MODE:-public}"
if [[ -n "${TARGET_USER}" ]]; then
  echo "  User:     ${TARGET_USER}"
fi
echo ""

# ---------------------------------------------------------------------------
# Phase 1: Base infrastructure
# ---------------------------------------------------------------------------
echo "=== Phase 1: base infrastructure ==="
echo ""

echo "--- terraform init (base) ---"
terraform -chdir="${TF_BASE_DIR}" init \
  -backend-config="bucket=${TF_BACKEND_BUCKET}" \
  -backend-config="key=${BASE_KEY}" \
  -backend-config="region=${TF_BACKEND_REGION}" \
  -backend-config="dynamodb_table=${TF_BACKEND_DYNAMODB_TABLE}" \
  -reconfigure
echo ""

echo "--- terraform plan (base) ---"
terraform -chdir="${TF_BASE_DIR}" plan \
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
  -out="${TF_BASE_DIR}/.tfplan_base"
echo ""

read -r -p "Apply base plan? [y/N] " CONFIRM
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi
echo ""

echo "--- terraform apply (base) ---"
terraform -chdir="${TF_BASE_DIR}" apply "${TF_BASE_DIR}/.tfplan_base"
rm -f "${TF_BASE_DIR}/.tfplan_base"
echo ""

# ---------------------------------------------------------------------------
# Read base outputs to wire into per-user plans
# ---------------------------------------------------------------------------
BASE_OUTPUTS=$(terraform -chdir="${TF_BASE_DIR}" output -json)
SUBNET_ID=$(echo "${BASE_OUTPUTS}"         | jq -r '.subnet_id.value')
ASSOC_PUBLIC_IP=$(echo "${BASE_OUTPUTS}"   | jq -r '.associate_public_ip.value')
SECURITY_GROUP_ID=$(echo "${BASE_OUTPUTS}" | jq -r '.security_group_id.value')
KMS_KEY_ARN=$(echo "${BASE_OUTPUTS}"       | jq -r '.kms_key_arn.value')

# CloudFront cache invalidation (web app only)
CF_DIST_ID=$(echo "${BASE_OUTPUTS}" | jq -r '.app_cloudfront_distribution_id.value // empty')
if [[ -n "${CF_DIST_ID}" ]]; then
  echo "--- invalidating CloudFront cache (${CF_DIST_ID}) ---"
  aws cloudfront create-invalidation \
    --distribution-id "${CF_DIST_ID}" \
    --paths "/*" \
    --output json | jq -r '"  Invalidation: \(.Invalidation.Id) (\(.Invalidation.Status))"'
  echo ""
fi

# ---------------------------------------------------------------------------
# Phase 2: Per-user EC2 instances
# ---------------------------------------------------------------------------
if [[ ${#APPLY_USERS[@]} -eq 0 ]]; then
  echo "No users registered. Run './admin.sh add-user' first."
  echo ""
  echo "=== Base infrastructure ready ==="
  echo "${BASE_OUTPUTS}" | jq -r '"  Network mode:    \(.network_mode.value)", "", .billing_alerts.value'
  exit 0
fi

echo "=== Phase 2: per-user instances ==="
echo ""

DEPLOYED_USERS=()
for username in "${APPLY_USERS[@]}"; do
  USER_KEY="${PROJECT_NAME}/users/${username}/terraform.tfstate"
  SSH_PUBLIC_KEY=$(jq -r --arg u "${username}" '.[$u].ssh_public_key' "${USERS_JSON}")
  GIT_USER_NAME=$(jq -r --arg u "${username}" '.[$u].git_user_name'   "${USERS_JSON}")
  GIT_USER_EMAIL=$(jq -r --arg u "${username}" '.[$u].git_user_email' "${USERS_JSON}")

  echo "--- ${username}: terraform init ---"
  terraform -chdir="${TF_USER_DIR}" init \
    -backend-config="bucket=${TF_BACKEND_BUCKET}" \
    -backend-config="key=${USER_KEY}" \
    -backend-config="region=${TF_BACKEND_REGION}" \
    -backend-config="dynamodb_table=${TF_BACKEND_DYNAMODB_TABLE}" \
    -reconfigure
  echo ""

  EXTRA_USER_ARGS=()
  [[ -n "${ADMIN_KEYS_TFVARS}" ]] && EXTRA_USER_ARGS+=("-var-file=${ADMIN_KEYS_TFVARS}")

  echo "--- ${username}: terraform plan ---"
  terraform -chdir="${TF_USER_DIR}" plan \
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
    "${EXTRA_USER_ARGS[@]}" \
    -out="${TF_USER_DIR}/.tfplan_${username}"
  echo ""

  read -r -p "Apply plan for ${username}? [y/N] " CONFIRM
  if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
    echo "Skipping ${username}."
    rm -f "${TF_USER_DIR}/.tfplan_${username}"
    echo ""
    continue
  fi
  echo ""

  echo "--- ${username}: terraform apply ---"
  terraform -chdir="${TF_USER_DIR}" apply "${TF_USER_DIR}/.tfplan_${username}"
  rm -f "${TF_USER_DIR}/.tfplan_${username}"

  INSTANCE_ID=$(terraform -chdir="${TF_USER_DIR}" output -raw instance_id 2>/dev/null || echo "unknown")
  DEPLOYED_USERS+=("${username}  →  ${INSTANCE_ID}")
  echo ""
done

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------
echo "=== Environment ready ==="
echo "${BASE_OUTPUTS}" | jq -r '"  Network mode:    \(.network_mode.value)"'
if [[ ${#DEPLOYED_USERS[@]} -gt 0 ]]; then
  echo ""
  echo "  Users deployed:"
  for entry in "${DEPLOYED_USERS[@]}"; do
    echo "    ${entry}"
  done
fi
echo ""
echo "  To connect:      ./admin.sh connect <username>"
echo ""
echo "${BASE_OUTPUTS}" | jq -r '.billing_alerts.value'
