#!/usr/bin/env bash
# bootstrap.sh — One-time setup: creates the S3 bucket, DynamoDB table,
# user registry, SES verification, and IAM Identity Center permission sets
# used by the rest of the tooling. Safe to re-run (all steps are idempotent).
#
# Flags:
#   --plan / --dry-run   Show exactly what will be created without making changes.
#   --yes  / -y          Skip the confirmation prompt (for re-runs or automation).
#   --profile <name>     Use a named AWS CLI profile instead of the one in admin.env.
#   --profile=<name>     Same, alternative syntax.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/admin.env"

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
PLAN_ONLY=false
AUTO_APPROVE=false
for arg in "$@"; do
  case "${arg}" in
    --plan|--dry-run)      PLAN_ONLY=true ;;
    --yes|-y)              AUTO_APPROVE=true ;;
    --profile|--profile=*) ;; # handled via BOOTSTRAP_PROFILE_OVERRIDE env var
    --region|--region=*)   ;; # handled via BOOTSTRAP_REGION_OVERRIDE env var
    *) echo "ERROR: Unknown option: ${arg}" >&2; exit 1 ;;
  esac
done

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

# Apply CLI overrides (set via env vars by run.sh)
AWS_PROFILE="${AWS_PROFILE:-}"
[[ -n "${BOOTSTRAP_PROFILE_OVERRIDE:-}" ]] && AWS_PROFILE="${BOOTSTRAP_PROFILE_OVERRIDE}"
[[ -n "${BOOTSTRAP_REGION_OVERRIDE:-}" ]]  && AWS_REGION="${BOOTSTRAP_REGION_OVERRIDE}"

# ---------------------------------------------------------------------------
# Profile existence check — if the configured profile doesn't exist yet (e.g.
# before first bootstrap), fall back to default credentials and prompt the
# admin to confirm the deploy region, since their default creds may target a
# different region.
# ---------------------------------------------------------------------------
if [[ -n "${AWS_PROFILE}" ]]; then
  if ! aws configure list-profiles 2>/dev/null | grep -qx "${AWS_PROFILE}"; then
    echo "NOTE: Profile '${AWS_PROFILE}' not found in ~/.aws/config."
    echo "      Falling back to default AWS credentials for bootstrap."
    echo "      After bootstrap completes, append config/aws-config-admin.example"
    echo "      to ~/.aws/config, then re-run './admin.sh sso-login'."
    echo ""
    AWS_PROFILE=""

    # Prompt to confirm deploy region — default creds may target a different region
    _default_region=$(aws configure get region 2>/dev/null || echo "")
    if [[ "${_default_region}" != "${AWS_REGION}" ]]; then
      echo "  Default credentials region : ${_default_region:-<not set>}"
      echo "  admin.env deploy region    : ${AWS_REGION}"
      echo ""
      read -r -p "  Region to use for bootstrap [${AWS_REGION}]: " _region_input
      [[ -n "${_region_input}" ]] && AWS_REGION="${_region_input}"
      echo ""
    fi
  fi
fi

USERS_KEY="${PROJECT_NAME}/users.json"

PROFILE_ARGS=()
[[ -n "${AWS_PROFILE}" ]] && PROFILE_ARGS=(--profile "${AWS_PROFILE}")

# SSO_PROFILE_ARGS — used for all IC API calls (sso-admin, identitystore).
# In cross-account setups, IC lives in a different account and needs a separate profile.
# Defaults to AWS_PROFILE when SSO_PROFILE is not set.
_SSO_PROFILE="${SSO_PROFILE:-${AWS_PROFILE}}"
SSO_PROFILE_ARGS=()
[[ -n "${_SSO_PROFILE}" ]] && SSO_PROFILE_ARGS=(--profile "${_SSO_PROFILE}")

if [[ -n "${AWS_PROFILE}" ]]; then
  AWS="aws --region ${AWS_REGION} --profile ${AWS_PROFILE}"
else
  AWS="aws --region ${AWS_REGION}"
fi
STATE_REGION="${AWS_REGION}"   # tracks state-backend region; may diverge from AWS_REGION

echo "=== fre-aws bootstrap ==="
echo "  Project:  ${PROJECT_NAME}"
echo "  Region:   ${AWS_REGION}"
echo "  Profile:  ${AWS_PROFILE:-<default>}"
echo ""

