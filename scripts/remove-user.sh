#!/usr/bin/env bash
# remove-user.sh — Remove a user from the fre-aws environment.
# Destroys the user's EC2 instance via down.sh, then removes them from the
# S3 registry and cleans up IAM Identity Center and Secrets Manager entries.
# Requires DEV_USERNAME env var (set by admin.sh).
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

: "${PROJECT_NAME:?}" "${AWS_PROFILE:?}" "${TF_BACKEND_BUCKET:?}" "${TF_BACKEND_REGION:?}"
: "${DEV_USERNAME:?DEV_USERNAME must be set (pass via admin.sh remove-user <username>)}"

echo "=== Remove User: ${DEV_USERNAME} ==="
echo ""

# ---------------------------------------------------------------------------
# Download current registry
# ---------------------------------------------------------------------------
USERS_JSON=$(mktemp)
trap 'rm -f "${USERS_JSON}" "${USERS_JSON}.tmp"' EXIT

users_s3_download "${USERS_JSON}"

# ---------------------------------------------------------------------------
# Check user exists
# ---------------------------------------------------------------------------
if ! jq -e --arg user "${DEV_USERNAME}" '.[$user] != null' "${USERS_JSON}" >/dev/null 2>&1; then
  echo "ERROR: User '${DEV_USERNAME}' not found in registry." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Warn and confirm
# ---------------------------------------------------------------------------
echo "WARNING: This will PERMANENTLY DESTROY '${DEV_USERNAME}'s EC2 instance"
echo "         and EBS volume, then remove them from the user registry."
echo "         This cannot be undone."
echo ""
read -r -p "Type '${DEV_USERNAME}' to confirm: " CONFIRM

if [[ "${CONFIRM}" != "${DEV_USERNAME}" ]]; then
  echo "Confirmation did not match. Aborted."
  exit 0
fi

# ---------------------------------------------------------------------------
# Destroy EC2 infrastructure before removing from registry
# (down.sh reads user config from the registry, so the entry must still exist)
# ---------------------------------------------------------------------------
echo ""
SKIP_DOWN_CONFIRM=true bash "${SCRIPT_DIR}/down.sh" "${DEV_USERNAME}"

# ---------------------------------------------------------------------------
# Remove entry and upload
# ---------------------------------------------------------------------------
jq --arg user "${DEV_USERNAME}" 'del(.[$user])' "${USERS_JSON}" > "${USERS_JSON}.tmp"
mv "${USERS_JSON}.tmp" "${USERS_JSON}"

users_s3_upload "${USERS_JSON}"

echo ""
echo "User '${DEV_USERNAME}' removed from registry."

# ---------------------------------------------------------------------------
# IAM Identity Center: remove account assignment and delete user
# ---------------------------------------------------------------------------
if [[ "${KEEP_SSO_USER:-}" == "true" ]]; then
  echo ""
  echo "IAM Identity Center user '${DEV_USERNAME}' preserved (--keep-sso)."
  echo "  Re-adding this username will reuse the existing Identity Center account."
elif [[ "${IDENTITY_MODE:-managed}" == "external" ]]; then
  echo ""
  echo "IDENTITY_MODE=external — skipping IAM Identity Center cleanup."
elif [[ -z "${SSO_REGION:-}" ]]; then
  echo ""
  echo "SSO_REGION not set — skipping IAM Identity Center cleanup."
  echo "  Delete the user manually in the IAM Identity Center console if needed."
else
  echo ""
  echo "Cleaning up IAM Identity Center..."

  SSO_INSTANCE_ARN=$(aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
    sso-admin list-instances \
    --query 'Instances[0].InstanceArn' --output text 2>/dev/null || echo "")

  IDENTITY_STORE_ID=$(aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
    sso-admin list-instances \
    --query 'Instances[0].IdentityStoreId' --output text 2>/dev/null || echo "")

  if [[ -z "${SSO_INSTANCE_ARN}" || "${SSO_INSTANCE_ARN}" == "None" ]]; then
    echo "  WARNING: No IAM Identity Center instance found in region ${SSO_REGION}. Skipping."
  else
    SSO_USER_ID=$(aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
      identitystore list-users \
      --identity-store-id "${IDENTITY_STORE_ID}" \
      --filters "AttributePath=UserName,AttributeValue=${DEV_USERNAME}" \
      --query 'Users[0].UserId' --output text 2>/dev/null || echo "")

    if [[ -z "${SSO_USER_ID}" || "${SSO_USER_ID}" == "None" ]]; then
      echo "  User '${DEV_USERNAME}' not found in Identity Center — nothing to remove."
    else
      # Remove all account assignments for this user
      ASSIGNMENTS=$(aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
        sso-admin list-account-assignments-for-principal \
        --instance-arn "${SSO_INSTANCE_ARN}" \
        --principal-id "${SSO_USER_ID}" \
        --principal-type USER \
        --query 'AccountAssignments[].{account:AccountId,ps:PermissionSetArn}' \
        --output json 2>/dev/null || echo "[]")

      ASSIGNMENT_COUNT=$(echo "${ASSIGNMENTS}" | jq 'length')
      if [[ "${ASSIGNMENT_COUNT}" -gt 0 ]]; then
        while IFS= read -r assignment; do
          ACCT=$(echo "${assignment}" | jq -r '.account')
          PS_ARN=$(echo "${assignment}" | jq -r '.ps')
          aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
            sso-admin delete-account-assignment \
            --instance-arn "${SSO_INSTANCE_ARN}" \
            --target-id "${ACCT}" \
            --target-type AWS_ACCOUNT \
            --permission-set-arn "${PS_ARN}" \
            --principal-type USER \
            --principal-id "${SSO_USER_ID}" >/dev/null
          echo "  Removed account assignment (account: ${ACCT})."
        done < <(echo "${ASSIGNMENTS}" | jq -c '.[]')
      fi

      # Delete the identity store user
      aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
        identitystore delete-user \
        --identity-store-id "${IDENTITY_STORE_ID}" \
        --user-id "${SSO_USER_ID}"
      echo "  Deleted Identity Center user '${DEV_USERNAME}' (id: ${SSO_USER_ID})."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Delete SSH key passphrase from Secrets Manager (if it exists)
# ---------------------------------------------------------------------------
if [[ -n "${AWS_REGION:-}" ]]; then
  echo ""
  echo "Cleaning up Secrets Manager..."
  SECRET_ID="${PROJECT_NAME}/${DEV_USERNAME}/ssh-key-passphrase"
  if aws --region "${AWS_REGION}" --profile "${AWS_PROFILE}" \
      secretsmanager describe-secret --secret-id "${SECRET_ID}" >/dev/null 2>&1; then
    aws --region "${AWS_REGION}" --profile "${AWS_PROFILE}" \
      secretsmanager delete-secret \
      --secret-id "${SECRET_ID}" \
      --force-delete-without-recovery >/dev/null
    echo "  Deleted SSH key passphrase: ${SECRET_ID}"
  else
    echo "  No SSH key passphrase secret found (skipping)."
  fi
fi

echo ""
echo "User '${DEV_USERNAME}' fully removed."
