#!/usr/bin/env bash
# add-user.sh — Interactive wizard to add a user to the fre-aws environment.
# Collects username, full name, email, role, SSH key, git name, and git email.
# Creates an IAM Identity Center user, generates user credentials, saves an
# onboarding bundle to config/onboarding/<username>/, and emails it via SES.
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
: "${AWS_REGION:?AWS_REGION must be set in config/admin.env}"

# ---------------------------------------------------------------------------
# Prerequisite checks — fail fast with clear messages
# ---------------------------------------------------------------------------
: "${SSO_REGION:?SSO_REGION must be set in config/admin.env (IAM Identity Center region)}"
: "${SSO_START_URL:?SSO_START_URL must be set in config/admin.env (IAM Identity Center portal URL)}"
: "${SENDER_EMAIL:?SENDER_EMAIL must be set in config/admin.env (verified SES sender address)}"

echo "=== Add User ==="
echo ""

# ---------------------------------------------------------------------------
# Optional: load user details from a file (skips interactive prompts)
# Usage: add-user.sh /path/to/file.env
# Recognised variables: NEW_USERNAME, FULL_NAME, USER_EMAIL,
#   ROLE (user|admin, default: user), SSH_PUBLIC_KEY (auto-generated if omitted),
#   GIT_USER_NAME (default: FULL_NAME), GIT_USER_EMAIL (default: USER_EMAIL)
# ---------------------------------------------------------------------------
USER_FILE="${1:-}"
if [[ -n "${USER_FILE}" ]]; then
  if [[ ! -f "${USER_FILE}" ]]; then
    echo "ERROR: User file not found: ${USER_FILE}" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${USER_FILE}"
  echo "Loading user details from: ${USER_FILE}"
  echo ""
fi

# ---------------------------------------------------------------------------
# Username
# ---------------------------------------------------------------------------
if [[ -z "${NEW_USERNAME:-}" ]]; then
  while true; do
    read -r -p "Username (letters, numbers, dots, hyphens, underscores): " NEW_USERNAME
    if [[ -z "${NEW_USERNAME}" ]]; then
      echo "  Username cannot be empty." >&2; continue
    fi
    if ! [[ "${NEW_USERNAME}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
      echo "  Invalid username. Use only letters, numbers, dots, hyphens, underscores." >&2; continue
    fi
    break
  done
else
  if ! [[ "${NEW_USERNAME}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "ERROR: Invalid NEW_USERNAME '${NEW_USERNAME}': use only letters, numbers, dots, hyphens, underscores." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Full name
# ---------------------------------------------------------------------------
if [[ -z "${FULL_NAME:-}" ]]; then
  while true; do
    read -r -p "Full name (e.g. Alice Smith): " FULL_NAME
    if [[ -z "${FULL_NAME}" ]]; then
      echo "  Full name cannot be empty." >&2; continue
    fi
    break
  done
fi

# ---------------------------------------------------------------------------
# Email address
# ---------------------------------------------------------------------------
if [[ -z "${USER_EMAIL:-}" ]]; then
  while true; do
    read -r -p "Email address: " USER_EMAIL
    if [[ -z "${USER_EMAIL}" ]]; then
      echo "  Email cannot be empty." >&2; continue
    fi
    break
  done
fi

# ---------------------------------------------------------------------------
# Role
# ---------------------------------------------------------------------------
if [[ -z "${ROLE:-}" ]]; then
  echo ""
  echo "Role:"
  echo "  1) user   (DeveloperAccess — scoped to own instance)  [default]"
  echo "  2) admin  (ProjectAdminAccess — full project access)"
  read -r -p "Select role [1]: " ROLE_CHOICE
  ROLE_CHOICE="${ROLE_CHOICE:-1}"
  case "${ROLE_CHOICE}" in
    1|user)  ROLE="user";  PS_NAME="DeveloperAccess" ;;
    2|admin) ROLE="admin"; PS_NAME="ProjectAdminAccess" ;;
    *)
      echo "  Invalid choice. Defaulting to user." >&2
      ROLE="user"; PS_NAME="DeveloperAccess"
      ;;
  esac
else
  case "${ROLE}" in
    user)  PS_NAME="DeveloperAccess" ;;
    admin) PS_NAME="ProjectAdminAccess" ;;
    *)
      echo "ERROR: Invalid ROLE '${ROLE}': must be 'user' or 'admin'." >&2
      exit 1
      ;;
  esac