# ---------------------------------------------------------------------------
# Verify AWS credentials
# ---------------------------------------------------------------------------
echo "Verifying AWS credentials..."
CALLER_IDENTITY=$($AWS sts get-caller-identity --output json 2>&1) || {
  if [[ -n "${AWS_PROFILE}" ]]; then
    echo "ERROR: AWS credentials not valid for profile '${AWS_PROFILE}'." >&2
    echo "       Run 'aws sso login --profile ${AWS_PROFILE}' or reconfigure credentials." >&2
  else
    echo "ERROR: No valid AWS credentials found." >&2
    echo "       Run 'aws configure' to set up default credentials." >&2
  fi
  exit 1
}
ACCOUNT_ID=$(echo "$CALLER_IDENTITY" | jq -r '.Account')
echo "  Authenticated as: $(echo "$CALLER_IDENTITY" | jq -r '.Arn')"
echo "  Account ID: ${ACCOUNT_ID}"
echo ""

BUCKET_NAME="${PROJECT_NAME}-${ACCOUNT_ID}-tfstate"
DYNAMODB_TABLE="${PROJECT_NAME}-${ACCOUNT_ID}-tflock"
echo "  Bucket:   ${BUCKET_NAME}"
echo "  DynamoDB: ${DYNAMODB_TABLE}"
echo ""

# ---------------------------------------------------------------------------
# Build policy content into variables.
# Done early so they appear in the plan display and are reused in execution
# without duplicating the policy definitions in the script.
# ---------------------------------------------------------------------------

# developer-access inline policy (uses variable substitutions for bucket/project)
DEV_POLICY=$(cat <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ec2:StartInstances", "ec2:StopInstances",
                 "ec2:DescribeInstances", "ec2:DescribeInstanceStatus"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "ssm:StartSession",
      "Resource": [
        "arn:aws:ec2:*:*:instance/*",
        "arn:aws:ssm:*::document/AWS-StartSSHSession"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["ssm:TerminateSession", "ssm:ResumeSession"],
      "Resource": "arn:aws:ssm:*:*:session/\${aws:RoleSessionName}-*"
    },
    {
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/${PROJECT_NAME}/installers/*"
    },
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:*:*:secret:${PROJECT_NAME}/*/ssh-key-passphrase-*"
    }
  ]
}
POLICY
)

# admin-access inline policy (no variable substitutions)
ADMIN_POLICY=$(cat <<'POLICY'
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
        "iam:GetRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SSOAccountAssignment",
      "Effect": "Allow",
      "Action": [
        "iam:GetSAMLProvider",
        "iam:ListSAMLProviders"
      ],
      "Resource": "*"
    }
  ]
}
POLICY
)

# ---------------------------------------------------------------------------
# Helper: find a permission set ARN by name.
# Defined before pre-flight checks so it can be called in both phases.
# $SSO_INSTANCE_ARN and $SSO_REGION must be set before calling.
# ---------------------------------------------------------------------------
_find_ps_arn() {
  local target="$1"
  local found=""
  while IFS= read -r arn; do
    [[ -z "${arn}" ]] && continue
    local name
    name=$(aws --region "${SSO_REGION}" "${SSO_PROFILE_ARGS[@]}" \
      sso-admin describe-permission-set \
      --instance-arn "${SSO_INSTANCE_ARN}" \
      --permission-set-arn "${arn}" \
      --query 'PermissionSet.Name' --output text 2>/dev/null || echo "")
    if [[ "${name}" == "${target}" ]]; then
      found="${arn}"
      break
    fi
  done < <(aws --region "${SSO_REGION}" "${SSO_PROFILE_ARGS[@]}" \
    sso-admin list-permission-sets \
    --instance-arn "${SSO_INSTANCE_ARN}" \
    --max-results 100 \
    --query 'PermissionSets[]' --output text 2>/dev/null | tr '\t' '\n')
  echo "${found}"
}

# ---------------------------------------------------------------------------
# Pre-flight checks — query existence of every resource bootstrap touches.
# Results are cached in flag variables and reused during execution so we
# never make the same AWS API call twice.
# ---------------------------------------------------------------------------
echo "--- checking existing resources ---"

# S3 bucket (also detects actual bucket region, which may differ from AWS_REGION)
S3_BUCKET_EXISTS=false
if $AWS s3api head-bucket --bucket "${BUCKET_NAME}" &>/dev/null; then
  S3_BUCKET_EXISTS=true
  BUCKET_REGION=$(aws "${PROFILE_ARGS[@]}" s3api get-bucket-location \
    --bucket "${BUCKET_NAME}" \
    --query 'LocationConstraint' \
    --output text 2>/dev/null)
  [[ "${BUCKET_REGION}" == "None" || -z "${BUCKET_REGION}" ]] && BUCKET_REGION="us-east-1"
  if [[ "${BUCKET_REGION}" != "${STATE_REGION}" ]]; then
    STATE_REGION="${BUCKET_REGION}"
    if [[ -n "${AWS_PROFILE}" ]]; then
      AWS="aws --region ${STATE_REGION} --profile ${AWS_PROFILE}"
    else
      AWS="aws --region ${STATE_REGION}"
    fi
  fi
