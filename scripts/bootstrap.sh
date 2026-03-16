#!/usr/bin/env bash
# bootstrap.sh — One-time setup: creates the S3 bucket, DynamoDB table, and
# KMS key used by Terraform for remote state. Run this before up.sh.
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
# Initialize user registry in S3 (if not already present)
# ---------------------------------------------------------------------------
USERS_KEY="${PROJECT_NAME}/users.json"
echo "Initializing user registry..."
if $AWS s3api head-object --bucket "${BUCKET_NAME}" --key "${USERS_KEY}" &>/dev/null; then
  echo "  User registry already exists, skipping."
else
  echo '{}' | $AWS s3 cp - "s3://${BUCKET_NAME}/${USERS_KEY}" >/dev/null
  echo "  User registry initialized (s3://${BUCKET_NAME}/${USERS_KEY})."
fi
echo ""

# ---------------------------------------------------------------------------
# SES sender verification (only if SENDER_EMAIL is configured)
# ---------------------------------------------------------------------------
if [[ -n "${SENDER_EMAIL:-}" ]]; then
  echo "Verifying SES sender: ${SENDER_EMAIL}..."
  SES_STATUS=$(aws --region "${AWS_REGION}" --profile "${AWS_PROFILE}" \
    ses get-identity-verification-attributes \
    --identities "${SENDER_EMAIL}" \
    --query "VerificationAttributes.\"${SENDER_EMAIL}\".VerificationStatus" \
    --output text 2>/dev/null || echo "")

  if [[ "${SES_STATUS}" == "Success" ]]; then
    echo "  Already verified."
  else
    aws --region "${AWS_REGION}" --profile "${AWS_PROFILE}" \
      ses verify-email-identity \
      --email-address "${SENDER_EMAIL}" >/dev/null
    echo "  Verification email sent to ${SENDER_EMAIL}."
    echo "  Click the link in that email before running add-user."
  fi
  echo ""
else
  echo "SENDER_EMAIL not set — skipping SES sender verification."
  echo "  To enable automated onboarding emails, add SENDER_EMAIL=you@example.com"
  echo "  to config/admin.env, then re-run bootstrap."
  echo ""
fi