fi
echo "  Role: ${ROLE}"
echo ""

# ---------------------------------------------------------------------------
# SSH key
# ---------------------------------------------------------------------------
SSH_PRIVATE_KEY_FILE=""

if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
  echo "SSH public key provided."
  echo ""
elif [[ -n "${USER_FILE}" ]]; then
  # File mode, no key supplied — auto-generate
  PRIV_KEY_PATH="/tmp/${NEW_USERNAME}-fre-claude"
  rm -f "${PRIV_KEY_PATH}" "${PRIV_KEY_PATH}.pub"
  ssh-keygen -t ed25519 -N "" \
    -f "${PRIV_KEY_PATH}" \
    -C "${NEW_USERNAME}@${PROJECT_NAME}" >/dev/null
  SSH_PUBLIC_KEY=$(cat "${PRIV_KEY_PATH}.pub")
  SSH_PRIVATE_KEY_FILE="${PRIV_KEY_PATH}"
  echo "SSH key: auto-generated (${PRIV_KEY_PATH})"
  echo ""
elif [[ "${ROLE}" == "admin" ]]; then
  echo "Admins must supply their own SSH public key (no private key generated or stored)."
  while true; do
    read -r -p "SSH public key (paste full key, e.g. ssh-ed25519 AAAA...): " SSH_PUBLIC_KEY
    if [[ -z "${SSH_PUBLIC_KEY}" ]]; then
      echo "  SSH public key cannot be empty." >&2; continue
    fi
    if ! [[ "${SSH_PUBLIC_KEY}" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|sk-ssh-ed25519@openssh\.com) ]]; then
      echo "  WARNING: Key does not start with a recognized SSH key type. Proceeding anyway."
    fi
    break
  done
  echo ""
else
  echo "SSH key:"
  echo "  1) Generate automatically (recommended)  [default]"
  echo "  2) Provide my own public key"
  read -r -p "Select option [1]: " KEY_CHOICE
  KEY_CHOICE="${KEY_CHOICE:-1}"
  case "${KEY_CHOICE}" in
    1|generate|*)
      PRIV_KEY_PATH="/tmp/${NEW_USERNAME}-fre-claude"
      rm -f "${PRIV_KEY_PATH}" "${PRIV_KEY_PATH}.pub"
      ssh-keygen -t ed25519 -N "" \
        -f "${PRIV_KEY_PATH}" \
        -C "${NEW_USERNAME}@${PROJECT_NAME}" >/dev/null
      SSH_PUBLIC_KEY=$(cat "${PRIV_KEY_PATH}.pub")
      SSH_PRIVATE_KEY_FILE="${PRIV_KEY_PATH}"
      echo "  Generated: ${PRIV_KEY_PATH}"
      ;;
    2|own)
      while true; do
        read -r -p "SSH public key (paste full key, e.g. ssh-ed25519 AAAA...): " SSH_PUBLIC_KEY
        if [[ -z "${SSH_PUBLIC_KEY}" ]]; then
          echo "  SSH public key cannot be empty." >&2; continue
        fi
        if ! [[ "${SSH_PUBLIC_KEY}" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|sk-ssh-ed25519@openssh\.com) ]]; then
          echo "  WARNING: Key does not start with a recognized SSH key type. Proceeding anyway."
        fi
        break
      done
      ;;
  esac
  echo ""
fi

# ---------------------------------------------------------------------------
# Git identity
# ---------------------------------------------------------------------------
if [[ -z "${GIT_USER_NAME:-}" ]]; then
  read -r -p "Git user name [${FULL_NAME}]: " GIT_USER_NAME
fi
GIT_USER_NAME="${GIT_USER_NAME:-${FULL_NAME}}"

if [[ -z "${GIT_USER_EMAIL:-}" ]]; then
  read -r -p "Git user email [${USER_EMAIL}]: " GIT_USER_EMAIL
fi
GIT_USER_EMAIL="${GIT_USER_EMAIL:-${USER_EMAIL}}"

echo ""
echo "Adding user '${NEW_USERNAME}'..."

# ---------------------------------------------------------------------------
# Download current registry and check for duplicate
# ---------------------------------------------------------------------------
USERS_JSON=$(mktemp)
trap 'rm -f "${USERS_JSON}" "${USERS_JSON}.tmp"' EXIT

users_s3_download "${USERS_JSON}"

