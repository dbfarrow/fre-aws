#!/usr/bin/env bash
# bootstrap.sh — One-time setup: creates the S3 bucket, DynamoDB table, and
# KMS key used by Terraform for remote state. Run this before up.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/defaults.env"

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config/defaults.env not found. Copy config/defaults.env.example and edit it." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

: "${PROJECT_NAME:?PROJECT_NAME must be set in config/defaults.env}"
: "${AWS_REGION:?AWS_REGION must be set in config/defaults.env}"
: "${AWS_PROFILE:?AWS_PROFILE must be set in config/defaults.env}"

BUCKET_NAME="${PROJECT_NAME}-tfstate"
DYNAMODB_TABLE="${PROJECT_NAME}-tflock"
KMS_ALIAS="alias/${PROJECT_NAME}/terraform-state"

AWS="aws --region ${AWS_REGION} --profile ${AWS_PROFILE}"

echo "=== fre-aws bootstrap ==="
echo "  Project:  ${PROJECT_NAME}"
echo "  Region:   ${AWS_REGION}"
echo "  Profile:  ${AWS_PROFILE}"
echo "  Bucket:   ${BUCKET_NAME}"
echo "  DynamoDB: ${DYNAMODB_TABLE}"
echo ""

# ---------------------------------------------------------------------------
# Verify AWS credentials
# ---------------------------------------------------------------------------
echo "Verifying AWS credentials..."
CALLER_IDENTITY=$($AWS sts get-caller-identity --output json 2>&1) || {
  echo "ERROR: AWS credentials not valid for profile '${AWS_PROFILE}'." >&2
  echo "       Run 'aws configure --profile ${AWS_PROFILE}' to set up credentials," >&2
  echo "       or check that your access key is active in the AWS Console (IAM → Users → Security credentials)." >&2
  exit 1
}
ACCOUNT_ID=$(echo "$CALLER_IDENTITY" | jq -r '.Account')
echo "  Authenticated as: $(echo "$CALLER_IDENTITY" | jq -r '.Arn')"
echo "  Account ID: ${ACCOUNT_ID}"
echo ""

# ---------------------------------------------------------------------------
# KMS key for state encryption
# ---------------------------------------------------------------------------
echo "Creating KMS key..."
if $AWS kms describe-key --key-id "${KMS_ALIAS}" &>/dev/null; then
  echo "  KMS key already exists, skipping."
  KMS_KEY_ID=$($AWS kms describe-key --key-id "${KMS_ALIAS}" --output json | jq -r '.KeyMetadata.KeyId')
else
  KMS_KEY_ID=$($AWS kms create-key \
    --description "${PROJECT_NAME} Terraform state encryption" \
    --output json | jq -r '.KeyMetadata.KeyId')
  $AWS kms create-alias \
    --alias-name "${KMS_ALIAS}" \
    --target-key-id "${KMS_KEY_ID}"
  $AWS kms enable-key-rotation --key-id "${KMS_KEY_ID}"
  echo "  Created KMS key: ${KMS_KEY_ID}"
fi
KMS_KEY_ARN=$($AWS kms describe-key --key-id "${KMS_KEY_ID}" --output json | jq -r '.KeyMetadata.Arn')
echo "  KMS key ARN: ${KMS_KEY_ARN}"
echo ""

# ---------------------------------------------------------------------------
# S3 bucket for Terraform state
# ---------------------------------------------------------------------------
echo "Creating S3 state bucket: ${BUCKET_NAME}..."
if $AWS s3api head-bucket --bucket "${BUCKET_NAME}" &>/dev/null; then
  echo "  Bucket already exists, skipping creation."
  # The bucket may have been created in a different region (e.g. us-east-1 during
  # a prior bootstrap run). Detect the actual location so backend.env is correct.
  BUCKET_REGION=$(aws --profile "${AWS_PROFILE}" s3api get-bucket-location \
    --bucket "${BUCKET_NAME}" \
    --query 'LocationConstraint' \
    --output text 2>/dev/null)
  # us-east-1 returns "None" for LocationConstraint
  if [[ "${BUCKET_REGION}" == "None" || -z "${BUCKET_REGION}" ]]; then
    BUCKET_REGION="us-east-1"
  fi
  if [[ "${BUCKET_REGION}" != "${AWS_REGION}" ]]; then
    echo "  WARNING: Bucket is in ${BUCKET_REGION}, not ${AWS_REGION}."
    echo "           Switching to ${BUCKET_REGION} for all state backend resources."
    AWS_REGION="${BUCKET_REGION}"
    AWS="aws --region ${AWS_REGION} --profile ${AWS_PROFILE}"
  fi
else
  if [[ "${AWS_REGION}" == "us-east-1" ]]; then
    $AWS s3api create-bucket --bucket "${BUCKET_NAME}"
  else
    $AWS s3api create-bucket --bucket "${BUCKET_NAME}" \
      --create-bucket-configuration LocationConstraint="${AWS_REGION}"
  fi
  echo "  Bucket created."
fi

# Versioning
$AWS s3api put-bucket-versioning \
  --bucket "${BUCKET_NAME}" \
  --versioning-configuration Status=Enabled
echo "  Versioning enabled."

# Encryption
$AWS s3api put-bucket-encryption \
  --bucket "${BUCKET_NAME}" \
  --server-side-encryption-configuration "{
    \"Rules\": [{
      \"ApplyServerSideEncryptionByDefault\": {
        \"SSEAlgorithm\": \"aws:kms\",
        \"KMSMasterKeyID\": \"${KMS_KEY_ARN}\"
      },
      \"BucketKeyEnabled\": true
    }]
  }"
echo "  Encryption enabled."

# Block all public access
$AWS s3api put-public-access-block \
  --bucket "${BUCKET_NAME}" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
echo "  Public access blocked."
echo ""

# ---------------------------------------------------------------------------
# DynamoDB table for state locking
# ---------------------------------------------------------------------------
echo "Creating DynamoDB lock table: ${DYNAMODB_TABLE}..."
if $AWS dynamodb describe-table --table-name "${DYNAMODB_TABLE}" &>/dev/null; then
  echo "  Table already exists, skipping."
else
  $AWS dynamodb create-table \
    --table-name "${DYNAMODB_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --sse-specification Enabled=true,SSEType=KMS,KMSMasterKeyId="${KMS_KEY_ARN}" \
    --output json > /dev/null
  echo "  Table created."
  echo "  Waiting for table to become active..."
  $AWS dynamodb wait table-exists --table-name "${DYNAMODB_TABLE}"
fi
echo ""

# ---------------------------------------------------------------------------
# Write backend config for up.sh to consume
# ---------------------------------------------------------------------------
BACKEND_CONFIG_FILE="${SCRIPT_DIR}/../config/backend.env"
cat > "${BACKEND_CONFIG_FILE}" <<EOF
# Auto-generated by bootstrap.sh — do not edit manually.
TF_BACKEND_BUCKET=${BUCKET_NAME}
TF_BACKEND_KEY=${PROJECT_NAME}/terraform.tfstate
TF_BACKEND_REGION=${AWS_REGION}
TF_BACKEND_DYNAMODB_TABLE=${DYNAMODB_TABLE}
TF_BACKEND_ACCOUNT_ID=${ACCOUNT_ID}
EOF
echo "Backend config written to config/backend.env"
echo ""

echo "=== Bootstrap complete ==="
echo ""
echo "Next step: run up.sh to provision your AWS environment."
