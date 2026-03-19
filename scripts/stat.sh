#!/usr/bin/env bash
# stat.sh — Full environment status: identity, configuration, cost implications,
# infrastructure state, and user/instance summary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
if [[ ! -f "${SCRIPT_DIR}/../config/admin.env" ]]; then
  echo "ERROR: config/admin.env not found." >&2
  exit 1
fi
source "${SCRIPT_DIR}/../config/admin.env"

if [[ ! -f "${SCRIPT_DIR}/../config/backend.env" ]]; then
  echo "ERROR: config/backend.env not found. Run './admin.sh bootstrap' first." >&2
  exit 1
fi
source "${SCRIPT_DIR}/../config/backend.env"

# shellcheck source=scripts/users-s3.sh
source "${SCRIPT_DIR}/users-s3.sh"

: "${AWS_REGION:?}" "${AWS_PROFILE:?}" "${PROJECT_NAME:?}"

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------
CREDS=$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env-no-export 2>/dev/null) || {
  echo "ERROR: Could not export credentials for profile '${AWS_PROFILE}'." >&2
  echo "       Run './admin.sh sso-login' first." >&2
  exit 1
}
eval "$(echo "${CREDS}" | sed 's/^/export /')"

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
IDENTITY=$(aws sts get-caller-identity --output json 2>/dev/null || echo "{}")
ACCOUNT_ID=$(echo "${IDENTITY}" | jq -r '.Account // "unknown"')
ARN=$(echo "${IDENTITY}" | jq -r '.Arn // "unknown"')

ARN_TYPE=$(echo "${ARN}" | cut -d: -f6 | cut -d/ -f1)
case "${ARN_TYPE}" in
  assumed-role)
    RAW_ROLE=$(echo "${ARN}" | sed 's|.*assumed-role/||; s|/.*||')
    SESSION=$(echo "${ARN}" | sed 's|.*/||')
    if [[ "${RAW_ROLE}" == AWSReservedSSO_* ]]; then
      ROLE_DISPLAY=$(echo "${RAW_ROLE}" | sed 's/^AWSReservedSSO_//; s/_[a-f0-9]*$//')
      IDENTITY_DISPLAY="${SESSION}  (SSO: ${ROLE_DISPLAY})"
    else
      IDENTITY_DISPLAY="${SESSION}  (role: ${RAW_ROLE})"
    fi
    ;;
  user)
    IDENTITY_DISPLAY="$(echo "${ARN}" | cut -d/ -f2-)  (IAM user)"
    ;;
  *)
    IDENTITY_DISPLAY="${ARN}"
    ;;
esac

# ---------------------------------------------------------------------------
# Auth method
# ---------------------------------------------------------------------------
if [[ -n "${SSO_REGION:-}" && -n "${SSO_START_URL:-}" ]]; then
  AUTH_METHOD="IAM Identity Center (SSO)"
  AUTH_DETAIL="${SSO_START_URL}"
else
  AUTH_METHOD="IAM user access keys"
  AUTH_DETAIL="Long-lived keys — enable MFA and rotate regularly"
fi

# ---------------------------------------------------------------------------
# Network mode
# ---------------------------------------------------------------------------
NETWORK="${NETWORK_MODE:-public}"
case "${NETWORK}" in
  public)
    NET_COST="\$0 extra"
    NET_NOTE="EC2 has public IP; all inbound traffic blocked by security group"
    ;;
  private_nat)
    NET_COST="~\$33/month"
    NET_NOTE="Private subnet + NAT Gateway (defense in depth)"
    ;;
  private_endpoints)
    NET_COST="~\$22/month"
    NET_NOTE="Private subnet + VPC endpoints (no internet access from instance)"
    ;;
  *)
    NET_COST="unknown"
    NET_NOTE=""
    ;;
esac

# ---------------------------------------------------------------------------
# Instance config
# ---------------------------------------------------------------------------
ITYPE="${INSTANCE_TYPE:-t3.micro}"
SPOT="${USE_SPOT:-true}"
EBS="${EBS_VOLUME_SIZE_GB:-30}"