fi

# DynamoDB lock table
DDB_EXISTS=false
$AWS dynamodb describe-table --table-name "${DYNAMODB_TABLE}" &>/dev/null \
  && DDB_EXISTS=true || true

# S3 user registry (can only exist if the bucket already exists)
REGISTRY_EXISTS=false
if [[ "${S3_BUCKET_EXISTS}" == true ]]; then
  $AWS s3api head-object --bucket "${BUCKET_NAME}" --key "${USERS_KEY}" &>/dev/null \
    && REGISTRY_EXISTS=true || true
fi

# SES sender verification
SES_VERIFIED=false
if [[ -n "${SENDER_EMAIL:-}" ]]; then
  SES_STATUS=$(aws --region "${AWS_REGION}" "${PROFILE_ARGS[@]}" \
    ses get-identity-verification-attributes \
    --identities "${SENDER_EMAIL}" \
    --query "VerificationAttributes.\"${SENDER_EMAIL}\".VerificationStatus" \
    --output text 2>/dev/null || echo "")
  [[ "${SES_STATUS}" == "Success" ]] && SES_VERIFIED=true
fi

# IAM Identity Center permission sets
# In external mode, IC is managed entirely by the org — bootstrap skips all IC operations.
SSO_INSTANCE_ARN=""
IDENTITY_STORE_ID=""
DEV_PS_ARN=""
ADMIN_PS_ARN=""
if [[ "${IDENTITY_MODE:-managed}" != "external" && -n "${SSO_REGION:-}" ]]; then
  SSO_INSTANCE_ARN=$(aws --region "${SSO_REGION}" "${SSO_PROFILE_ARGS[@]}" \
    sso-admin list-instances \
    --query 'Instances[0].InstanceArn' --output text 2>/dev/null || echo "")
  [[ "${SSO_INSTANCE_ARN}" == "None" ]] && SSO_INSTANCE_ARN=""
  IDENTITY_STORE_ID=$(aws --region "${SSO_REGION}" "${SSO_PROFILE_ARGS[@]}" \
    sso-admin list-instances \
    --query 'Instances[0].IdentityStoreId' --output text 2>/dev/null || echo "")
  [[ "${IDENTITY_STORE_ID}" == "None" ]] && IDENTITY_STORE_ID=""

  if [[ -n "${SSO_INSTANCE_ARN}" ]]; then
    DEV_PS_ARN=$(_find_ps_arn "${PROJECT_NAME}-developer-access")
    ADMIN_PS_ARN=$(_find_ps_arn "${PROJECT_NAME}-admin-access")
  fi
fi
echo ""

# ---------------------------------------------------------------------------
# Print plan
# ---------------------------------------------------------------------------
echo "=== bootstrap plan ==="
echo ""
printf "  %-12s %s\n" "Account:"  "${ACCOUNT_ID}  ($(echo "${CALLER_IDENTITY}" | jq -r '.Arn'))"
printf "  %-12s %s\n" "Project:"  "${PROJECT_NAME}"
printf "  %-12s %s\n" "Region:"   "${AWS_REGION}"
echo ""

echo "  Infrastructure"
echo "  ──────────────────────────────────────────────────────────────────"
if [[ "${S3_BUCKET_EXISTS}" == false ]]; then
  printf "  %-24s %-36s %s\n" "S3 state bucket"     "${BUCKET_NAME}"                "CREATE"
else
  printf "  %-24s %-36s %s\n" "S3 state bucket"     "${BUCKET_NAME}"                "exists  (versioning/encryption/tags will be refreshed)"
fi
if [[ "${DDB_EXISTS}" == false ]]; then
  printf "  %-24s %-36s %s\n" "DynamoDB lock table" "${DYNAMODB_TABLE}"             "CREATE"
else
  printf "  %-24s %-36s %s\n" "DynamoDB lock table" "${DYNAMODB_TABLE}"             "exists  (tags will be refreshed)"
fi
if [[ "${REGISTRY_EXISTS}" == false ]]; then
  printf "  %-24s %-36s %s\n" "S3 user registry"   "${PROJECT_NAME}/users.json"    "CREATE"
