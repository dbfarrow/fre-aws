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

# ---------------------------------------------------------------------------
# check_profile <profile> <label>
# Prints identity info for the profile. Returns 1 if auth fails, 2 if the
# profile is not configured. Pass empty string to use default credentials.
# ---------------------------------------------------------------------------
check_profile() {
  local profile="${1}" label="${2}"

  if [[ -n "${profile}" ]]; then
    echo "=== ${label} (${profile}) ==="
  else
    echo "=== ${label} (default credentials) ==="
  fi

  local profile_args=()
  [[ -n "${profile}" ]] && profile_args=(--profile "${profile}")

  local out
  out=$(aws sts get-caller-identity "${profile_args[@]}" --output json 2>&1) || {
    if echo "${out}" | grep -qi "could not be found\|does not exist\|No profile"; then
      echo "  Not configured."
      echo ""
      return 2
    fi
    if echo "${out}" | grep -qi "ForbiddenException\|No access\|not authorized"; then
      echo "  ERROR: SSO session valid but role is not accessible." >&2
      echo "         The permission set may not be assigned to your user in Identity Center." >&2
      echo "         If you just tore down and are rebuilding: run './admin.sh bootstrap' first." >&2
      echo ""
      return 1
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
  if [[ -n "${CONNECT_PROFILE:-}" ]]; then
    DEV_PROFILE="${CONNECT_PROFILE}"
  elif [[ -n "${AWS_PROFILE:-}" ]]; then
    DEV_PROFILE="${AWS_PROFILE}-dev"
  else
    DEV_PROFILE=""
  fi
  ADMIN_OK=true
  DEV_OK=true

  check_profile "${AWS_PROFILE}" "admin" || {
    [[ $? -eq 1 ]] && ADMIN_OK=false
  }

  # In managed mode, also verify the connect profile used by 'connect'.
  # In external mode, connect uses AWS_PROFILE directly — no fre-aws dev profile exists.
  # Skip if no dev profile could be derived (AWS_PROFILE unset, no CONNECT_PROFILE).
  if [[ "${IDENTITY_MODE:-managed}" != "external" && -n "${DEV_PROFILE}" ]]; then
    check_profile "${DEV_PROFILE}" "connect" || {
      [[ $? -eq 1 ]] && DEV_OK=false
    }
  fi

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