if [[ "${SPOT}" == "true" ]]; then
  SPOT_NOTE="spot  (~60-90% savings vs on-demand)"
else
  SPOT_NOTE="on-demand  (set USE_SPOT=true in admin.env to save ~60-90%)"
fi

# ---------------------------------------------------------------------------
# VPC / infrastructure status
# ---------------------------------------------------------------------------
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:ProjectName,Values=${PROJECT_NAME}" \
  --query 'Vpcs[0].VpcId' \
  --region "${AWS_REGION}" \
  --output text 2>/dev/null || echo "")

if [[ -z "${VPC_ID}" || "${VPC_ID}" == "None" ]]; then
  INFRA_STATUS="not deployed  (run './admin.sh up')"
else
  INFRA_STATUS="${VPC_ID}"
fi

# ---------------------------------------------------------------------------
# Billing — Cost Explorer (global service, always us-east-1)
# ---------------------------------------------------------------------------
BILLING_MTD=""
BILLING_FORECAST=""
BILLING_SERVICES=""
BILLING_ERROR=""

MONTH_START=$(date -u +%Y-%m-01)
TOMORROW=$(date -u -d "1 day" +%Y-%m-%d 2>/dev/null || echo "")
NEXT_MONTH=$(date -u -d "$(date -u +%Y-%m-01) 1 month" +%Y-%m-%d 2>/dev/null || echo "")