else
  printf "  %-24s %-36s %s\n" "S3 user registry"   "${PROJECT_NAME}/users.json"    "exists  (no changes)"
fi
if [[ -n "${SENDER_EMAIL:-}" ]]; then
  if [[ "${SES_VERIFIED}" == true ]]; then
    printf "  %-24s %-36s %s\n" "SES sender"        "${SENDER_EMAIL}"               "exists  (already verified)"
  else
    printf "  %-24s %-36s %s\n" "SES sender"        "${SENDER_EMAIL}"               "VERIFY  (verification email will be sent)"
  fi
else
  printf "  %-24s %-36s %s\n" "SES sender"          "(not configured)"              "SKIP"
  echo "    (set SENDER_EMAIL in admin.env to enable automated onboarding emails)"
fi

echo ""
if [[ "${IDENTITY_MODE:-managed}" == "external" ]]; then
  echo "  IAM Identity Center  (external mode — org-managed, no changes)"
elif [[ -n "${SSO_REGION:-}" ]]; then
  if [[ "${_SSO_PROFILE:-}" != "${AWS_PROFILE:-}" && -n "${_SSO_PROFILE:-}" ]]; then
    echo "  IAM Identity Center  (region: ${SSO_REGION}, SSO profile: ${_SSO_PROFILE})"
  else
    echo "  IAM Identity Center  (region: ${SSO_REGION})"
  fi
else
  echo "  IAM Identity Center  (SSO_REGION not set in admin.env — permission sets will be skipped)"
fi
echo "  ──────────────────────────────────────────────────────────────────"

if [[ "${IDENTITY_MODE:-managed}" == "external" ]]; then
  printf "  %-55s %s\n" "Permission sets" "SKIP  (IDENTITY_MODE=external)"
  echo "    Users authenticate via their existing org IC roles — no fre-aws permission sets needed."
elif [[ -n "${SSO_REGION:-}" && -z "${SSO_INSTANCE_ARN}" ]]; then
  echo "  WARNING: No Identity Center instance found in region ${SSO_REGION} — permission sets will be skipped."
else
  if [[ -z "${SSO_REGION:-}" ]]; then
    _dev_ps_status="SKIP    (set SSO_REGION in admin.env to enable)"
    _admin_ps_status="SKIP    (set SSO_REGION in admin.env to enable)"
  else
    [[ -z "${DEV_PS_ARN}" ]]   && _dev_ps_status="CREATE"   || _dev_ps_status="exists  (inline policy will be updated)"
    [[ -z "${ADMIN_PS_ARN}" ]] && _admin_ps_status="CREATE" || _admin_ps_status="exists  (inline policy will be updated)"
  fi

  printf "  %-55s %s\n" "${PROJECT_NAME}-developer-access" "${_dev_ps_status}"
  echo "    Grants users access to connect to their own EC2 instance:"
  echo "    • ec2: StartInstances, StopInstances, DescribeInstances, DescribeInstanceStatus  → *"
  echo "    • ssm: StartSession  → EC2 instances + AWS-StartSSHSession document"
  echo "    • ssm: TerminateSession, ResumeSession  → own sessions only"
  echo "    • s3: GetObject  → s3://${BUCKET_NAME}/${PROJECT_NAME}/installers/*"
  echo "    • secretsmanager: GetSecretValue  → ${PROJECT_NAME}/*/ssh-key-passphrase-*"
  echo ""
  printf "  %-55s %s\n" "${PROJECT_NAME}-admin-access" "${_admin_ps_status}"
  echo "    Grants admins access to manage the full environment:"
  echo "    • PowerUserAccess (AWS managed — all services except IAM)"
  echo "    • TerraformIAM (inline — specific IAM actions Terraform needs to manage EC2 roles):"
  echo "        iam: CreateRole, DeleteRole, GetRole, TagRole, UntagRole,"
  echo "             UpdateAssumeRolePolicy, AttachRolePolicy, DetachRolePolicy,"
  echo "             ListRolePolicies, ListAttachedRolePolicies, ListInstanceProfilesForRole,"
  echo "             CreateInstanceProfile, DeleteInstanceProfile, GetInstanceProfile,"
  echo "             TagInstanceProfile, AddRoleToInstanceProfile, RemoveRoleFromInstanceProfile,"
  echo "             PassRole, CreatePolicy, CreatePolicyVersion, DeletePolicy, DeletePolicyVersion,"
  echo "             GetPolicy, GetPolicyVersion, ListPolicyVersions, TagPolicy,"
  echo "             GetRolePolicy, PutRolePolicy, DeleteRolePolicy  → *"
  echo "        iam: GetSAMLProvider, ListSAMLProviders  → *"
  if [[ -n "${SSO_REGION:-}" ]]; then
    echo ""
    echo "  Both permission sets:"
    echo "  • Provisioned to account ${ACCOUNT_ID}"
    if [[ -n "${OWNER_EMAIL:-}" ]]; then
      echo "  • Assigned to: ${OWNER_EMAIL}"
    else
      echo "  • (OWNER_EMAIL not set — assign to yourself manually in IAM Identity Center after bootstrap)"
    fi
  fi
