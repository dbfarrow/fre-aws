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

_PROFILE_ARGS=()
[[ -n "${AWS_PROFILE:-}" ]] && _PROFILE_ARGS=(--profile "${AWS_PROFILE}")

# ---------------------------------------------------------------------------
# Verify credentials
# ---------------------------------------------------------------------------
echo "=== fre-aws configure ==="
echo "  Project: ${PROJECT_NAME}   Profile: ${AWS_PROFILE:-<default>}"
echo ""

echo "Verifying credentials..."
CALLER_IDENTITY=$(aws "${_PROFILE_ARGS[@]}" sts get-caller-identity --output json 2>&1) || {
  echo "ERROR: AWS credentials not valid${AWS_PROFILE:+ for profile '${AWS_PROFILE}'}." >&2
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

# ---------------------------------------------------------------------------
# Check bucket exists
# ---------------------------------------------------------------------------
echo "Checking S3 bucket ${BUCKET_NAME}..."
if ! aws "${_PROFILE_ARGS[@]}" s3api head-bucket --bucket "${BUCKET_NAME}" &>/dev/null; then
  echo "ERROR: Bucket '${BUCKET_NAME}' not found." >&2
  echo "       This project has not been bootstrapped yet, or you are using a different AWS account." >&2
  echo "       Ask the super-admin to run './admin.sh bootstrap' first." >&2
  exit 1
fi

BUCKET_REGION=$(aws "${_PROFILE_ARGS[@]}" s3api get-bucket-location \
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
CANONICAL_JSON=$(aws "${_PROFILE_ARGS[@]}" --region "${BUCKET_REGION}" \
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
_chk "existing_vpc_id"    "$(echo "${CANONICAL_JSON}" | jq -r '.existing_vpc_id // empty')"    "${EXISTING_VPC_ID:-}"
_chk "existing_subnet_id" "$(echo "${CANONICAL_JSON}" | jq -r '.existing_subnet_id // empty')" "${EXISTING_SUBNET_ID:-}"
_chk "litellm_base_url"   "$(echo "${CANONICAL_JSON}" | jq -r '.litellm_base_url // empty')"   "${LITELLM_BASE_URL:-}"
_chk "instance_type"      "$(echo "${CANONICAL_JSON}" | jq -r '.instance_type // empty')"      "${INSTANCE_TYPE:-t3.micro}"
_chk "autoshutdown_idle_minutes" "$(echo "${CANONICAL_JSON}" | jq -r '.autoshutdown_idle_minutes // empty')" "${AUTOSHUTDOWN_IDLE_MINUTES:-30}"
_chk "sso_region"         "$(echo "${CANONICAL_JSON}" | jq -r '.sso_region // empty')"         "${SSO_REGION:-}"
_chk "sso_start_url"      "$(echo "${CANONICAL_JSON}" | jq -r '.sso_start_url // empty')"      "${SSO_START_URL:-}"
_chk "sender_email"       "$(echo "${CANONICAL_JSON}" | jq -r '.sender_email // empty')"       "${SENDER_EMAIL:-}"
_chk "logo_url"           "$(echo "${CANONICAL_JSON}" | jq -r '.logo_url // empty')"           "${LOGO_URL:-}"
_chk "billing_alert_email" "$(echo "${CANONICAL_JSON}" | jq -r '.billing_alert_email // empty')" "${BILLING_ALERT_EMAIL:-}"
_chk "monthly_budget_usd" "$(echo "${CANONICAL_JSON}" | jq -r '.monthly_budget_usd // empty')" "${MONTHLY_BUDGET_USD:-10}"
_chk "budget_alert_threshold_percent" "$(echo "${CANONICAL_JSON}" | jq -r '.budget_alert_threshold_percent // empty')" "${BUDGET_ALERT_THRESHOLD_PERCENT:-80}"
_chk "anomaly_threshold_usd" "$(echo "${CANONICAL_JSON}" | jq -r '.anomaly_threshold_usd // empty')" "${ANOMALY_THRESHOLD_USD:-5}"
_chk "enable_anomaly_detection" "$(echo "${CANONICAL_JSON}" | jq -r '.enable_anomaly_detection // empty')" "${ENABLE_ANOMALY_DETECTION:-true}"
_chk "enable_scheduled_stop" "$(echo "${CANONICAL_JSON}" | jq -r '.enable_scheduled_stop // empty')" "${ENABLE_SCHEDULED_STOP:-true}"
_chk "enable_web_app"     "$(echo "${CANONICAL_JSON}" | jq -r '.enable_web_app // empty')"     "${ENABLE_WEB_APP:-false}"
_chk "web_app_url"        "$(echo "${CANONICAL_JSON}" | jq -r '.web_app_url // empty')"        "${WEB_APP_URL:-}"
_chk "app_domain"         "$(echo "${CANONICAL_JSON}" | jq -r '.app_domain // empty')"         "${APP_DOMAIN:-}"
_chk "route53_zone_id"    "$(echo "${CANONICAL_JSON}" | jq -r '.route53_zone_id // empty')"    "${ROUTE53_ZONE_ID:-}"
_chk "bucket_policy_principal_arn" "$(echo "${CANONICAL_JSON}" | jq -r '.bucket_policy_principal_arn // empty')" "${BUCKET_POLICY_PRINCIPAL_ARN:-}"
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
