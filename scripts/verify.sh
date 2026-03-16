#!/usr/bin/env bash
# verify.sh — Confirm AWS credentials are active and show identity + role.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load whichever config is present (admin or user context)
if [[ -f "${SCRIPT_DIR}/../config/admin.env" ]]; then
  source "${SCRIPT_DIR}/../config/admin.env"
elif [[ -f "${SCRIPT_DIR}/../config/user.env" ]]; then
  source "${SCRIPT_DIR}/../config/user.env"
fi

: "${AWS_PROFILE:?AWS_PROFILE not set}"

IDENTITY=$(aws sts get-caller-identity --profile "${AWS_PROFILE}" --output json 2>&1) || {
  echo "ERROR: Could not retrieve identity for profile '${AWS_PROFILE}'." >&2
  echo "       AWS error: ${IDENTITY}" >&2
  echo "       Run './admin.sh sso-login' (or './user.sh sso-login') to authenticate." >&2
  exit 1
}

ACCOUNT=$(echo "${IDENTITY}" | jq -r '.Account')
ARN=$(echo "${IDENTITY}" | jq -r '.Arn')
USER_ID=$(echo "${IDENTITY}" | jq -r '.UserId' | cut -d: -f2)   # strip AROA... prefix for SSO

# Extract role/identity type from ARN
#   assumed-role: arn:aws:sts::ACCOUNT:assumed-role/ROLE/SESSION
#   IAM user:     arn:aws:iam::ACCOUNT:user/NAME
ARN_TYPE=$(echo "${ARN}" | cut -d: -f6 | cut -d/ -f1)   # assumed-role, user, etc.

case "${ARN_TYPE}" in
  assumed-role)
    RAW_ROLE=$(echo "${ARN}" | sed 's|.*assumed-role/||; s|/.*||')
    # AWSReservedSSO_PermissionSetName_hexsuffix → PermissionSetName
    if [[ "${RAW_ROLE}" == AWSReservedSSO_* ]]; then
      ROLE=$(echo "${RAW_ROLE}" | sed 's/^AWSReservedSSO_//; s/_[a-f0-9]*$//')
      ROLE_DISPLAY="${ROLE}  (SSO permission set)"
    else
      ROLE_DISPLAY="${RAW_ROLE}  (assumed role)"
    fi
    ;;
  user)
    ROLE_DISPLAY="$(echo "${ARN}" | cut -d/ -f2-)  (IAM user)"
    ;;
  *)
    ROLE_DISPLAY="${ARN_TYPE}"
    ;;
esac

echo "Account:  ${ACCOUNT}"
echo "User:     ${USER_ID}"
echo "Role:     ${ROLE_DISPLAY}"
echo "Arn:      ${ARN}"
