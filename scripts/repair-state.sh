#!/usr/bin/env bash
# repair-state.sh — NOT COMPATIBLE with the current split-state architecture.
#
# This script was written for the monolithic state layout (all users in one
# state file with for_each = var.users). It references TF_BACKEND_KEY (removed)
# and monolithic resource addresses (e.g. aws_iam_role.user_ec2["alice"]) that
# no longer exist in the base module.
#
# To inspect or repair state manually:
#   terraform -chdir=terraform ...      (base resources)
#   terraform -chdir=terraform/user ... (user resources, after -backend-config init)
echo "ERROR: repair-state.sh is not compatible with the current split-state architecture." >&2
echo "       References TF_BACKEND_KEY (removed) and monolithic resource addresses." >&2
echo "       Use: terraform -chdir=terraform state ...      (base resources)" >&2
echo "            terraform -chdir=terraform/user state ... (user resources, after init)" >&2
exit 1

# repair-state.sh — Import per-user AWS resources that exist in AWS but are
# missing from Terraform state (e.g. after state loss or a partial apply).
#
# Uses Terraform import blocks (requires Terraform 1.5+) so that all imports
# are applied in a single atomic operation, avoiding the partial-state
# "Invalid index" errors that occur when importing resources one at a time
# inside a for_each.
#
# Usage: repair-state.sh [--dry-run] [USERNAME]
#
#   --dry-run   Show the plan without applying.
#   USERNAME    Limit scan to one user (default: all registered users).
#
# Run via: ./admin.sh repair-state [--dry-run] [USERNAME]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/admin.env"
BACKEND_CONFIG_FILE="${SCRIPT_DIR}/../config/backend.env"
TF_DIR="${SCRIPT_DIR}/../terraform"

# Temp files created during this run — cleaned up on exit
IMPORTS_TF="${TF_DIR}/imports_repair.tf"
PLAN_FILE="${TF_DIR}/.tfplan_repair"
trap 'rm -f "${IMPORTS_TF}" "${PLAN_FILE}"' EXIT

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
DRY_RUN=false
TARGET_USER=""
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=true ;;
    --*)       echo "ERROR: Unknown option: ${arg}" >&2; exit 1 ;;
    *)         TARGET_USER="${arg}" ;;
  esac
done

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: config/admin.env not found." >&2
  echo "       Copy the example: cp config/admin.env.example config/admin.env" >&2
  exit 1
fi
source "${CONFIG_FILE}"

if [[ ! -f "${BACKEND_CONFIG_FILE}" ]]; then
  echo "ERROR: config/backend.env not found. Run './admin.sh bootstrap' first." >&2
  exit 1
fi
source "${BACKEND_CONFIG_FILE}"

# shellcheck source=scripts/users-s3.sh
source "${SCRIPT_DIR}/users-s3.sh"

: "${PROJECT_NAME:?}" "${AWS_REGION:?}" "${AWS_PROFILE:?}"
: "${TF_BACKEND_BUCKET:?}" "${TF_BACKEND_KEY:?}" "${TF_BACKEND_DYNAMODB_TABLE:?}" "${TF_BACKEND_REGION:?}"

