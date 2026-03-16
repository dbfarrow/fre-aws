#!/usr/bin/env bash
# list-users.sh — Outputs configured usernames, one per line, to stdout.
# No TTY required. Used by admin.sh start/stop loops to iterate all users.
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

# ---------------------------------------------------------------------------
# Download registry and emit usernames
# ---------------------------------------------------------------------------
USERS_JSON=$(mktemp)
trap 'rm -f "${USERS_JSON}"' EXIT

users_s3_download "${USERS_JSON}"
jq -r 'keys[]' "${USERS_JSON}" | sort
