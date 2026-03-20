#!/usr/bin/env bash
# installer-bundle.sh — Shared function for creating and uploading installer bundles.
# Source this file; do not execute it directly.
#
# Requires these variables to be set before sourcing:
#   SCRIPT_DIR, TF_BACKEND_BUCKET, TF_BACKEND_REGION, AWS_PROFILE, PROJECT_NAME
#
# Usage:
#   source "${SCRIPT_DIR}/installer-bundle.sh"
#   INSTALLER_URL=$(_create_installer_bundle "<username>" "<bundle_dir>")

# ---------------------------------------------------------------------------
# _create_installer_bundle <username> <bundle_dir>
#
# Assembles a self-contained installer zip for a user, uploads it to S3,
# and prints a 72-hour pre-signed download URL to stdout.
#
# Arguments:
#   username   — the new user's username
#   bundle_dir — directory containing: user.env, aws-config, and optionally fre-claude
# ---------------------------------------------------------------------------
_create_installer_bundle() {
  local username="$1"
  local bundle_dir="$2"
  local tmp_dir
  tmp_dir=$(mktemp -d)

  # Populate bundle structure
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
  cp "${bundle_dir}/user.env"        "${tmp_dir}/config/user.env"

  mkdir -p "${tmp_dir}/credentials"
  cp "${bundle_dir}/aws-config"      "${tmp_dir}/credentials/aws-config"
  if [[ -f "${bundle_dir}/fre-claude" ]]; then
    cp "${bundle_dir}/fre-claude"    "${tmp_dir}/credentials/fre-claude"
  fi

  # Create zip
  local zip_path="${bundle_dir}/installer.zip"
  (cd "${tmp_dir}" && zip -r "${zip_path}" . -x "*.DS_Store") >/dev/null
  rm -rf "${tmp_dir}"

  # Upload to S3
  aws s3 cp "${zip_path}" \
    "s3://${TF_BACKEND_BUCKET}/${PROJECT_NAME}/installers/${username}/latest.zip" \
    --region "${TF_BACKEND_REGION}" --profile "${AWS_PROFILE}" >/dev/null

  # Return pre-signed URL (72-hour expiry)
  aws s3 presign \
    "s3://${TF_BACKEND_BUCKET}/${PROJECT_NAME}/installers/${username}/latest.zip" \
    --region "${TF_BACKEND_REGION}" --profile "${AWS_PROFILE}" \
    --expires-in 259200
}
