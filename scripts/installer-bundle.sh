#!/usr/bin/env bash
# installer-bundle.sh — Shared functions for uploading onboarding files and
# creating installer bundles. Source this file; do not execute it directly.
#
# Requires these variables to be set before sourcing:
#   SCRIPT_DIR, TF_BACKEND_BUCKET, TF_BACKEND_REGION, AWS_PROFILE, PROJECT_NAME
#
# Usage:
#   source "${SCRIPT_DIR}/installer-bundle.sh"
#   _upload_onboarding_files "<username>" "<src_dir>"
#   INSTALLER_URL=$(_create_installer_bundle "<username>" "[local_bundle_dir]")

# ---------------------------------------------------------------------------
# _upload_onboarding_files <username> <src_dir>
#
# Uploads user.env, aws-config, and optionally fre-claude from src_dir to S3
# under ${PROJECT_NAME}/users/${username}/. These are the authoritative
# onboarding files used by all subsequent bundle operations.
# ---------------------------------------------------------------------------
_upload_onboarding_files() {
  local username="${1}" src_dir="${2}"
  local s3_prefix="s3://${TF_BACKEND_BUCKET}/${PROJECT_NAME}/users/${username}"
  aws s3 cp "${src_dir}/user.env"   "${s3_prefix}/user.env"   --region "${TF_BACKEND_REGION}" --profile "${AWS_PROFILE}" >/dev/null
  aws s3 cp "${src_dir}/aws-config" "${s3_prefix}/aws-config" --region "${TF_BACKEND_REGION}" --profile "${AWS_PROFILE}" >/dev/null
  if [[ -f "${src_dir}/fre-claude" ]]; then
    aws s3 cp "${src_dir}/fre-claude" "${s3_prefix}/fre-claude" --region "${TF_BACKEND_REGION}" --profile "${AWS_PROFILE}" >/dev/null
  fi
}

# ---------------------------------------------------------------------------
# _create_installer_bundle <username> [local_bundle_dir]
#
# Assembles a self-contained installer zip for a user, uploads it to S3,
# and prints a 72-hour pre-signed download URL to stdout.
#
# Onboarding files (user.env, aws-config, fre-claude) are downloaded from S3.
# If the S3 files are not found and local_bundle_dir is provided, they are
# auto-migrated from local to S3 (one-time migration path for existing users).
#
# Arguments:
#   username         — the user's username
#   local_bundle_dir — (optional) local fallback directory for auto-migration
# ---------------------------------------------------------------------------
_create_installer_bundle() {
  local username="$1"
  local local_bundle_dir="${2:-}"
  local s3_prefix="s3://${TF_BACKEND_BUCKET}/${PROJECT_NAME}/users/${username}"

  # Download onboarding files from S3 into a temp dir
  local src_dir
  src_dir=$(mktemp -d)

  if ! aws s3 cp "${s3_prefix}/user.env" "${src_dir}/user.env" --region "${TF_BACKEND_REGION}" --profile "${AWS_PROFILE}" >/dev/null 2>&1; then
    # S3 files not found — try auto-migration from local bundle dir
    if [[ -n "${local_bundle_dir}" && -f "${local_bundle_dir}/user.env" ]]; then
      echo "  (Migrating onboarding files for '${username}' to S3...)" >&2
      cp "${local_bundle_dir}/user.env"   "${src_dir}/user.env"
      cp "${local_bundle_dir}/aws-config" "${src_dir}/aws-config"
      if [[ -f "${local_bundle_dir}/fre-claude" ]]; then
        cp "${local_bundle_dir}/fre-claude" "${src_dir}/fre-claude"
      fi
      _upload_onboarding_files "${username}" "${src_dir}"
      echo "  Onboarding files migrated to S3." >&2
    else
      rm -rf "${src_dir}"
      echo "ERROR: Onboarding files for '${username}' not found in S3 or locally." >&2
      echo "       Run publish-installer from the original machine to migrate them." >&2
      return 1
    fi
  else
    # S3 download succeeded — also fetch aws-config and optional fre-claude
    aws s3 cp "${s3_prefix}/aws-config" "${src_dir}/aws-config" --region "${TF_BACKEND_REGION}" --profile "${AWS_PROFILE}" >/dev/null 2>&1 || true
    aws s3 cp "${s3_prefix}/fre-claude" "${src_dir}/fre-claude" --region "${TF_BACKEND_REGION}" --profile "${AWS_PROFILE}" >/dev/null 2>&1 || true
  fi

  # Populate bundle structure in a separate temp dir
  local tmp_dir
  tmp_dir=$(mktemp -d)

  cp "${SCRIPT_DIR}/../run.sh"       "${tmp_dir}/user.sh"
  chmod +x "${tmp_dir}/user.sh"
  cp "${SCRIPT_DIR}/../Dockerfile"   "${tmp_dir}/Dockerfile"
  cp "${SCRIPT_DIR}/install.sh"      "${tmp_dir}/install.sh"
  chmod +x "${tmp_dir}/install.sh"

  mkdir -p "${tmp_dir}/scripts"
  for s in connect.sh start.sh stop.sh verify.sh update.sh upload.sh; do
    if [[ -f "${SCRIPT_DIR}/${s}" ]]; then
      cp "${SCRIPT_DIR}/${s}" "${tmp_dir}/scripts/"
    fi
  done

  mkdir -p "${tmp_dir}/config"
  cp "${src_dir}/user.env"        "${tmp_dir}/config/user.env"

  mkdir -p "${tmp_dir}/credentials"
  cp "${src_dir}/aws-config"      "${tmp_dir}/credentials/aws-config"
  if [[ -f "${src_dir}/fre-claude" ]]; then
    cp "${src_dir}/fre-claude"    "${tmp_dir}/credentials/fre-claude"
  fi

  rm -rf "${src_dir}"

  # Create zip
  local zip_dir
  zip_dir=$(mktemp -d)
  local zip_path="${zip_dir}/installer.zip"
  (cd "${tmp_dir}" && zip -r "${zip_path}" . -x "*.DS_Store") >/dev/null
  rm -rf "${tmp_dir}"

  # Upload to S3
  aws s3 cp "${zip_path}" \
    "s3://${TF_BACKEND_BUCKET}/${PROJECT_NAME}/installers/${username}/latest.zip" \
    --region "${TF_BACKEND_REGION}" --profile "${AWS_PROFILE}" >/dev/null
  rm -rf "${zip_dir}"

  # Return pre-signed URL (72-hour expiry)
  aws s3 presign \
    "s3://${TF_BACKEND_BUCKET}/${PROJECT_NAME}/installers/${username}/latest.zip" \
    --region "${TF_BACKEND_REGION}" --profile "${AWS_PROFILE}" \
    --expires-in 259200
}
