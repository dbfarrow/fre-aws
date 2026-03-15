#!/usr/bin/env bash
# users-s3.sh — Shared library for managing the user registry in S3.
# Source this file; do not execute directly.
#
# Required environment (loaded by callers from defaults.env + backend.env):
#   PROJECT_NAME       — used as S3 key prefix
#   AWS_PROFILE        — AWS CLI profile
#   TF_BACKEND_BUCKET  — S3 bucket name (same bucket as Terraform state)
#   TF_BACKEND_REGION  — S3 bucket region

# ---------------------------------------------------------------------------
# Internal: S3 key for the user registry
# ---------------------------------------------------------------------------
_users_s3_key() {
  echo "${PROJECT_NAME}/users.json"
}

# ---------------------------------------------------------------------------
# users_s3_download <dest_file>
# Downloads users.json from S3 to dest_file.
# If the object does not exist (404), writes '{}' to dest_file.
# Any other error (auth, network, wrong region) is fatal — never silently
# returns '{}' for a real failure.
# ---------------------------------------------------------------------------
users_s3_download() {
  local dest="${1:?dest_file required}"
  local key
  key=$(_users_s3_key)

  local err
  err=$(aws s3 cp \
    "s3://${TF_BACKEND_BUCKET}/${key}" \
    "${dest}" \
    --region "${TF_BACKEND_REGION}" \
    --profile "${AWS_PROFILE}" 2>&1)
  local exit_code=$?

  if [[ ${exit_code} -eq 0 ]]; then
    return 0
  fi

  # 404 / NoSuchKey means the registry hasn't been initialised yet — treat as empty
  if echo "${err}" | grep -qE "404|NoSuchKey|does not exist"; then
    echo '{}' > "${dest}"
  else
    echo "ERROR: Failed to download user registry from S3." >&2
    echo "       Bucket: ${TF_BACKEND_BUCKET}  Key: ${key}" >&2
    echo "       ${err}" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# users_s3_upload <src_file>
# Uploads src_file to S3 as the user registry JSON.
# ---------------------------------------------------------------------------
users_s3_upload() {
  local src="${1:?src_file required}"
  local key
  key=$(_users_s3_key)

  aws s3 cp \
    "${src}" \
    "s3://${TF_BACKEND_BUCKET}/${key}" \
    --region "${TF_BACKEND_REGION}" \
    --profile "${AWS_PROFILE}" >/dev/null
}

# ---------------------------------------------------------------------------
# users_render_tfvars <json_file> <tfvars_file>
# Converts users.json → HCL tfvars format consumable by Terraform.
#
# Input JSON:
#   {
#     "alice": {
#       "ssh_public_key": "ssh-ed25519 AAAA...",
#       "git_user_name":  "Alice Smith",
#       "git_user_email": "alice@example.com"
#     }
#   }
#
# Output HCL:
#   users = {
#     "alice" = {
#       ssh_public_key = "ssh-ed25519 AAAA..."
#       git_user_name  = "Alice Smith"
#       git_user_email = "alice@example.com"
#     }
#   }
# ---------------------------------------------------------------------------
users_render_tfvars() {
  local json_file="${1:?json_file required}"
  local tfvars_file="${2:?tfvars_file required}"

  # @json provides proper JSON escaping (including surrounding quotes),
  # which is compatible with HCL string literals.
  jq -r '
    "users = {",
    (to_entries[] |
      "  \"\(.key)\" = {",
      "    ssh_public_key = \(.value.ssh_public_key | @json)",
      "    git_user_name  = \(.value.git_user_name  | @json)",
      "    git_user_email = \(.value.git_user_email | @json)",
      "  }",
      ""
    ),
    "}"
  ' "${json_file}" > "${tfvars_file}"
}