if jq -e --arg user "${NEW_USERNAME}" '.[$user] != null' "${USERS_JSON}" >/dev/null 2>&1; then
  echo "ERROR: User '${NEW_USERNAME}' already exists in the registry." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# IAM Identity Center: create user and account assignment
# ---------------------------------------------------------------------------
echo ""
echo "Creating IAM Identity Center user..."

SSO_INSTANCE_ARN=$(aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
  sso-admin list-instances \
  --query 'Instances[0].InstanceArn' --output text 2>/dev/null || echo "")

if [[ -z "${SSO_INSTANCE_ARN}" || "${SSO_INSTANCE_ARN}" == "None" ]]; then
  echo "ERROR: No IAM Identity Center instance found in region ${SSO_REGION}." >&2
  echo "       Verify SSO_REGION in config/admin.env and re-run." >&2
  exit 1
fi

IDENTITY_STORE_ID=$(aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
  sso-admin list-instances \
  --query 'Instances[0].IdentityStoreId' --output text)

# Derive GivenName / FamilyName from FULL_NAME (first word = given, rest = family)
GIVEN_NAME="${FULL_NAME%% *}"
FAMILY_NAME="${FULL_NAME#* }"
if [[ "${FAMILY_NAME}" == "${FULL_NAME}" ]]; then
  FAMILY_NAME=""
fi

# Check if user already exists in identity store (by username)
EXISTING_USER_ID=$(aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
  identitystore list-users \
  --identity-store-id "${IDENTITY_STORE_ID}" \
  --filters "AttributePath=UserName,AttributeValue=${NEW_USERNAME}" \
  --query 'Users[0].UserId' --output text 2>/dev/null || echo "")

# Also check if the email is already in use by any user
EXISTING_EMAIL_USER=$(aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
  identitystore list-users \
  --identity-store-id "${IDENTITY_STORE_ID}" \
  --filters "AttributePath=Emails.Value,AttributeValue=${USER_EMAIL}" \
  --query 'Users[0]' --output json 2>/dev/null || echo "null")
EXISTING_EMAIL_USER_ID=$(echo "${EXISTING_EMAIL_USER}" | jq -r '.UserId // empty')
EXISTING_EMAIL_USERNAME=$(echo "${EXISTING_EMAIL_USER}" | jq -r '.UserName // empty')

if [[ -n "${EXISTING_USER_ID}" && "${EXISTING_USER_ID}" != "None" ]]; then
  echo "  IAM Identity Center user '${NEW_USERNAME}' already exists (id: ${EXISTING_USER_ID})."
  SSO_USER_ID="${EXISTING_USER_ID}"
elif [[ -n "${EXISTING_EMAIL_USER_ID}" ]]; then
  echo "ERROR: Email '${USER_EMAIL}' is already in use by Identity Center user '${EXISTING_EMAIL_USERNAME}'." >&2
  echo "       Use a different email address, or remove the existing user first." >&2
  exit 1
else
  EMAILS_JSON="[{\"Value\": \"${USER_EMAIL}\", \"Type\": \"work\", \"Primary\": true}]"
  NAME_JSON="{\"GivenName\": \"${GIVEN_NAME}\", \"FamilyName\": \"${FAMILY_NAME}\", \"Formatted\": \"${FULL_NAME}\"}"

  SSO_USER_ID=$(aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
    identitystore create-user \
    --identity-store-id "${IDENTITY_STORE_ID}" \
    --user-name "${NEW_USERNAME}" \
    --display-name "${FULL_NAME}" \
    --name "${NAME_JSON}" \
    --emails "${EMAILS_JSON}" \
    --query 'UserId' --output text)
  echo "  Created IAM Identity Center user: ${NEW_USERNAME} (id: ${SSO_USER_ID})"
fi

# Find permission set ARN
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

PS_ARN=$(_find_ps_arn "${PS_NAME}")
if [[ -z "${PS_ARN}" ]]; then
  echo "ERROR: Permission set '${PS_NAME}' not found." >&2
  echo "       Run './admin.sh bootstrap' to create it." >&2
  exit 1
fi

