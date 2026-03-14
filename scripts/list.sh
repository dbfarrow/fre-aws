#!/usr/bin/env bash
# list.sh — Lists all provisioned user instances and their current state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/defaults.env"
source "${SCRIPT_DIR}/../config/backend.env" 2>/dev/null || true

: "${AWS_REGION:?}" "${AWS_PROFILE:?}" "${PROJECT_NAME:?}"

eval "$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env-no-export 2>/dev/null | sed 's/^/export /')" || {
  echo "ERROR: Could not export credentials for profile '${AWS_PROFILE}'." >&2
  echo "       If using SSO, run './admin.sh sso-login' first." >&2
  exit 1
}

echo "=== ${PROJECT_NAME} users ==="
echo ""

RESULT=$(aws ec2 describe-instances \
  --filters "Name=tag:ProjectName,Values=${PROJECT_NAME}" \
  --query 'Reservations[].Instances[]' \
  --region "${AWS_REGION}" \
  --output json 2>/dev/null)

COUNT=$(echo "${RESULT}" | jq 'length')

if [[ "${COUNT}" -eq 0 ]]; then
  echo "  No instances found. Has './admin.sh up' been run?"
  exit 0
fi

printf "  %-15s %-22s %-12s %s\n" "USERNAME" "INSTANCE ID" "STATE" "TYPE"
printf "  %-15s %-22s %-12s %s\n" "--------" "-----------" "-----" "----"

echo "${RESULT}" | jq -r '
  sort_by((.Tags // [] | map(select(.Key == "Username")) | .[0].Value) // "")
  | .[] |
  [
    (.Tags // [] | map(select(.Key == "Username")) | .[0].Value // "(none)"),
    .InstanceId,
    .State.Name,
    .InstanceType
  ] | @tsv
' | while IFS=$'\t' read -r username instance_id state type; do
  printf "  %-15s %-22s %-12s %s\n" "${username}" "${instance_id}" "${state}" "${type}"
done

echo ""