if [[ -n "${TOMORROW}" && -n "${NEXT_MONTH}" ]]; then
  SPEND_JSON=$(aws ce get-cost-and-usage \
    --time-period "Start=${MONTH_START},End=${TOMORROW}" \
    --granularity MONTHLY \
    --metrics "UnblendedCost" \
    --group-by "Type=DIMENSION,Key=SERVICE" \
    --region us-east-1 \
    --output json 2>/dev/null || echo "")

  if [[ -n "${SPEND_JSON}" ]]; then
    BILLING_MTD=$(echo "${SPEND_JSON}" | jq -r '
      [.ResultsByTime[0]?.Groups[]?.Metrics.UnblendedCost.Amount | tonumber] | add // 0
      | . * 100 | round / 100
    ' 2>/dev/null || echo "")

    BILLING_SERVICES=$(echo "${SPEND_JSON}" | jq -r '
      .ResultsByTime[0]?.Groups[]? |
      select((.Metrics.UnblendedCost.Amount | tonumber) >= 0.01) |
      [.Keys[0], (.Metrics.UnblendedCost.Amount | tonumber | . * 100 | round / 100 | tostring)] |
      join("\t")
    ' 2>/dev/null | sort -t$'\t' -k2 -rn || echo "")

    # Forecast remaining days (skip on last day of month when tomorrow = next month)
    if [[ "${TOMORROW}" < "${NEXT_MONTH}" ]]; then
      FORECAST_JSON=$(aws ce get-cost-forecast \
        --time-period "Start=${TOMORROW},End=${NEXT_MONTH}" \
        --granularity MONTHLY \
        --metric UNBLENDED_COST \
        --region us-east-1 \
        --output json 2>/dev/null || echo "")

      if [[ -n "${FORECAST_JSON}" ]]; then
        # Add forecasted remaining days to actual MTD for end-of-month projection
        BILLING_FORECAST=$(echo "${FORECAST_JSON}" | jq -r \
          --argjson mtd "${BILLING_MTD:-0}" \
          '(.Total.Amount | tonumber) + $mtd | . * 100 | round / 100' \
          2>/dev/null || echo "")
      fi
    fi
  else
    BILLING_ERROR="unavailable — Cost Explorer may not be enabled on this account"
  fi
fi

# ---------------------------------------------------------------------------
# Users + instances
# ---------------------------------------------------------------------------
USERS_JSON=$(mktemp)
trap 'rm -f "${USERS_JSON}"' EXIT

users_s3_download "${USERS_JSON}"
CONFIGURED_USERS=$(jq -r 'keys[]' "${USERS_JSON}" 2>/dev/null | sort || true)
USER_COUNT=$(echo "${CONFIGURED_USERS}" | grep -c . 2>/dev/null || echo 0)

# Fetch Identity Center users not in the S3 registry (e.g. removed with --keep-sso)
ORPHANED_SSO=""
if [[ -n "${SSO_REGION:-}" ]]; then
  IDENTITY_STORE_ID=$(aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
    sso-admin list-instances \
    --query 'Instances[0].IdentityStoreId' --output text 2>/dev/null || echo "")

  if [[ -n "${IDENTITY_STORE_ID}" && "${IDENTITY_STORE_ID}" != "None" ]]; then
    SSO_USERS_JSON=$(aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
      identitystore list-users \
      --identity-store-id "${IDENTITY_STORE_ID}" \
      --max-results 100 \
      --output json 2>/dev/null || echo '{"Users":[]}')

    ORPHANED_SSO=$(echo "${SSO_USERS_JSON}" | jq -r \
      --argjson registry "$(jq -c 'keys' "${USERS_JSON}")" '
      .Users[] |
      select([.UserName] | inside($registry) | not) |
      "\(.UserName)\t\(.DisplayName // "-")\t\((.Emails // []) | map(select(.Primary == true)) | .[0].Value // "-")"
    ' 2>/dev/null || echo "")
  fi
fi

INSTANCES=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:ProjectName,Values=${PROJECT_NAME}" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
  --query 'Reservations[].Instances[]' \
  --region "${AWS_REGION}" \
  --output json 2>/dev/null || echo "[]")

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
echo ""
echo "=== ${PROJECT_NAME} ==="
echo ""
printf "  %-12s %s\n" "Account:"  "${ACCOUNT_ID}"
printf "  %-12s %s\n" "Region:"   "${AWS_REGION}"
printf "  %-12s %s\n" "Identity:" "${IDENTITY_DISPLAY}"
echo ""

echo "--- Configuration ---"
echo ""
printf "  %-12s %s\n" "Auth:"     "${AUTH_METHOD}"
printf "  %-12s %s\n" ""          "${AUTH_DETAIL}"
echo ""
printf "  %-12s %s  (%s)\n"       "Network:"  "${NETWORK}" "${NET_COST}"
[[ -n "${NET_NOTE}" ]] && printf "  %-12s %s\n" "" "${NET_NOTE}"
echo ""
printf "  %-12s %s  •  %s  •  %s GB EBS\n" "Instances:" "${ITYPE}" "${SPOT_NOTE}" "${EBS}"
echo ""

if [[ -n "${BILLING_ALERT_EMAIL:-}" ]]; then
  printf "  %-12s \$%s/month budget  •  alerts → %s\n" \
    "Billing:" "${MONTHLY_BUDGET_USD:-10}" "${BILLING_ALERT_EMAIL}"
else
  printf "  %-12s not configured\n" "Billing:"
  printf "  %-12s %s\n" "" "(set BILLING_ALERT_EMAIL in config/admin.env to enable spend alerts)"
fi
echo ""

echo "--- Infrastructure ---"
echo ""
printf "  %-12s %s\n" "VPC:"   "${INFRA_STATUS}"
printf "  %-12s s3://%s/%s\n" "State:" "${TF_BACKEND_BUCKET}" "${TF_BACKEND_KEY}"
echo ""

echo "--- Billing ---"
echo ""

if [[ -n "${BILLING_ERROR}" ]]; then
  printf "  %s\n" "${BILLING_ERROR}"
elif [[ -n "${BILLING_MTD}" ]]; then
  printf "  %-16s \$%s\n" "Month-to-date:" "${BILLING_MTD}"

  if [[ -n "${BILLING_FORECAST}" ]]; then
    BUDGET="${MONTHLY_BUDGET_USD:-}"
    if [[ -n "${BUDGET}" && "${BUDGET}" != "0" ]]; then
      PCT=$(awk "BEGIN {printf \"%.0f\", ${BILLING_FORECAST}/${BUDGET}*100}")
      printf "  %-16s \$%s projected  •  \$%s budget  (%s%%)\n" \
        "Forecast:" "${BILLING_FORECAST}" "${BUDGET}" "${PCT}"
    else
      printf "  %-16s \$%s projected\n" "Forecast:" "${BILLING_FORECAST}"
    fi
  fi

  if [[ -n "${BILLING_SERVICES}" ]]; then
    echo ""
    while IFS=$'\t' read -r svc cost; do
      printf "    %-44s \$%s\n" "${svc}" "${cost}"
    done <<< "${BILLING_SERVICES}"
  fi
else
  printf "  no spend data yet this month\n"
fi

echo ""

# Format any timestamp (ISO 8601 or "YYYY-MM-DD HH:MM:SS GMT") to local time.
format_time() {
  local ts="$1"
  [[ -z "${ts}" ]] && return
  echo "${ts}" | python3 -c "
import sys, os
from datetime import datetime, timezone
try:
    from zoneinfo import ZoneInfo
    tz = ZoneInfo(os.environ.get('TZ') or 'UTC')
except Exception:
    tz = timezone.utc
ts = sys.stdin.read().strip().replace(' GMT', '+00:00')
print(datetime.fromisoformat(ts).astimezone(tz).strftime('%m/%d %H:%M %Z'))
" 2>/dev/null || echo "${ts}"
}

# Extract and reformat the timestamp from a StateTransitionReason to local timezone.
format_reason() {
  local reason="$1"
  [[ -z "${reason}" ]] && return
  if [[ "${reason}" =~ \(([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ [A-Z]+)\) ]]; then
    format_time "${BASH_REMATCH[1]}"
  else
    echo "${reason}"
  fi
}

echo "--- Users (${USER_COUNT}) ---"
echo ""

if [[ -z "${CONFIGURED_USERS}" ]]; then
  echo "  (no registered users — run './admin.sh add-user')"
else
  printf "  %-20s %-22s %-12s %-10s %s\n" "USERNAME" "INSTANCE ID" "TYPE" "ROLE" "STATE"
  printf "  %-20s %-22s %-12s %-10s %s\n" "--------" "-----------" "----" "----" "-----"
  while IFS= read -r username; do
    instance_info=$(echo "${INSTANCES}" | jq -r --arg user "${username}" '
      .[] | select(.Tags // [] | any(.Key == "Username" and .Value == $user))
      | "\(.InstanceId)|\(.State.Name)|\(.InstanceType)|\(.StateTransitionReason // "")|\(.LaunchTime // "")"
    ' | head -1)
    role=$(jq -r --arg u "${username}" '.[$u].role // "-"' "${USERS_JSON}")

    if [[ -n "${instance_info}" ]]; then
      IFS='|' read -r instance_id state type reason launch_time <<< "${instance_info}"
      if [[ "${state}" == "running" && -n "${launch_time}" ]]; then
        up_since=$(format_time "${launch_time}")
        state_col="${state}  (up since ${up_since})"
      elif [[ -n "${reason}" ]]; then
        state_col="${state}  $(format_reason "${reason}")"
      else
        state_col="${state}"
      fi
      printf "  %-20s %-22s %-12s %-10s %s\n" \
        "${username}" "${instance_id}" "${type}" "${role}" "${state_col}"
    else
      printf "  %-20s %-22s %-12s %-10s %s\n" \
        "${username}" "(not provisioned)" "" "${role}" ""
    fi
  done <<< "${CONFIGURED_USERS}"
fi

if [[ -n "${ORPHANED_SSO}" ]]; then
  echo ""
  echo "  --- identity center only (no fre-aws entry) ---"
  printf "  %-20s %-25s %s\n" "USERNAME" "DISPLAY NAME" "EMAIL"
  printf "  %-20s %-25s %s\n" "--------" "------------" "-----"
  while IFS=$'\t' read -r username display_name email; do
    printf "  %-20s %-25s %s\n" "${username}" "${display_name}" "${email}"
  done <<< "${ORPHANED_SSO}"
fi

echo ""
