#!/usr/bin/env bash
# update.sh — Download and apply the latest installer bundle from S3.
# Runs inside Docker. The host ~/fre-aws/ directory is mounted at
# /workspace/fre-aws via "docker run --volume ~/fre-aws:/workspace/fre-aws".
# Updated scripts are written back to the host through that mount.
set -euo pipefail

CONFIG_FILE="/workspace/config/user.env"

# ---------------------------------------------------------------------------
# Load user config
# ---------------------------------------------------------------------------
if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: Config file not found: ${CONFIG_FILE}" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

: "${MY_USERNAME:?MY_USERNAME must be set in config/user.env}"
: "${PROJECT_NAME:?PROJECT_NAME must be set in config/user.env}"
: "${AWS_PROFILE:?AWS_PROFILE must be set in config/user.env}"
: "${TF_BACKEND_BUCKET:?TF_BACKEND_BUCKET must be set in config/user.env}"

# ---------------------------------------------------------------------------
# Download latest bundle from S3
# ---------------------------------------------------------------------------
S3_KEY="${PROJECT_NAME}/installers/${MY_USERNAME}/latest.zip"
DEST="/workspace/fre-aws"

echo "Downloading latest update for '${MY_USERNAME}'..."

aws s3 cp "s3://${TF_BACKEND_BUCKET}/${S3_KEY}" /tmp/update.zip \
  --profile "${AWS_PROFILE}" 2>&1 || {
  echo "" >&2
  echo "ERROR: Could not download update from S3." >&2
  echo "       Make sure your AWS session is active: ~/fre-aws/user.sh sso-login" >&2
  exit 1
}

echo "  Downloaded s3://${TF_BACKEND_BUCKET}/${S3_KEY}"

# ---------------------------------------------------------------------------
# Apply update — extract only scripts/ into the install directory
# ---------------------------------------------------------------------------
if [[ ! -d "${DEST}" ]]; then
  echo "ERROR: Install directory not found: ${DEST}" >&2
  echo "       Expected ~/fre-aws to be mounted at /workspace/fre-aws" >&2
  exit 1
fi

echo "Applying update..."
unzip -o /tmp/update.zip "scripts/*" -d "${DEST}" >/dev/null
chmod +x "${DEST}"/scripts/*.sh
rm -f /tmp/update.zip

echo "  Scripts updated in ~/fre-aws/scripts/"
echo ""
echo "Update complete."