# Remove any existing assignments for the OTHER known permission sets so
# the user ends up with exactly one role on this account.
for OTHER_PS_NAME in "DeveloperAccess" "ProjectAdminAccess"; do
  [[ "${OTHER_PS_NAME}" == "${PS_NAME}" ]] && continue
  OTHER_PS_ARN=$(_find_ps_arn "${OTHER_PS_NAME}")
  [[ -z "${OTHER_PS_ARN}" ]] && continue

  ALREADY_ASSIGNED=$(aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
    sso-admin list-account-assignments \
    --instance-arn "${SSO_INSTANCE_ARN}" \
    --account-id "${TF_BACKEND_ACCOUNT_ID}" \
    --permission-set-arn "${OTHER_PS_ARN}" \
    --query 'AccountAssignments' --output json 2>/dev/null \
    | jq --arg uid "${SSO_USER_ID}" \
        '[.[] | select(.PrincipalType=="USER" and .PrincipalId==$uid)] | length')

  if [[ "${ALREADY_ASSIGNED}" -gt 0 ]]; then
    echo "  Removing existing '${OTHER_PS_NAME}' assignment..."
    aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
      sso-admin delete-account-assignment \
      --instance-arn "${SSO_INSTANCE_ARN}" \
      --target-id "${TF_BACKEND_ACCOUNT_ID}" \
      --target-type AWS_ACCOUNT \
      --permission-set-arn "${OTHER_PS_ARN}" \
      --principal-type USER \
      --principal-id "${SSO_USER_ID}" >/dev/null
    echo "  Removed '${OTHER_PS_NAME}' from ${NEW_USERNAME}."
  fi
done

# Assign the target permission set and wait for the async provisioning to complete
ASSIGN_OUT=$(aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
  sso-admin create-account-assignment \
  --instance-arn "${SSO_INSTANCE_ARN}" \
  --target-id "${TF_BACKEND_ACCOUNT_ID}" \
  --target-type AWS_ACCOUNT \
  --permission-set-arn "${PS_ARN}" \
  --principal-type USER \
  --principal-id "${SSO_USER_ID}" \
  --output json 2>&1) || {
  echo "ERROR: create-account-assignment failed: ${ASSIGN_OUT}" >&2
  exit 1
}

ASSIGN_REQUEST_ID=$(echo "${ASSIGN_OUT}" | jq -r '.AccountAssignmentCreationStatus.RequestId // empty')
ASSIGN_INITIAL_STATUS=$(echo "${ASSIGN_OUT}" | jq -r '.AccountAssignmentCreationStatus.Status // empty')

if [[ "${ASSIGN_INITIAL_STATUS}" == "SUCCEEDED" ]]; then
  echo "  Assigned '${PS_NAME}' to ${NEW_USERNAME} on account ${TF_BACKEND_ACCOUNT_ID}."
elif [[ -z "${ASSIGN_REQUEST_ID}" ]]; then
  echo "  WARNING: Could not determine assignment RequestId. Check IAM Identity Center console." >&2
else
  echo "  Waiting for '${PS_NAME}' assignment to provision..."
  ASSIGN_STATUS=""
  for _ in $(seq 1 20); do
    ASSIGN_RESULT=$(aws --region "${SSO_REGION}" --profile "${AWS_PROFILE}" \
      sso-admin describe-account-assignment-creation-status \
      --instance-arn "${SSO_INSTANCE_ARN}" \
      --account-assignment-creation-request-id "${ASSIGN_REQUEST_ID}" \
      --output json 2>/dev/null || echo "{}")
    ASSIGN_STATUS=$(echo "${ASSIGN_RESULT}" | jq -r '.AccountAssignmentCreationStatus.Status // empty')
    [[ "${ASSIGN_STATUS}" == "SUCCEEDED" ]] && break
    if [[ "${ASSIGN_STATUS}" == "FAILED" ]]; then
      ASSIGN_REASON=$(echo "${ASSIGN_RESULT}" | jq -r '.AccountAssignmentCreationStatus.FailureReason // "no reason provided"')
      echo "ERROR: Account assignment FAILED: ${ASSIGN_REASON}" >&2
      exit 1
    fi
    sleep 3
  done
  if [[ "${ASSIGN_STATUS}" == "SUCCEEDED" ]]; then
    echo "  Assigned '${PS_NAME}' to ${NEW_USERNAME} on account ${TF_BACKEND_ACCOUNT_ID}."
  else
    echo "ERROR: Timed out waiting for account assignment (last status: ${ASSIGN_STATUS:-unknown})." >&2
    echo "       Check IAM Identity Center → AWS accounts in the console." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Generate user.env
