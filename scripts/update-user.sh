#!/usr/bin/env bash
# update-user.sh — Merge updated fields from a local .env file into the S3 registry.
# Does NOT touch IAM Identity Center, installer bundles, or running instances.
#
# Usage: ./admin.sh update-user <file>
#   Recognised fields: NEW_USERNAME, USER_EMAIL, ROLE, GIT_USER_NAME,
#     GIT_USER_EMAIL, SSH_PUBLIC_KEY, PREFERRED_SHELL, SLACK_USER_ID
#
# To apply changes to a running instance: ./admin.sh refresh <username>
# For SSH key changes: also run ./admin.sh update-user-key <username>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Validate file argument
# ---------------------------------------------------------------------------
USER_FILE="${1:-}"
if [[ -z "${USER_FILE}" ]]; then
  echo "Usage: admin.sh update-user <file.env>" >&2
  exit 1
fi
if [[ ! -f "${USER_FILE}" ]]; then
  echo "ERROR: File not found: ${USER_FILE}" >&2
  exit 1
fi

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

: "${PROJECT_NAME:?}" "${TF_BACKEND_BUCKET:?}" "${TF_BACKEND_REGION:?}"

# ---------------------------------------------------------------------------
# Load fields from user file
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "${USER_FILE}"

TARGET_USERNAME="${NEW_USERNAME:-}"
if [[ -z "${TARGET_USERNAME}" ]]; then
  echo "ERROR: NEW_USERNAME not set in ${USER_FILE}." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Export AWS credentials
# ---------------------------------------------------------------------------
_PROFILE_ARGS=()
[[ -n "${AWS_PROFILE:-}" ]] && _PROFILE_ARGS=(--profile "${AWS_PROFILE}")
_CREDS=$(aws configure export-credentials "${_PROFILE_ARGS[@]}" --format env-no-export 2>/dev/null) || {
  echo "ERROR: Could not export credentials${AWS_PROFILE:+ for profile '${AWS_PROFILE}'}." >&2
  echo "       Run './admin.sh sso-login' first." >&2
  exit 1
}
eval "$(echo "${_CREDS}" | sed 's/^/export /')"
unset _CREDS _PROFILE_ARGS

# ---------------------------------------------------------------------------
# Download registry
# ---------------------------------------------------------------------------
USERS_JSON=$(mktemp)
trap 'rm -f "${USERS_JSON}" "${USERS_JSON}.tmp"' EXIT

users_s3_download "${USERS_JSON}"

if ! jq -e --arg u "${TARGET_USERNAME}" '.[$u] != null' "${USERS_JSON}" >/dev/null 2>&1; then
  echo "ERROR: User '${TARGET_USERNAME}' not found in registry." >&2
  echo "       To add a new user: ./admin.sh add-user ${USER_FILE}" >&2
  exit 1
fi

echo "=== Update User: ${TARGET_USERNAME} ==="
echo ""

# ---------------------------------------------------------------------------
# Merge only the fields present in the file (non-empty values overwrite;
# empty values are left unchanged in the registry).
# ---------------------------------------------------------------------------
jq \
  --arg user          "${TARGET_USERNAME}" \
  --arg user_email    "${USER_EMAIL:-}" \
  --arg role          "${ROLE:-}" \
  --arg git_name      "${GIT_USER_NAME:-}" \
  --arg git_email     "${GIT_USER_EMAIL:-}" \
  --arg ssh_key       "${SSH_PUBLIC_KEY:-}" \
  --arg shell         "${PREFERRED_SHELL:-}" \
  --arg slack_user_id "${SLACK_USER_ID:-}" \
  '
  .[$user] *=
    (if $user_email    != "" then {user_email:      $user_email}    else {} end) +
    (if $role          != "" then {role:            $role}          else {} end) +
    (if $git_name      != "" then {git_user_name:   $git_name}      else {} end) +
    (if $git_email     != "" then {git_user_email:  $git_email}     else {} end) +
    (if $ssh_key       != "" then {ssh_public_key:  $ssh_key}       else {} end) +
    (if $shell         != "" then {preferred_shell: $shell}         else {} end) +
    (if $slack_user_id != "" then {slack_user_id:   $slack_user_id} else {} end)
  ' \
  "${USERS_JSON}" > "${USERS_JSON}.tmp"
mv "${USERS_JSON}.tmp" "${USERS_JSON}"

users_s3_upload "${USERS_JSON}"
echo "Registry updated for '${TARGET_USERNAME}'."
echo ""
echo "Run './admin.sh refresh ${TARGET_USERNAME}' to apply to a running instance."
echo "(Note: ssh_public_key changes also require './admin.sh update-user-key ${TARGET_USERNAME}'.)"
