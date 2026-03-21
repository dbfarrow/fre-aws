#!/usr/bin/env bash
# app-link.sh — Shared function for generating signed browser app magic links.
#
# Source this file from scripts that need to generate app link URLs.
# Requires: PROJECT_NAME, AWS_REGION, AWS_PROFILE, WEB_APP_URL (from admin.env)

# _generate_app_link_url <username>
# Fetches the HMAC secret from SSM and generates a 72-hour signed token URL.
# Prints the full app URL to stdout. Returns 1 on failure.
_generate_app_link_url() {
  local username="$1"
  local hmac_param_path="/${PROJECT_NAME}/app/hmac-secret"
  local secret
  secret=$(aws ssm get-parameter --name "${hmac_param_path}" --with-decryption \
    --query "Parameter.Value" --output text \
    --region "${AWS_REGION}" --profile "${AWS_PROFILE}" 2>/dev/null || echo "")
  if [[ -z "${secret}" ]]; then
    echo "ERROR: Could not read HMAC secret from SSM (${hmac_param_path})." >&2
    echo "       Ensure the web app is deployed: ENABLE_WEB_APP=true, then ./admin.sh up" >&2
    return 1
  fi
  local expiry payload hmac_hex token
  expiry=$(( $(date +%s) + 259200 ))
  payload="${username}:${expiry}"
  hmac_hex=$(printf '%s' "${payload}" | openssl dgst -sha256 -hmac "${secret}" -hex | awk '{print $NF}')
  token=$(printf '%s' "${payload}:${hmac_hex}" | base64 | tr '+/' '-_' | tr -d '=' | tr -d '\n')
  echo "${WEB_APP_URL%/}?token=${token}"
}