fi
echo ""

# ---------------------------------------------------------------------------
# Gate: plan-only exit / confirmation prompt / auto-approve
# ---------------------------------------------------------------------------
if [[ "${PLAN_ONLY}" == true ]]; then
  echo "(--plan: no changes made)"
  exit 0
fi

if [[ "${AUTO_APPROVE}" == false ]]; then
  read -r -p "Apply? [y/N] " CONFIRM
  if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi
echo ""

# ---------------------------------------------------------------------------
# S3 bucket — create or confirm, then configure
# ---------------------------------------------------------------------------
echo "S3 state bucket: ${BUCKET_NAME}..."
if [[ "${S3_BUCKET_EXISTS}" == false ]]; then
  if [[ "${STATE_REGION}" == "us-east-1" ]]; then
    $AWS s3api create-bucket --bucket "${BUCKET_NAME}"
  else
    $AWS s3api create-bucket --bucket "${BUCKET_NAME}" \
      --create-bucket-configuration LocationConstraint="${STATE_REGION}"
  fi
  echo "  Bucket created."
else
  echo "  Bucket already exists."
  if [[ "${STATE_REGION}" != "${AWS_REGION}" ]]; then
    echo "  NOTE: Bucket is in ${STATE_REGION} (not ${AWS_REGION}) — using that region for state backend."
  fi
fi

# Configure (idempotent — always run to ensure settings are current)
$AWS s3api put-bucket-versioning \
  --bucket "${BUCKET_NAME}" \
  --versioning-configuration Status=Enabled
echo "  Versioning enabled."

$AWS s3api put-bucket-encryption \
  --bucket "${BUCKET_NAME}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'
echo "  Encryption enabled."

$AWS s3api put-public-access-block \
  --bucket "${BUCKET_NAME}" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
echo "  Public access blocked."

$AWS s3api put-bucket-tagging \
  --bucket "${BUCKET_NAME}" \
  --tagging "TagSet=[{Key=ProjectName,Value=${PROJECT_NAME}},{Key=ManagedBy,Value=fre-aws}]"
echo "  Tags applied."
echo ""

# ---------------------------------------------------------------------------
# DynamoDB table for state locking
# ---------------------------------------------------------------------------
echo "DynamoDB lock table: ${DYNAMODB_TABLE}..."
if [[ "${DDB_EXISTS}" == false ]]; then
  $AWS dynamodb create-table \
    --table-name "${DYNAMODB_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --output json > /dev/null
  echo "  Table created."
  echo "  Waiting for table to become active..."
  $AWS dynamodb wait table-exists --table-name "${DYNAMODB_TABLE}"
else
  echo "  Table already exists."
fi

TABLE_ARN=$($AWS dynamodb describe-table --table-name "${DYNAMODB_TABLE}" --query 'Table.TableArn' --output text 2>/dev/null || echo "")
if [[ -n "${TABLE_ARN}" ]]; then
  $AWS dynamodb tag-resource --resource-arn "${TABLE_ARN}" --tags "Key=ProjectName,Value=${PROJECT_NAME}" "Key=ManagedBy,Value=fre-aws"
  echo "  Tags applied."
fi
echo ""

# ---------------------------------------------------------------------------
# S3 user registry
# ---------------------------------------------------------------------------
echo "User registry..."
if [[ "${REGISTRY_EXISTS}" == false ]]; then
  echo '{}' | $AWS s3 cp - "s3://${BUCKET_NAME}/${USERS_KEY}" >/dev/null
  echo "  User registry initialized (s3://${BUCKET_NAME}/${USERS_KEY})."
else
  echo "  User registry already exists, skipping."
fi
echo ""

