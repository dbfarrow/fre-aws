#!/usr/bin/env bash
# list.sh — Lists configured users and their current EC2 instance state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/defaults.env"
source "${SCRIPT_DIR}/../config/backend.env" 2>/dev/null || true

: "${AWS_REGION:?}" "${AWS_PROFILE:?}" "${PROJECT_NAME:?}"

USERS_TFVARS="${SCRIPT_DIR}/../config/users.tfvars"
if [[ ! -f "${USERS_TFVARS}" ]]; then
  echo "ERROR: config/users.tfvars not found." >&2
  echo "       Copy the example and add your users:" >&2
  echo "         cp config/users.tfvars.example config/users.tfvars" >&2
  exit 1
fi

CREDS=$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env-no-export 2>&1) || {
  echo "ERROR: Could not export credentials for profile '${AWS_PROFILE}'." >&2
  echo "       Run './admin.sh sso-login' first." >&2
  exit 1
}
eval "$(echo "${CREDS}" | sed 's/^/export /')"

# Extract usernames from users.tfvars — matches lines like:   alice = {
CONFIGURED_USERS=$(grep -E '^\s+"?[a-zA-Z0-9_.@-]+"? = \{' "${USERS_TFVARS}" | awk '{gsub(/"/, "", $1); print $1}' | sort)

if [[ -z "${CONFIGURED_USERS}" ]]; then
  echo "No users configured in config/users.tfvars."
  exit 0
fi

# Fetch all non-terminated instances for this project
INSTANCES=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:ProjectName,Values=${PROJECT_NAME}" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
  --query 'Reservations[].Instances[]' \
  --region "${AWS_REGION}" \
  --output json 2>/dev/null)

echo "=== ${PROJECT_NAME} users ==="
echo ""
printf "  %-15s %-22s %-12s %s\n" "USERNAME" "INSTANCE ID" "STATE" "TYPE"
printf "  %-15s %-22s %-12s %s\n" "--------" "-----------" "-----" "----"

while IFS= read -r username; do
  instance_info=$(echo "${INSTANCES}" | jq -r --arg user "${username}" '
    .[] | select(.Tags // [] | any(.Key == "Username" and .Value == $user))
    | "\(.InstanceId)\t\(.State.Name)\t\(.InstanceType)"
  ' | head -1)

  if [[ -n "${instance_info}" ]]; then
    IFS=$'\t' read -r instance_id state type <<< "${instance_info}"
    printf "  %-15s %-22s %-12s %s\n" "${username}" "${instance_id}" "${state}" "${type}"
  else
    printf "  %-15s %-22s %-12s %s\n" "${username}" "(not provisioned)" "" "run ./admin.sh up"
  fi
done <<< "${CONFIGURED_USERS}"

echo ""
