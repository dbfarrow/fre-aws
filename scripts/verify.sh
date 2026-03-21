#!/usr/bin/env bash
# verify.sh — Confirm AWS credentials are active and show identity + role.
#
# In admin context: checks both the admin profile and the derived dev profile
# (${AWS_PROFILE}-dev, used by 'connect'). Both must be working for all
# admin.sh commands to function correctly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load whichever config is present (admin or user context)
IS_ADMIN=false
if [[ -f "${SCRIPT_DIR}/../config/admin.env" ]]; then
  source "${SCRIPT_DIR}/../config/admin.env"
  IS_ADMIN=true
elif [[ -f "${SCRIPT_DIR}/../config/user.env" ]]; then
  source "${SCRIPT_DIR}/../config/user.env"
fi

: "${AWS_PROFILE:?AWS_PROFILE not set}"

# ---------------------------------------------------------------------------
# check_profile <profile> <label>
# Prints identity info for the profile. Returns 1 if auth fails, 2 if the
# profile is not configured.
# ---------------------------------------------------------------------------
check_profile() {
  local profile="${1}" label="${2}"

  echo "=== ${label} (${profile}) ==="

  local out
  out=$(aws sts get-caller-identity --profile "${profile}" --output json 2>&1) || {
    if echo "${out}" | grep -qi "could not be found\|does not exist\|No profile"; then
      echo "  Not configured."
      echo ""
      return 2
    fi
    echo "  ERROR: credentials not valid or expired." >&2
    echo "         ${out}" >&2
    echo ""
    return 1
  }

  local account arn user_id arn_type role_display raw_role
  account=$(echo "${out}" | jq -r '.Account')
  arn=$(echo "${out}"     | jq -r '.Arn')
  user_id=$(echo "${out}" | jq -r '.UserId' | cut -d: -f2)   # strip AROA... prefix for SSO

  arn_type=$(echo "${arn}" | cut -d: -f6 | cut -d/ -f1)   # assumed-role, user, etc.

  case "${arn_type}" in
    assumed-role)
      raw_role=$(echo "${arn}" | sed 's|.*assumed-role/||; s|/.*||')
      if [[ "${raw_role}" == AWSReservedSSO_* ]]; then
        role_display=$(echo "${raw_role}" | sed 's/^AWSReservedSSO_//; s/_[a-f0-9]*$//')
        role_display="${role_display}  (SSO permission set)"
      else
        role_display="${raw_role}  (assumed role)"
      fi
      ;;
    user)
      role_display="$(echo "${arn}" | cut -d/ -f2-)  (IAM user)"
      ;;
    *)
      role_display="${arn_type}"
      ;;
  esac

  echo "  Account:  ${account}"
  echo "  User:     ${user_id}"
  echo "  Role:     ${role_display}"
  echo "  Arn:      ${arn}"
  echo ""
}

# ---------------------------------------------------------------------------
# Admin context: check both admin and dev profiles
# ---------------------------------------------------------------------------
if [[ "${IS_ADMIN}" == true ]]; then
  DEV_PROFILE="${AWS_PROFILE}-dev"
  ADMIN_OK=true
  DEV_OK=true

  check_profile "${AWS_PROFILE}" "admin" || {
    [[ $? -eq 1 ]] && ADMIN_OK=false
  }
  check_profile "${DEV_PROFILE}" "connect" || {
    [[ $? -eq 1 ]] && DEV_OK=false
  }

  if [[ "${ADMIN_OK}" == false || "${DEV_OK}" == false ]]; then
    echo "Run './admin.sh sso-login' to re-authenticate." >&2
    exit 1
  fi

# ---------------------------------------------------------------------------
# User context: check the single configured profile
# ---------------------------------------------------------------------------
else
  check_profile "${AWS_PROFILE}" "credentials" || {
    echo "Run './user.sh sso-login' to re-authenticate." >&2
    exit 1
  }
fi