# ---------------------------------------------------------------------------
# SES sender verification (only if SENDER_EMAIL is configured)
# ---------------------------------------------------------------------------
if [[ -n "${SENDER_EMAIL:-}" ]]; then
  echo "SES sender: ${SENDER_EMAIL}..."
  if [[ "${SES_VERIFIED}" == false ]]; then
    aws --region "${AWS_REGION}" "${PROFILE_ARGS[@]}" \
      ses verify-email-identity \
      --email-address "${SENDER_EMAIL}" >/dev/null
    echo "  Verification email sent to ${SENDER_EMAIL}."
    echo "  Click the link in that email before running add-user."
  else
    echo "  Already verified."
  fi
  echo ""
else
  echo "SENDER_EMAIL not set — skipping SES sender verification."
  echo "  To enable automated onboarding emails, add SENDER_EMAIL=you@example.com"
  echo "  to config/admin.env, then re-run bootstrap."
  echo ""
fi

# ---------------------------------------------------------------------------
# IAM Identity Center permission sets (managed mode only, only if SSO_REGION is configured)
# External mode: org manages IC entirely; bootstrap makes no IC API calls.
# ---------------------------------------------------------------------------
if [[ "${IDENTITY_MODE:-managed}" == "external" ]]; then
  echo "IDENTITY_MODE=external — skipping IAM Identity Center (using org-managed roles)."
  echo ""
