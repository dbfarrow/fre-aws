#!/usr/bin/env bash
# up.sh — Runs terraform init + plan + apply to create or update infrastructure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/defaults.env"
BACKEND_CONFIG_FILE="${SCRIPT_DIR}/../config/backend.env"
TF_DIR="${SCRIPT_DIR}/../terraform"

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config/defaults.env not found." >&2
  exit 1
fi
source "$CONFIG_FILE"

if [[ ! -f "$BACKEND_CONFIG_FILE" ]]; then
  echo "ERROR: config/backend.env not found. Run bootstrap.sh first." >&2
  exit 1
fi
source "$BACKEND_CONFIG_FILE"

: "${PROJECT_NAME:?}" "${AWS_REGION:?}" "${AWS_PROFILE:?}"
: "${TF_BACKEND_BUCKET:?}" "${TF_BACKEND_KEY:?}" "${TF_BACKEND_DYNAMODB_TABLE:?}" "${TF_BACKEND_KMS_KEY_ID:?}"

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
  -backend-config="kms_key_id=${TF_BACKEND_KMS_KEY_ID}" \
  -reconfigure
echo ""

# ---------------------------------------------------------------------------
# terraform plan
# ---------------------------------------------------------------------------
echo "--- terraform plan ---"
terraform -chdir="${TF_DIR}" plan \
  -var="project_name=${PROJECT_NAME}" \
  -var="aws_region=${AWS_REGION}" \
  -var="aws_profile=${AWS_PROFILE}" \
  -var="instance_type=${INSTANCE_TYPE:-t3.micro}" \
  -var="use_spot=${USE_SPOT:-true}" \
  -var="network_mode=${NETWORK_MODE:-public}" \
  -var="ebs_volume_size_gb=${EBS_VOLUME_SIZE_GB:-20}" \
  -var="owner_email=${OWNER_EMAIL:-}" \
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
  "  Instance ID:     \(.instance_id.value)",
  "  Instance state:  \(.instance_state.value)",
  "  Network mode:    \(.network_mode.value)",
  "",
  "  To connect:      \(.connect_command.value)"
'
