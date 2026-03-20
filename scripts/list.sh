#!/usr/bin/env bash
# list.sh — Lists the union of registered users and EC2 instances in the VPC.
# Instances that exist in AWS but are absent from the S3 registry are shown
# separately so orphaned resources are visible.
#
# Usage: list.sh [--verbose|-v]
set -euo pipefail

VERBOSE=false
for arg in "$@"; do
  case "${arg}" in
    --verbose|-v) VERBOSE=true ;;
    *) echo "ERROR: Unknown option: ${arg}" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/admin.env"

if [[ ! -f "${SCRIPT_DIR}/../config/backend.env" ]]; then
  echo "ERROR: config/backend.env not found. Run './admin.sh bootstrap' first." >&2
  exit 1
fi
source "${SCRIPT_DIR}/../config/backend.env"

# shellcheck source=scripts/users-s3.sh
source "${SCRIPT_DIR}/users-s3.sh"

: "${AWS_REGION:?}" "${AWS_PROFILE:?}" "${PROJECT_NAME:?}"
: "${TF_BACKEND_BUCKET:?}" "${TF_BACKEND_REGION:?}"

CREDS=$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env-no-export 2>/dev/null) || {
  echo "ERROR: Could not export credentials for profile '${AWS_PROFILE}'." >&2
  echo "       Run './admin.sh sso-login' first." >&2
  exit 1
}
eval "$(echo "${CREDS}" | sed 's/^/export /')"

# ---------------------------------------------------------------------------
# Download user registry from S3
# ---------------------------------------------------------------------------
USERS_JSON=$(mktemp)
trap 'rm -f "${USERS_JSON}"' EXIT

users_s3_download "${USERS_JSON}"
CONFIGURED_USERS=$(jq -r 'keys[]' "${USERS_JSON}" | sort)

# ---------------------------------------------------------------------------
# Fetch Identity Center users not in the S3 registry (e.g. removed with --keep-sso)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Fetch all non-terminated instances for this project's VPC
# ---------------------------------------------------------------------------
INSTANCES=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:ProjectName,Values=${PROJECT_NAME}" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
  --query 'Reservations[].Instances[]' \
  --region "${AWS_REGION}" \
  --output json 2>/dev/null)

