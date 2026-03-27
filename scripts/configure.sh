#!/usr/bin/env bash
# configure.sh — Second-admin onboarding: validates local config against
# the canonical settings in S3 and regenerates config/backend.env.
#
# Run this after the project has been bootstrapped to get a working
# local setup without running bootstrap yourself.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/admin.env"

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config/admin.env not found. Copy config/admin.env.example and edit it." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

: "${PROJECT_NAME:?PROJECT_NAME must be set in config/admin.env}"
: "${AWS_REGION:?AWS_REGION must be set in config/admin.env}"
: "${AWS_PROFILE:?AWS_PROFILE must be set in config/admin.env}"

# ---------------------------------------------------------------------------
# Verify credentials
# ---------------------------------------------------------------------------
echo "=== fre-aws configure ==="
echo "  Project: ${PROJECT_NAME}   Profile: ${AWS_PROFILE}"
echo ""

echo "Verifying credentials..."
CALLER_IDENTITY=$(aws --profile "${AWS_PROFILE}" sts get-caller-identity --output json 2>&1) || {
  echo "ERROR: AWS credentials not valid for profile '${AWS_PROFILE}'." >&2
  echo "       Run './admin.sh sso-login' first." >&2
  exit 1
}
ACCOUNT_ID=$(echo "${CALLER_IDENTITY}" | jq -r '.Account')
CALLER_ARN=$(echo "${CALLER_IDENTITY}" | jq -r '.Arn')
echo "  OK (${CALLER_ARN})"
echo ""

# ---------------------------------------------------------------------------
# Derive bucket name (same formula as bootstrap.sh)
# ---------------------------------------------------------------------------
BUCKET_NAME="${PROJECT_NAME}-${ACCOUNT_ID}-tfstate"
DYNAMODB_TABLE="${PROJECT_NAME}-${ACCOUNT_ID}-tflock"

# ---------------------------------------------------------------------------
# Check bucket exists
# ---------------------------------------------------------------------------
echo "Checking S3 bucket ${BUCKET_NAME}..."
if ! aws --profile "${AWS_PROFILE}" s3api head-bucket --bucket "${BUCKET_NAME}" &>/dev/null; then
  echo "ERROR: Bucket '${BUCKET_NAME}' not found." >&2
  echo "       This project has not been bootstrapped yet, or you are using a different AWS account." >&2
  echo "       Ask the super-admin to run './admin.sh bootstrap' first." >&2
  exit 1
fi

BUCKET_REGION=$(aws --profile "${AWS_PROFILE}" s3api get-bucket-location \
  --bucket "${BUCKET_NAME}" \
  --query 'LocationConstraint' \
  --output text 2>/dev/null)
[[ "${BUCKET_REGION}" == "None" || -z "${BUCKET_REGION}" ]] && BUCKET_REGION="us-east-1"
echo "  found (${BUCKET_REGION})"
echo ""

# ---------------------------------------------------------------------------
# Download canonical settings
# ---------------------------------------------------------------------------
SETTINGS_KEY="${PROJECT_NAME}/settings.json"
echo "Downloading canonical settings..."
CANONICAL_JSON=$(aws --profile "${AWS_PROFILE}" --region "${BUCKET_REGION}" \
  s3 cp "s3://${BUCKET_NAME}/${SETTINGS_KEY}" - 2>/dev/null) || {
  echo "ERROR: Could not download s3://${BUCKET_NAME}/${SETTINGS_KEY}" >&2
  echo "       The project may have been bootstrapped with an older version of fre-aws." >&2
  echo "       Ask the super-admin to re-run './admin.sh bootstrap' to create the settings file." >&2
  exit 1
}
echo "  done"
echo ""

# ---------------------------------------------------------------------------
# Drift check
# ---------------------------------------------------------------------------
echo "Drift check:"
_drift=false
_chk() {
  local label="$1" canonical="$2" local_val="$3"
  if [[ "${canonical}" != "${local_val}" ]]; then
    printf "  %-20s %-8s canonical=%-16s local=%s\n" "${label}" "WARNING:" "${canonical}" "${local_val}"
    _drift=true
  else
    printf "  %-20s %-8s %s\n" "${label}" "OK" "${canonical}"
  fi
}

_chk "aws_region"         "$(echo "${CANONICAL_JSON}" | jq -r '.aws_region // empty')"         "${AWS_REGION}"
_chk "network_mode"       "$(echo "${CANONICAL_JSON}" | jq -r '.network_mode // empty')"       "${NETWORK_MODE:-public}"
_chk "use_spot"           "$(echo "${CANONICAL_JSON}" | jq -r '.use_spot // empty')"           "${USE_SPOT:-false}"
_chk "identity_mode"      "$(echo "${CANONICAL_JSON}" | jq -r '.identity_mode // empty')"      "${IDENTITY_MODE:-managed}"
_chk "ebs_volume_size_gb" "$(echo "${CANONICAL_JSON}" | jq -r '.ebs_volume_size_gb // empty')" "${EBS_VOLUME_SIZE_GB:-30}"
_LOCAL_CORP_CA="false"; [[ -n "${CORP_CA_CERT_FILE:-}" ]] && _LOCAL_CORP_CA="true"
_chk "corp_ca_cert_required" "$(echo "${CANONICAL_JSON}" | jq -r '.corp_ca_cert_required // empty')" "${_LOCAL_CORP_CA}"
unset _LOCAL_CORP_CA
echo ""

# ---------------------------------------------------------------------------
# Write backend.env
# ---------------------------------------------------------------------------
BACKEND_CONFIG_FILE="${SCRIPT_DIR}/../config/backend.env"
echo "Generating config/backend.env..."
cat > "${BACKEND_CONFIG_FILE}" <<EOF
# Auto-generated by configure.sh — do not edit manually.
TF_BACKEND_BUCKET=${BUCKET_NAME}
TF_BACKEND_REGION=${BUCKET_REGION}
TF_BACKEND_DYNAMODB_TABLE=${DYNAMODB_TABLE}
TF_BACKEND_ACCOUNT_ID=${ACCOUNT_ID}
EOF
echo "  done"
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "=== Configure complete ==="
if [[ "${_drift}" == "true" ]]; then
  echo ""
  echo "WARNING: Local admin.env differs from canonical settings."
  echo "  Review the warnings above and update config/admin.env to match."
  echo "  Mismatches can cause conflicting infrastructure when multiple admins run 'up'."
fi
echo ""
echo "Next steps:"
echo "  1. Fix any mismatches above in config/admin.env."
echo "  2. Run './admin.sh sso-login' to authenticate."
echo "  3. Run './admin.sh up <username>' to provision or update instances."
echo ""