# ---------------------------------------------------------------------------
# Export AWS credentials
# ---------------------------------------------------------------------------
eval "$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env-no-export 2>/dev/null | sed 's/^/export /')" || {
  echo "ERROR: Could not export credentials for profile '${AWS_PROFILE}'." >&2
  echo "       If using SSO, run './admin.sh sso-login' first." >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Download user registry and render to tfvars
# ---------------------------------------------------------------------------
USERS_JSON=$(mktemp)
USERS_TFVARS=$(mktemp)
trap 'rm -f "${USERS_JSON}" "${USERS_TFVARS}" "${IMPORTS_TF}" "${PLAN_FILE}"' EXIT

users_s3_download "${USERS_JSON}"
users_render_tfvars "${USERS_JSON}" "${USERS_TFVARS}"

# All registered usernames — needed for target flags even when scanning one user.
mapfile -t ALL_USERS < <(jq -r 'keys[]' "${USERS_JSON}")

# Users to actively scan for orphaned resources
if [[ -n "${TARGET_USER}" ]]; then
  SCAN_USERS=("${TARGET_USER}")
else
  SCAN_USERS=("${ALL_USERS[@]}")
fi

# ---------------------------------------------------------------------------
# Terraform init
# ---------------------------------------------------------------------------
echo "--- terraform init ---"
terraform -chdir="${TF_DIR}" init \
  -backend-config="bucket=${TF_BACKEND_BUCKET}" \
  -backend-config="key=${TF_BACKEND_KEY}" \
  -backend-config="region=${TF_BACKEND_REGION}" \
  -backend-config="dynamodb_table=${TF_BACKEND_DYNAMODB_TABLE}" \
  -reconfigure -input=false 2>&1 | tail -3
echo ""

# Var flags — identical to up.sh so Terraform can resolve the full config.
TF_VARS=(
  -var="project_name=${PROJECT_NAME}"
  -var="aws_region=${AWS_REGION}"
  -var="instance_type=${INSTANCE_TYPE:-t3.micro}"
  -var="use_spot=${USE_SPOT:-true}"
  -var="network_mode=${NETWORK_MODE:-public}"
  -var="ebs_volume_size_gb=${EBS_VOLUME_SIZE_GB:-30}"
  -var="owner_email=${OWNER_EMAIL:-}"
  -var="billing_alert_email=${BILLING_ALERT_EMAIL:-}"
  -var="monthly_budget_usd=${MONTHLY_BUDGET_USD:-10}"
  -var="budget_alert_threshold_percent=${BUDGET_ALERT_THRESHOLD_PERCENT:-80}"
  -var="anomaly_threshold_usd=${ANOMALY_THRESHOLD_USD:-5}"
  -var="enable_anomaly_detection=${ENABLE_ANOMALY_DETECTION:-true}"
  -var-file="${USERS_TFVARS}"
)

SSM_POLICY_ARN="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

# ---------------------------------------------------------------------------
# Snapshot current state
# ---------------------------------------------------------------------------
echo "--- scanning state ---"
STATE_LIST=$(terraform -chdir="${TF_DIR}" state list 2>/dev/null || echo "")

echo "  Scan users: ${SCAN_USERS[*]:-none}"
[[ "${DRY_RUN}" == true ]] && echo "  Mode:       DRY RUN — plan only, no apply"
echo ""

# ---------------------------------------------------------------------------
# Collect orphaned resources
#
# Import blocks require ALL imports in a single apply to avoid partial-state
# cross-reference errors within for_each resources (e.g. importing dave's
# instance profile while test1's is missing causes "Invalid index" on
# module.user_ec2["test1"]). By batching everything into one apply, Terraform
# sees a consistent state after all imports.
# ---------------------------------------------------------------------------
declare -a IMPORT_LINES=()
IMPORT_COUNT=0
REMOVE_COUNT=0
ALREADY_OK=0
NOT_IN_AWS=0

queue_import() {
  local addr="$1" aws_id="$2" label="$3"
  if echo "${STATE_LIST}" | grep -qF "${addr}"; then
    echo "  [ok]     ${label}"
    ALREADY_OK=$((ALREADY_OK + 1))
    return
  fi
  IMPORT_LINES+=("import {")
  IMPORT_LINES+=("  to = ${addr}")
  IMPORT_LINES+=("  id = \"${aws_id}\"")
  IMPORT_LINES+=("}")
  IMPORT_LINES+=("")
  IMPORT_COUNT=$((IMPORT_COUNT + 1))
  echo "  [queue]  ${label}"
}

for USERNAME in "${SCAN_USERS[@]}"; do
  ROLE_NAME="${PROJECT_NAME}-${USERNAME}-ec2-role"
  PROFILE_NAME="${PROJECT_NAME}-${USERNAME}-ec2-profile"

  echo "=== ${USERNAME} ==="

  # IAM Role
  if aws iam get-role --role-name "${ROLE_NAME}" &>/dev/null; then
    queue_import \
      "aws_iam_role.user_ec2[\"${USERNAME}\"]" \
      "${ROLE_NAME}" \
      "IAM role: ${ROLE_NAME}"
  else
    echo "  [skip]   IAM role '${ROLE_NAME}' not found in AWS"
    NOT_IN_AWS=$((NOT_IN_AWS + 1))
  fi

  # IAM Instance Profile
  if aws iam get-instance-profile --instance-profile-name "${PROFILE_NAME}" &>/dev/null; then
    queue_import \
      "aws_iam_instance_profile.user_ec2[\"${USERNAME}\"]" \
      "${PROFILE_NAME}" \
      "IAM instance profile: ${PROFILE_NAME}"
  else
    echo "  [skip]   IAM instance profile '${PROFILE_NAME}' not found in AWS"
    NOT_IN_AWS=$((NOT_IN_AWS + 1))
  fi

  # IAM Role Policy Attachment (only if the role itself exists)
  if aws iam get-role --role-name "${ROLE_NAME}" &>/dev/null; then
    ATTACHED=$(aws iam list-attached-role-policies --role-name "${ROLE_NAME}" \
      --query "AttachedPolicies[?PolicyArn=='${SSM_POLICY_ARN}'].PolicyArn" \
      --output text 2>/dev/null || echo "")
    if [[ -n "${ATTACHED}" ]]; then
      queue_import \
        "aws_iam_role_policy_attachment.ssm_core[\"${USERNAME}\"]" \
        "${ROLE_NAME}/${SSM_POLICY_ARN}" \
        "IAM policy attachment: AmazonSSMManagedInstanceCore → ${ROLE_NAME}"
    else
      echo "  [info]   SSM policy not yet attached to ${ROLE_NAME} — 'up' will attach it"
    fi
  fi

  # EC2 Spot Instance Request
  # If a spot request is in state but terminated in AWS, Terraform cannot plan
  # at all ("reading EC2 Spot Instance Request: terminated"). Remove the entire
  # module from state so Terraform recreates the instance on the next 'up'.
  SIR_ADDR="module.user_ec2[\"${USERNAME}\"].aws_spot_instance_request.this[0]"
  if echo "${STATE_LIST}" | grep -qF "${SIR_ADDR}"; then
    SIR_ID=$(terraform -chdir="${TF_DIR}" state show "${SIR_ADDR}" 2>/dev/null \
      | grep '^\s*id\s*=' | awk '{print $3}' | tr -d '"' || echo "")
    if [[ -n "${SIR_ID}" ]]; then
      SIR_STATE=$(aws ec2 describe-spot-instance-requests \
        --spot-instance-request-ids "${SIR_ID}" \
        --query 'SpotInstanceRequests[0].State' \
        --region "${AWS_REGION}" \
        --output text 2>/dev/null || echo "")
      if [[ "${SIR_STATE}" == "terminated" || "${SIR_STATE}" == "cancelled" || "${SIR_STATE}" == "closed" ]]; then
        if [[ "${DRY_RUN}" == true ]]; then
          echo "  [remove] EC2 module state for ${USERNAME}: spot request ${SIR_ID} is ${SIR_STATE} (dry run)"
          REMOVE_COUNT=$((REMOVE_COUNT + 1))
        else
          echo "  [remove] EC2 module state for ${USERNAME}: spot request ${SIR_ID} is ${SIR_STATE}"
          terraform -chdir="${TF_DIR}" state rm "module.user_ec2[\"${USERNAME}\"]" 2>&1 \
            | sed 's/^/           /'
          STATE_LIST=$(terraform -chdir="${TF_DIR}" state list 2>/dev/null || echo "")
          REMOVE_COUNT=$((REMOVE_COUNT + 1))
        fi
      else
        echo "  [ok]     EC2 spot request ${SIR_ID} (${SIR_STATE:-unknown})"
        ALREADY_OK=$((ALREADY_OK + 1))
      fi
    fi
  fi

  echo ""
done

# ---------------------------------------------------------------------------
# Nothing to do?
# ---------------------------------------------------------------------------
if [[ "${IMPORT_COUNT}" -eq 0 && "${REMOVE_COUNT}" -eq 0 ]]; then
  echo "=== Summary ==="
  echo "  Nothing to do — state is consistent."
  echo "  Already OK: ${ALREADY_OK}"
  exit 0
fi

# State removals are already done above (direct state manipulation, no plan needed).
# Only proceed to the import block flow if there are resources to import.
if [[ "${IMPORT_COUNT}" -eq 0 ]]; then
  echo "=== Summary ==="
  [[ "${DRY_RUN}" == true ]] && echo "  Would remove: ${REMOVE_COUNT}" || echo "  Removed from state: ${REMOVE_COUNT}"
  echo "  Already OK:         ${ALREADY_OK}"
  echo ""
  echo "Run './admin.sh up' to recreate removed instances."
  exit 0
fi

# ---------------------------------------------------------------------------
# Write imports_repair.tf
# The import blocks are placed in the terraform directory so Terraform sees
# them as part of the configuration. The EXIT trap always removes this file.
# ---------------------------------------------------------------------------
{
  echo "# Auto-generated by repair-state.sh — removed automatically after apply."
  echo "# Do not commit this file."
  echo ""
  printf '%s\n' "${IMPORT_LINES[@]}"
} > "${IMPORTS_TF}"

# ---------------------------------------------------------------------------
# Build -target flags for ALL registered users' per-user IAM resources.
#
# We target every user (not just the ones being imported) so that Terraform
# can fully resolve the for_each maps across all users. Without this, a
# targeted import for "dave" would fail when Terraform tries to evaluate
# module.user_ec2["test1"]'s iam_instance_profile reference.
# ---------------------------------------------------------------------------
TARGET_FLAGS=()
for USERNAME in "${ALL_USERS[@]}"; do
  TARGET_FLAGS+=("-target=aws_iam_role.user_ec2[\"${USERNAME}\"]")
  TARGET_FLAGS+=("-target=aws_iam_instance_profile.user_ec2[\"${USERNAME}\"]")
  TARGET_FLAGS+=("-target=aws_iam_role_policy_attachment.ssm_core[\"${USERNAME}\"]")
done

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------
echo "--- terraform plan ---"
terraform -chdir="${TF_DIR}" plan \
  "${TF_VARS[@]}" \
  "${TARGET_FLAGS[@]}" \
  -out="${PLAN_FILE}"
echo ""

# ---------------------------------------------------------------------------
# Dry-run: stop after plan
# ---------------------------------------------------------------------------
if [[ "${DRY_RUN}" == true ]]; then
  echo "=== Summary (dry run) ==="
  echo "  Would import:        ${IMPORT_COUNT}"
  echo "  Would remove:        ${REMOVE_COUNT}"
  echo "  Already OK:          ${ALREADY_OK}"
  echo "  Not in AWS:          ${NOT_IN_AWS}"
  echo ""
  echo "Re-run without --dry-run to apply."
  exit 0
fi

# ---------------------------------------------------------------------------
# Confirm and apply
# ---------------------------------------------------------------------------
read -r -p "Apply ${IMPORT_COUNT} import(s)? [y/N] " CONFIRM
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "--- terraform apply ---"
terraform -chdir="${TF_DIR}" apply "${PLAN_FILE}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  Imported:            ${IMPORT_COUNT}"
echo "  Removed from state:  ${REMOVE_COUNT}"
echo "  Already OK:          ${ALREADY_OK}"
echo "  Not in AWS:          ${NOT_IN_AWS}"
echo ""
echo "State repaired. Run './admin.sh up' to apply any remaining changes."