elif [[ -n "${SSO_REGION:-}" ]]; then
  echo "IAM Identity Center permission sets (region: ${SSO_REGION})..."

  if [[ -z "${SSO_INSTANCE_ARN}" ]]; then
    echo "  WARNING: No IAM Identity Center instance found in region ${SSO_REGION}."
    echo "           Verify SSO_REGION in config/admin.env and re-run bootstrap."
    echo ""
  else
    echo "  Instance: ${SSO_INSTANCE_ARN}"
    echo ""

    # ---- ${PROJECT_NAME}-developer-access ----------------------------------------
    if [[ -z "${DEV_PS_ARN}" ]]; then
      DEV_PS_ARN=$(aws --region "${SSO_REGION}" "${SSO_PROFILE_ARGS[@]}" \
        sso-admin create-permission-set \
        --instance-arn "${SSO_INSTANCE_ARN}" \
        --name "${PROJECT_NAME}-developer-access" \
        --description "Scoped ${PROJECT_NAME} user access: connect to own instance only" \
        --session-duration "PT8H" \
        --query 'PermissionSet.PermissionSetArn' --output text)
      echo "  '${PROJECT_NAME}-developer-access': created."
    else
      echo "  '${PROJECT_NAME}-developer-access': already exists."
    fi

    POLICY_FILE=$(mktemp)
    echo "${DEV_POLICY}" > "${POLICY_FILE}"
    aws --region "${SSO_REGION}" "${SSO_PROFILE_ARGS[@]}" \
      sso-admin put-inline-policy-to-permission-set \
      --instance-arn "${SSO_INSTANCE_ARN}" \
      --permission-set-arn "${DEV_PS_ARN}" \
      --inline-policy "file://${POLICY_FILE}" >/dev/null
    echo "  '${PROJECT_NAME}-developer-access': policy applied."
    rm -f "${POLICY_FILE}"

    # ---- ${PROJECT_NAME}-admin-access --------------------------------------------
    if [[ -z "${ADMIN_PS_ARN}" ]]; then
      ADMIN_PS_ARN=$(aws --region "${SSO_REGION}" "${SSO_PROFILE_ARGS[@]}" \
        sso-admin create-permission-set \
        --instance-arn "${SSO_INSTANCE_ARN}" \
        --name "${PROJECT_NAME}-admin-access" \
        --description "${PROJECT_NAME} admin: run bootstrap/up/down, manage users and infrastructure" \
        --session-duration "PT8H" \
        --query 'PermissionSet.PermissionSetArn' --output text)
      echo "  '${PROJECT_NAME}-admin-access': created."
    else
      echo "  '${PROJECT_NAME}-admin-access': already exists."
    fi

    aws --region "${SSO_REGION}" "${SSO_PROFILE_ARGS[@]}" \
      sso-admin attach-managed-policy-to-permission-set \
      --instance-arn "${SSO_INSTANCE_ARN}" \
      --permission-set-arn "${ADMIN_PS_ARN}" \
      --managed-policy-arn "arn:aws:iam::aws:policy/PowerUserAccess" 2>/dev/null \
      && echo "  '${PROJECT_NAME}-admin-access': attached PowerUserAccess." \
      || echo "  '${PROJECT_NAME}-admin-access': PowerUserAccess already attached."

    POLICY_FILE=$(mktemp)
    echo "${ADMIN_POLICY}" > "${POLICY_FILE}"
    aws --region "${SSO_REGION}" "${SSO_PROFILE_ARGS[@]}" \
      sso-admin put-inline-policy-to-permission-set \
      --instance-arn "${SSO_INSTANCE_ARN}" \
      --permission-set-arn "${ADMIN_PS_ARN}" \
      --inline-policy "file://${POLICY_FILE}" >/dev/null
    echo "  '${PROJECT_NAME}-admin-access': IAM policy applied."
    rm -f "${POLICY_FILE}"

    # ---- Provision both permission sets to the account --------------------------
    # Without this step the role never appears in the account and SSO logins
    # fail with "No access" even after a user assignment is created.
    _provision_ps() {
      local ps_name="$1" ps_arn="$2"
      echo "  Provisioning '${ps_name}' to account ${ACCOUNT_ID}..."

      local provision_out
      provision_out=$(aws --region "${SSO_REGION}" "${SSO_PROFILE_ARGS[@]}" \
        sso-admin provision-permission-set \
        --instance-arn "${SSO_INSTANCE_ARN}" \
        --permission-set-arn "${ps_arn}" \
        --target-id "${ACCOUNT_ID}" \
        --target-type AWS_ACCOUNT \
        --output json 2>&1) || true

      local request_id
      request_id=$(echo "${provision_out}" | jq -r '.PermissionSetProvisioningStatus.RequestId // empty' 2>/dev/null || echo "")
      if [[ -z "${request_id}" ]]; then
        echo "    WARNING: Could not start provisioning." >&2
        echo "    Response: ${provision_out}" >&2
        return
      fi

      local status result_json reason=""
      for _ in $(seq 1 20); do
        result_json=$(aws --region "${SSO_REGION}" "${SSO_PROFILE_ARGS[@]}" \
          sso-admin describe-permission-set-provisioning-status \
          --instance-arn "${SSO_INSTANCE_ARN}" \
          --provision-permission-set-request-id "${request_id}" \
          --output json 2>/dev/null || echo "{}")
        status=$(echo "${result_json}" | jq -r '.PermissionSetProvisioningStatus.Status // empty')
        [[ "${status}" == "SUCCEEDED" ]] && { echo "    OK."; return; }
        if [[ "${status}" == "FAILED" ]]; then
          reason=$(echo "${result_json}" | jq -r '.PermissionSetProvisioningStatus.FailureReason // "no reason provided"')
          echo "    FAILED: ${reason}" >&2
          return
        fi
        sleep 3
      done
      echo "    WARNING: Timed out waiting for provisioning (last status: ${status:-unknown})." >&2
    }

    echo ""
    _provision_ps "${PROJECT_NAME}-developer-access" "${DEV_PS_ARN}"
    _provision_ps "${PROJECT_NAME}-admin-access"     "${ADMIN_PS_ARN}"

    # ---- Assign permission sets to OWNER_EMAIL if provided ----------------------
    echo ""
    if [[ -n "${OWNER_EMAIL:-}" && -n "${IDENTITY_STORE_ID}" ]]; then
      ADMIN_USER_ID=$(aws --region "${SSO_REGION}" "${SSO_PROFILE_ARGS[@]}" \
        identitystore list-users \
        --identity-store-id "${IDENTITY_STORE_ID}" \
        --filters "AttributePath=Emails.Value,AttributeValue=${OWNER_EMAIL}" \
        --query 'Users[0].UserId' --output text 2>/dev/null || echo "")

      if [[ -n "${ADMIN_USER_ID}" && "${ADMIN_USER_ID}" != "None" ]]; then
        aws --region "${SSO_REGION}" "${SSO_PROFILE_ARGS[@]}" \
          sso-admin create-account-assignment \
          --instance-arn "${SSO_INSTANCE_ARN}" \
          --target-id "${ACCOUNT_ID}" \
          --target-type AWS_ACCOUNT \
          --permission-set-arn "${ADMIN_PS_ARN}" \
          --principal-type USER \
          --principal-id "${ADMIN_USER_ID}" >/dev/null 2>/dev/null \
          && echo "  Assigned ${PROJECT_NAME}-admin-access to ${OWNER_EMAIL}." \
          || echo "  ${PROJECT_NAME}-admin-access already assigned to ${OWNER_EMAIL}."
        aws --region "${SSO_REGION}" "${SSO_PROFILE_ARGS[@]}" \
          sso-admin create-account-assignment \
          --instance-arn "${SSO_INSTANCE_ARN}" \
          --target-id "${ACCOUNT_ID}" \
          --target-type AWS_ACCOUNT \
          --permission-set-arn "${DEV_PS_ARN}" \
          --principal-type USER \
          --principal-id "${ADMIN_USER_ID}" >/dev/null 2>/dev/null \
          && echo "  Assigned ${PROJECT_NAME}-developer-access to ${OWNER_EMAIL}." \
          || echo "  ${PROJECT_NAME}-developer-access already assigned to ${OWNER_EMAIL}."
        echo "  Add both profiles to ~/.aws/config (see aws-config-sso.example), then re-run sso-login."
      else
        echo "  Could not find Identity Center user with email '${OWNER_EMAIL}'."
        echo "  Assign ${PROJECT_NAME}-admin-access manually: IAM Identity Center → AWS accounts."
      fi
    else
      echo "  Assign permission sets in IAM Identity Center → AWS accounts:"
      echo "    Admins:      ${PROJECT_NAME}-admin-access"
      echo "    Developers:  ${PROJECT_NAME}-developer-access"
      echo "  Then update sso_role_name in ~/.aws/config to match."
    fi
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
TF_BACKEND_REGION=${STATE_REGION}
TF_BACKEND_DYNAMODB_TABLE=${DYNAMODB_TABLE}
TF_BACKEND_ACCOUNT_ID=${ACCOUNT_ID}
EOF
echo "Backend config written to config/backend.env"
echo ""

