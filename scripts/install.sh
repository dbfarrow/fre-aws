#!/usr/bin/env bash
# install.sh — One-time installer for the fre-aws user bundle.
# Run from the unpacked installer directory:
#   bash install.sh
#
# What this script does:
#   1. Checks Docker is installed
#   2. Warns if ~/fre-aws/ already exists, prompts to overwrite
#   3. Copies user.sh, Dockerfile, scripts/, config/ into ~/fre-aws/
#   4. Copies credentials/fre-claude → ~/.ssh/fre-claude (chmod 600) if present
#   5. Backs up and replaces ~/.aws/config with credentials/aws-config
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/fre-aws"

# ---------------------------------------------------------------------------
# Step 1 — Check Docker
# ---------------------------------------------------------------------------
echo "Checking for Docker..."
if ! command -v docker &>/dev/null; then
  echo ""
  echo "ERROR: Docker is not installed." >&2
  echo ""
  echo "Install one of the following container runtimes, then re-run this script:" >&2
  echo "  Docker Desktop  — https://www.docker.com/products/docker-desktop/" >&2
  echo "  OrbStack        — https://orbstack.dev" >&2
  echo "  Rancher Desktop — https://rancherdesktop.io" >&2
  exit 1
fi
echo "  Docker found: $(docker --version)"
echo ""

# ---------------------------------------------------------------------------
# Step 2 — Check for existing installation
# ---------------------------------------------------------------------------
if [[ -d "${INSTALL_DIR}" ]]; then
  echo "WARNING: ${INSTALL_DIR} already exists."
  read -r -p "Overwrite it? [Y/n]: " OVERWRITE
  OVERWRITE="${OVERWRITE:-Y}"
  if [[ ! "${OVERWRITE}" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
  fi
  echo ""
fi

# ---------------------------------------------------------------------------
# Step 3 — Create ~/fre-aws directory structure and copy files
# ---------------------------------------------------------------------------
echo "Installing to ${INSTALL_DIR}..."

mkdir -p "${INSTALL_DIR}/scripts" "${INSTALL_DIR}/config"

# user.sh entry point
cp "${BUNDLE_DIR}/user.sh" "${INSTALL_DIR}/user.sh"
chmod +x "${INSTALL_DIR}/user.sh"

# Dockerfile (needed to build the Docker image)
cp "${BUNDLE_DIR}/Dockerfile" "${INSTALL_DIR}/Dockerfile"

# All scripts
for script in "${BUNDLE_DIR}/scripts/"*.sh; do
  cp "${script}" "${INSTALL_DIR}/scripts/"
  chmod +x "${INSTALL_DIR}/scripts/$(basename "${script}")"
done

# User config
cp "${BUNDLE_DIR}/config/user.env" "${INSTALL_DIR}/config/user.env"

echo "  Files copied to ${INSTALL_DIR}/"

# ---------------------------------------------------------------------------
# Step 4 — SSH key (if included in bundle)
# ---------------------------------------------------------------------------
if [[ -f "${BUNDLE_DIR}/credentials/fre-claude" ]]; then
  echo ""
  echo "Installing SSH key..."
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  cp "${BUNDLE_DIR}/credentials/fre-claude" "${HOME}/.ssh/fre-claude"
  chmod 600 "${HOME}/.ssh/fre-claude"
  echo "  SSH key installed: ~/.ssh/fre-claude"
  echo ""
  echo "  Add this key to your GitHub account so git push/pull works from your instance:"
  echo "    1. Copy the public key: ssh-keygen -y -f ~/.ssh/fre-claude | pbcopy"
  echo "    2. GitHub: Settings → SSH and GPG keys → New SSH key → paste it"
fi

# ---------------------------------------------------------------------------
# Step 5 — AWS config
# ---------------------------------------------------------------------------
echo ""
echo "Installing AWS config..."
mkdir -p "${HOME}/.aws"

if [[ -f "${HOME}/.aws/config" ]]; then
  BACKUP="${HOME}/.aws/config.backup-$(date +%Y%m%d%H%M%S)"
  cp "${HOME}/.aws/config" "${BACKUP}"
  echo "  Existing ~/.aws/config backed up to: ${BACKUP}"
fi

cp "${BUNDLE_DIR}/credentials/aws-config" "${HOME}/.aws/config"
chmod 600 "${HOME}/.aws/config"
echo "  AWS config installed: ~/.aws/config"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "================================================"
echo " Setup complete!"
echo "================================================"
echo ""
echo "Next steps:"
echo ""
echo "  1. Activate your AWS account (if you haven't already):"
echo "     Your admin will provide the SSO portal URL and instructions."
echo ""
echo "  2. Log in to AWS (once per day when your session expires):"
echo "     ~/fre-aws/user.sh sso-login"
echo ""
echo "  3. Connect to your instance:"
echo "     ~/fre-aws/user.sh connect"
echo ""
echo "For help: ~/fre-aws/user.sh --help"