# ---------------------------------------------------------------------------
AWS_PROFILE_FOR_DEV="claude-code"
DEVELOPER_ENV="MY_USERNAME=${NEW_USERNAME}
PROJECT_NAME=${PROJECT_NAME}
AWS_PROFILE=${AWS_PROFILE_FOR_DEV}
AWS_REGION=${AWS_REGION}
"

# ---------------------------------------------------------------------------
# Generate aws-config
# ---------------------------------------------------------------------------
SSO_ROLE_NAME="${PS_NAME}"
AWS_CONFIG="[profile ${AWS_PROFILE_FOR_DEV}]
sso_session = fre-aws-sso
sso_account_id = ${TF_BACKEND_ACCOUNT_ID}
sso_role_name = ${SSO_ROLE_NAME}
region = ${AWS_REGION}

[sso-session fre-aws-sso]
sso_start_url = ${SSO_START_URL}
sso_region = ${SSO_REGION}
sso_registration_scopes = sso:account:access
"

# ---------------------------------------------------------------------------
# Save onboarding bundle to config/onboarding/<username>/
# ---------------------------------------------------------------------------
BUNDLE_DIR="${SCRIPT_DIR}/../config/onboarding/${NEW_USERNAME}"
mkdir -p "${BUNDLE_DIR}"

if [[ -n "${SSH_PRIVATE_KEY_FILE}" ]]; then
  cp "${SSH_PRIVATE_KEY_FILE}" "${BUNDLE_DIR}/fre-claude"
  chmod 600 "${BUNDLE_DIR}/fre-claude"
fi

printf '%s' "${AWS_CONFIG}" > "${BUNDLE_DIR}/aws-config"
printf '%s' "${DEVELOPER_ENV}" > "${BUNDLE_DIR}/user.env"

echo ""
echo "Onboarding bundle saved to: config/onboarding/${NEW_USERNAME}/"

# ---------------------------------------------------------------------------
# Update S3 registry
# ---------------------------------------------------------------------------
jq \
  --arg user   "${NEW_USERNAME}" \
  --arg key    "${SSH_PUBLIC_KEY}" \
  --arg name   "${GIT_USER_NAME}" \
  --arg email  "${GIT_USER_EMAIL}" \
  --arg role   "${ROLE}" \
  --arg uemail "${USER_EMAIL}" \
  '.[$user] = {
    ssh_public_key: $key,
    git_user_name:  $name,
    git_user_email: $email,
    role:           $role,
    user_email:     $uemail
  }' \
  "${USERS_JSON}" > "${USERS_JSON}.tmp"
mv "${USERS_JSON}.tmp" "${USERS_JSON}"

users_s3_upload "${USERS_JSON}"
echo "User '${NEW_USERNAME}' added to S3 registry."

# ---------------------------------------------------------------------------
# Send onboarding email via SES
# ---------------------------------------------------------------------------
echo ""
echo "Sending onboarding email to ${USER_EMAIL}..."

ATTACHMENT_ARGS=()
if [[ -n "${SSH_PRIVATE_KEY_FILE}" ]]; then
  ATTACHMENT_ARGS+=("--attachment" "${BUNDLE_DIR}/fre-claude:fre-claude")
fi
ATTACHMENT_ARGS+=("--attachment" "${BUNDLE_DIR}/aws-config:aws-config")
ATTACHMENT_ARGS+=("--attachment" "${BUNDLE_DIR}/user.env:user.env")

python3 "${SCRIPT_DIR}/send-onboarding-email.py" \
  --to "${USER_EMAIL}" \
  --from "${SENDER_EMAIL}" \
  --username "${NEW_USERNAME}" \
  --project "${PROJECT_NAME}" \
  --role "${ROLE}" \
  --aws-profile "${AWS_PROFILE_FOR_DEV}" \
  --aws-region "${AWS_REGION}" \
  --aws-cli-profile "${AWS_PROFILE}" \
  --ses-region "${AWS_REGION}" \
  --sso-start-url "${SSO_START_URL}" \
  --user-email "${USER_EMAIL}" \
  "${ATTACHMENT_ARGS[@]}"

echo ""
echo "=== Done ==="
echo ""
echo "  IAM Identity Center user: ${NEW_USERNAME}"
echo "  Permission set:           ${PS_NAME}"
echo "  Bundle:                   config/onboarding/${NEW_USERNAME}/"
echo "  Email sent to:            ${USER_EMAIL}"
echo ""
echo "Next: run './admin.sh up' to provision their EC2 instance."
