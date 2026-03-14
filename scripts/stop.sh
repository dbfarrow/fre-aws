#!/usr/bin/env bash
# stop.sh — Stops the running EC2 instance. Compute charges stop; EBS is retained.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/defaults.env"
source "${SCRIPT_DIR}/../config/backend.env" 2>/dev/null || true

: "${AWS_REGION:?}" "${AWS_PROFILE:?}"

TF_DIR="${SCRIPT_DIR}/../terraform"

INSTANCE_ID=$(terraform -chdir="${TF_DIR}" output -raw instance_id 2>/dev/null) || {
  echo "ERROR: Could not read instance_id from Terraform state. Has up.sh been run?" >&2
  exit 1
}

echo "Stopping instance ${INSTANCE_ID}..."
aws ec2 stop-instances \
  --instance-ids "${INSTANCE_ID}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --output json > /dev/null

echo "Waiting for instance to reach stopped state..."
aws ec2 wait instance-stopped \
  --instance-ids "${INSTANCE_ID}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"

echo "Instance ${INSTANCE_ID} is stopped. EBS data is preserved."