# ---------------------------------------------------------------------------
# IAM Identity Center permission sets (only if SSO_REGION is configured)
# Creates DeveloperAccess and ProjectAdminAccess permission sets idempotently.
# ---------------------------------------------------------------------------
if [[ -n "${SSO_REGION:-}" ]]; then
  echo "Setting up IAM Identity Center permission sets (region: ${SSO_REGION})..."

  SSO_INSTANCE_ARN=$(aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
    sso-admin list-instances \
    --query 'Instances[0].InstanceArn' --output text 2>/dev/null || echo "")

  if [[ -z "${SSO_INSTANCE_ARN}" || "${SSO_INSTANCE_ARN}" == "None" ]]; then
    echo "  WARNING: No IAM Identity Center instance found in region ${SSO_REGION}."
    echo "           Verify SSO_REGION in config/admin.env and re-run bootstrap."
    echo ""
  else
    echo "  Instance: ${SSO_INSTANCE_ARN}"
    echo ""

    # Find an existing permission set ARN by name; echoes ARN or empty string.
    _find_ps_arn() {
      local target="$1"
      local found=""
      while IFS= read -r arn; do
        [[ -z "${arn}" ]] && continue
        local name
        name=$(aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
          sso-admin describe-permission-set \
          --instance-arn "${SSO_INSTANCE_ARN}" \
          --permission-set-arn "${arn}" \
          --query 'PermissionSet.Name' --output text 2>/dev/null || echo "")
        if [[ "${name}" == "${target}" ]]; then
          found="${arn}"
          break
        fi
      done < <(aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
        sso-admin list-permission-sets \
        --instance-arn "${SSO_INSTANCE_ARN}" \
        --max-results 100 \
        --query 'PermissionSets[]' --output text 2>/dev/null | tr '\t' '\n')
      echo "${found}"
    }

    # Create a permission set if it doesn't exist; echoes the ARN either way.
    _ensure_ps() {
      local name="$1" description="$2"
      local arn
      arn=$(_find_ps_arn "${name}")
      if [[ -n "${arn}" ]]; then
        echo "  '${name}': already exists." >&2
      else
        arn=$(aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
          sso-admin create-permission-set \
          --instance-arn "${SSO_INSTANCE_ARN}" \
          --name "${name}" \
          --description "${description}" \
          --session-duration "PT8H" \
          --query 'PermissionSet.PermissionSetArn' --output text)
        echo "  '${name}': created." >&2
      fi
      echo "${arn}"
    }

    # ---- DeveloperAccess ------------------------------------------------
    # Scoped policy: developer can only start/stop/connect to their own instance.
    DEV_PS_ARN=$(_ensure_ps "DeveloperAccess" \
      "Scoped ${PROJECT_NAME} user access: connect to own instance only")

    POLICY_FILE=$(mktemp)
    cat > "${POLICY_FILE}" << 'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ec2:StartInstances", "ec2:StopInstances"],
      "Resource": "*",
      "Condition": {"StringEquals": {"aws:ResourceTag/Username": "${aws:username}"}}
    },
    {
      "Effect": "Allow",
      "Action": ["ec2:DescribeInstances", "ec2:DescribeInstanceStatus"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "ssm:StartSession",
      "Resource": "*",
      "Condition": {"StringEquals": {"aws:ResourceTag/Username": "${aws:username}"}}
    },
    {
      "Effect": "Allow",
      "Action": ["ssm:TerminateSession", "ssm:ResumeSession"],
      "Resource": "arn:aws:ssm:*:*:session/${aws:username}-*"
    }
  ]
}
POLICY
    aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
      sso-admin put-inline-policy-to-permission-set \
      --instance-arn "${SSO_INSTANCE_ARN}" \
      --permission-set-arn "${DEV_PS_ARN}" \
      --inline-policy "file://${POLICY_FILE}" >/dev/null
    echo "  'DeveloperAccess': policy applied."
    rm -f "${POLICY_FILE}"

    # ---- ProjectAdminAccess ---------------------------------------------
    # PowerUserAccess (all services except IAM) plus the specific IAM
    # permissions Terraform needs to create and manage EC2 instance roles.
    ADMIN_PS_ARN=$(_ensure_ps "ProjectAdminAccess" \
      "${PROJECT_NAME} admin: run bootstrap/up/down, manage users and infrastructure")

    aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
      sso-admin attach-managed-policy-to-permission-set \
      --instance-arn "${SSO_INSTANCE_ARN}" \
      --permission-set-arn "${ADMIN_PS_ARN}" \
      --managed-policy-arn "arn:aws:iam::aws:policy/PowerUserAccess" 2>/dev/null \
      && echo "  'ProjectAdminAccess': attached PowerUserAccess." \
      || echo "  'ProjectAdminAccess': PowerUserAccess already attached."

    POLICY_FILE=$(mktemp)
    cat > "${POLICY_FILE}" << 'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformIAM",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole", "iam:DeleteRole", "iam:GetRole",
        "iam:TagRole", "iam:UntagRole", "iam:UpdateAssumeRolePolicy",
        "iam:AttachRolePolicy", "iam:DetachRolePolicy",
        "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile", "iam:TagInstanceProfile",
        "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
        "iam:PassRole",
        "iam:CreatePolicy", "iam:CreatePolicyVersion",
        "iam:DeletePolicy", "iam:DeletePolicyVersion",
        "iam:GetPolicy", "iam:GetPolicyVersion",
        "iam:ListPolicyVersions", "iam:TagPolicy",
        "iam:GetRolePolicy"
      ],
      "Resource": "*"
    }
  ]
}
POLICY
    aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
      sso-admin put-inline-policy-to-permission-set \
      --instance-arn "${SSO_INSTANCE_ARN}" \
      --permission-set-arn "${ADMIN_PS_ARN}" \
      --inline-policy "file://${POLICY_FILE}" >/dev/null
    echo "  'ProjectAdminAccess': IAM policy applied."
    rm -f "${POLICY_FILE}"

    echo ""
    echo "  Assign permission sets in IAM Identity Center → AWS accounts:"
    echo "    Admins:      ProjectAdminAccess"
    echo "    Developers:  DeveloperAccess"
    echo "  Then update sso_role_name in ~/.aws/config to match."
    echo ""
  fi
else
  echo "SSO_REGION not set — skipping IAM Identity Center permission sets."
  echo "  To automate this, add SSO_REGION=<region> to config/admin.env."
  echo ""
fi

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
echo "Next steps:"
echo "  1. Run './admin.sh add-user' to register users."
echo "  2. Run './admin.sh up' to provision AWS infrastructure."