# ---------------------------------------------------------------------------
# Write admin AWS profile config (managed mode + SSO configured only)
# In external mode, admins use their existing org IC profiles — no generated config needed.
# ---------------------------------------------------------------------------
if [[ "${IDENTITY_MODE:-managed}" != "external" && -n "${SSO_REGION:-}" ]]; then
  AWS_CONFIG_FILE="${SCRIPT_DIR}/../config/aws-config-admin.example"
  SSO_URL="${SSO_START_URL:-<your-sso-start-url — find it in IAM Identity Center → Dashboard>}"
  cat > "${AWS_CONFIG_FILE}" <<EOF
# Generated by bootstrap.sh — append to ~/.aws/config, then re-run sso-login.
# This file is gitignored; regenerate anytime by re-running './admin.sh bootstrap'.

# Admin profile — used by admin.sh for all management operations (${PROJECT_NAME}-admin-access)
[profile claude-code]
sso_session = ${PROJECT_NAME}-admin
sso_account_id = ${ACCOUNT_ID}
sso_role_name = ${PROJECT_NAME}-admin-access
region = ${AWS_REGION}

# Developer profile — used by admin.sh connect / user.sh connect (${PROJECT_NAME}-developer-access)
[profile claude-code-dev]
sso_session = ${PROJECT_NAME}-dev
sso_account_id = ${ACCOUNT_ID}
sso_role_name = ${PROJECT_NAME}-developer-access
region = ${AWS_REGION}

[sso-session ${PROJECT_NAME}-admin]
sso_start_url = ${SSO_URL}
sso_region = ${SSO_REGION}
sso_registration_scopes = sso:account:access

[sso-session ${PROJECT_NAME}-dev]
sso_start_url = ${SSO_URL}
sso_region = ${SSO_REGION}
sso_registration_scopes = sso:account:access
EOF
  echo "Admin AWS profile config written to: config/aws-config-admin.example"
  echo ""
fi

echo "=== Bootstrap complete ==="
echo ""

if [[ "${IDENTITY_MODE:-managed}" == "external" ]]; then
  echo "Next steps:"
  echo ""
  echo "  1. Ensure AWS_PROFILE in config/admin.env points to your existing org IC profile."
  echo "  2. Run './admin.sh add-user <username>' to register users."
  echo "  3. Run './admin.sh up <username>' to provision EC2 instances."
  echo ""
  echo "  Note: users connect using their existing org IC credentials."
  echo "  If SSM access fails, ask IT to verify ssm:StartSession is in the developer permission set."
elif [[ -n "${SSO_REGION:-}" ]]; then
  echo "Next steps:"
  echo ""
  echo "  1. Append config/aws-config-admin.example to ~/.aws/config"
  echo "     (or update your existing claude-code profile to match)"
  echo "  2. Ensure AWS_PROFILE=claude-code is set in config/admin.env"
  echo "  3. Run './admin.sh sso-login' to authenticate with the new profiles"
  echo "  4. Run './admin.sh add-user' to register yourself and other users"
  echo "  5. Run './admin.sh up' to provision AWS infrastructure"
else
  echo "Next steps:"
  echo "  1. Run './admin.sh add-user' to register users."
  echo "  2. Run './admin.sh up' to provision AWS infrastructure."
fi
