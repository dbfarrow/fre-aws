#!/usr/bin/env bash
# list.sh — Lists the union of registered users and EC2 instances in the VPC.
# Instances that exist in AWS but are absent from the S3 registry are shown
# separately so orphaned resources are visible.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/defaults.env"

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
# Print registered users
# ---------------------------------------------------------------------------
echo "=== ${PROJECT_NAME} users ==="
echo ""
printf "  %-20s %-22s %-12s %s\n" "USERNAME" "INSTANCE ID" "STATE" "TYPE"
printf "  %-20s %-22s %-12s %s\n" "--------" "-----------" "-----" "----"

if [[ -n "${CONFIGURED_USERS}" ]]; then
  while IFS= read -r username; do
    instance_info=$(echo "${INSTANCES}" | jq -r --arg user "${username}" '
      .[] | select(.Tags // [] | any(.Key == "Username" and .Value == $user))
      | "\(.InstanceId)\t\(.State.Name)\t\(.InstanceType)"
    ' | head -1)

    if [[ -n "${instance_info}" ]]; then
      IFS=$'\t' read -r instance_id state type <<< "${instance_info}"
      printf "  %-20s %-22s %-12s %s\n" "${username}" "${instance_id}" "${state}" "${type}"
    else
      printf "  %-20s %-22s %-12s %s\n" "${username}" "(not provisioned)" "" "run ./admin.sh up"
    fi
  done <<< "${CONFIGURED_USERS}"
else
  echo "  (no registered users — run './admin.sh add-user')"
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
  echo "  --- not in registry ---"
  printf "  %-20s %-22s %-12s %s\n" "USERNAME TAG" "INSTANCE ID" "STATE" "TYPE"
  printf "  %-20s %-22s %-12s %s\n" "-----------" "-----------" "-----" "----"
  while IFS=$'\t' read -r username instance_id state type; do
    printf "  %-20s %-22s %-12s %s\n" "${username}" "${instance_id}" "${state}" "${type}"
  done <<< "${ORPHANED}"
fi

echo ""