# ---------------------------------------------------------------------------
# Format any timestamp (ISO 8601 or "YYYY-MM-DD HH:MM:SS GMT") to local time.
# Output: "03/18 21:23 PDT"
# ---------------------------------------------------------------------------
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
# Input:  "User initiated (2026-03-18 05:23:41 GMT)"
# Output: "03/18 21:23 PDT"
# ---------------------------------------------------------------------------
format_reason() {
  local reason="$1"
  [[ -z "${reason}" ]] && return
  if [[ "${reason}" =~ \(([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ [A-Z]+)\) ]]; then
    format_time "${BASH_REMATCH[1]}"
  else
    echo "${reason}"
  fi
}

# ---------------------------------------------------------------------------
# App login URL generation (only when WEB_APP_URL is configured)
# HMAC secret is fetched from SSM once on first use and cached.
# ---------------------------------------------------------------------------
_HMAC_SECRET=""
_HMAC_FETCH_DONE=false

_get_hmac_secret() {
  [[ "${_HMAC_FETCH_DONE}" == true ]] && return
  _HMAC_FETCH_DONE=true
  _HMAC_SECRET=$(aws ssm get-parameter \
    --name "/${PROJECT_NAME}/app/hmac-secret" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text \
    --region "${AWS_REGION}" 2>/dev/null || echo "")
}

_make_app_link() {
  local username="$1"
  [[ -z "${WEB_APP_URL:-}" ]] && return
  _get_hmac_secret
  [[ -z "${_HMAC_SECRET}" ]] && return
  local expiry=$(( $(date +%s) + 259200 ))
  local payload="${username}:${expiry}"
  local hmac_hex
  hmac_hex=$(printf '%s' "${payload}" | openssl dgst -sha256 -hmac "${_HMAC_SECRET}" -hex | awk '{print $NF}')
  local token
  token=$(printf '%s' "${payload}:${hmac_hex}" | base64 | tr '+/' '-_' | tr -d '=' | tr -d '\n')
  echo "${WEB_APP_URL%/}?token=${token}"
}

# ---------------------------------------------------------------------------
# Print registered users
# ---------------------------------------------------------------------------
echo "=== ${PROJECT_NAME} users ==="
echo ""

if [[ -z "${CONFIGURED_USERS}" ]]; then
  echo "  (no registered users — run './admin.sh add-user')"
elif [[ "${VERBOSE}" == true ]]; then
  while IFS= read -r username; do
    instance_info=$(echo "${INSTANCES}" | jq -r --arg user "${username}" '
      .[] | select(.Tags // [] | any(.Key == "Username" and .Value == $user))
      | "\(.InstanceId)|\(.State.Name)|\(.InstanceType)|\(.StateTransitionReason // "")|\(.LaunchTime // "")"
    ' | head -1)

    echo "  ${username}"

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
      printf "    %-16s %s  %s  %s\n" "instance:" "${instance_id}" "${type}" "${state_col}"
      if [[ "${state}" == "running" ]]; then
        app_link=$(_make_app_link "${username}")
        [[ -n "${app_link}" ]] && printf "    %-16s %s\n" "login url:" "${app_link}"
      fi
    else
      printf "    %-16s %s\n" "instance:" "(not provisioned — run ./admin.sh up)"
    fi

    # Pull attributes from registry
    user_email=$(jq -r --arg u "${username}" '.[$u].user_email   // "-"' "${USERS_JSON}")
    role=$(      jq -r --arg u "${username}" '.[$u].role         // "-"' "${USERS_JSON}")
    git_name=$(  jq -r --arg u "${username}" '.[$u].git_user_name  // "-"' "${USERS_JSON}")
    git_email=$( jq -r --arg u "${username}" '.[$u].git_user_email // "-"' "${USERS_JSON}")
    ssh_key=$(   jq -r --arg u "${username}" '.[$u].ssh_public_key // "-"' "${USERS_JSON}")
    ssh_key_short="${ssh_key:0:50}..."

    printf "    %-16s %s\n" "email:"    "${user_email}"
    printf "    %-16s %s\n" "role:"     "${role}"
    printf "    %-16s %s\n" "git name:" "${git_name}"
    printf "    %-16s %s\n" "git email:""${git_email}"
    printf "    %-16s %s\n" "ssh key:"  "${ssh_key_short}"
    echo ""
  done <<< "${CONFIGURED_USERS}"
else
  printf "  %-20s %-22s %-12s %s\n" "USERNAME" "INSTANCE ID" "TYPE" "STATE"
  printf "  %-20s %-22s %-12s %s\n" "--------" "-----------" "----" "-----"
  while IFS= read -r username; do
    instance_info=$(echo "${INSTANCES}" | jq -r --arg user "${username}" '
      .[] | select(.Tags // [] | any(.Key == "Username" and .Value == $user))
      | "\(.InstanceId)|\(.State.Name)|\(.InstanceType)|\(.StateTransitionReason // "")|\(.LaunchTime // "")"
    ' | head -1)

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
      if [[ "${state}" == "running" ]]; then
        app_link=$(_make_app_link "${username}")
        [[ -n "${app_link}" ]] && state_col="${state_col}  ${app_link:0:50}…"
      fi
      printf "  %-20s %-22s %-12s %s\n" "${username}" "${instance_id}" "${type}" "${state_col}"
    else
      printf "  %-20s %-22s %-12s %s\n" "${username}" "(not provisioned)" "" "run ./admin.sh up"
    fi
  done <<< "${CONFIGURED_USERS}"
fi

# ---------------------------------------------------------------------------
# Find instances whose Username tag is absent or not in the registry
# ---------------------------------------------------------------------------
ORPHANED=$(echo "${INSTANCES}" | jq -r \
  --argjson registry "$(jq -c 'keys' "${USERS_JSON}")" '
  .[] |
  ((.Tags // []) | map(select(.Key == "Username")) | .[0].Value // null) as $u |
  select($u == null or ($u | IN($registry[]) | not)) |
  "\($u // "(no Username tag)")\t\(.InstanceId)\t\(.State.Name)\t\(.InstanceType)"
')

if [[ -n "${ORPHANED}" ]]; then
  echo ""
  echo "  --- orphaned instances (not in registry) ---"
  printf "  %-20s %-22s %-12s %s\n" "USERNAME TAG" "INSTANCE ID" "STATE" "TYPE"
  printf "  %-20s %-22s %-12s %s\n" "-----------" "-----------" "-----" "----"
  while IFS=$'\t' read -r username instance_id state type; do
    printf "  %-20s %-22s %-12s %s\n" "${username}" "${instance_id}" "${state}" "${type}"
  done <<< "${ORPHANED}"
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
