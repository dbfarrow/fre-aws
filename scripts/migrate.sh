#!/usr/bin/env bash
# migrate.sh — Blue-green instance migration.
#
# Usage (invoked via run.sh dispatch):
#   admin.sh migrate <username>         # test run: provision spare, restore, leave spare running
#   admin.sh migrate <username> --live  # live run: provision spare (or find existing), validate, promote
#
# Test run leaves dave-spare running for the operator to validate.
# Run with --live to promote dave-spare → dave, or 'admin.sh down dave-spare' to abandon.
#
# Environment variables (injected by run.sh):
#   DEV_USERNAME          target user (e.g. "dave")
#   MIGRATE_LIVE          "true" if --live was passed
#   VAULT_HOST_DIR        container path of local vault mount (e.g. /vault)
#   GIT_CONFIG_FILE       container path of host ~/.gitconfig (e.g. /host-gitconfig), optional
#   AWS_PROFILE           AWS profile for CLI calls
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_BASE_DIR="${SCRIPT_DIR}/../terraform"
TF_USER_DIR="${SCRIPT_DIR}/../terraform/user"

# ---------------------------------------------------------------------------
# Config loading (mirrors refresh.sh pattern)
# ---------------------------------------------------------------------------
_CALLER_PROFILE="${AWS_PROFILE:-}"
if [[ -f "${SCRIPT_DIR}/../config/user.env" ]]; then
  source "${SCRIPT_DIR}/../config/user.env"
elif [[ -f "${SCRIPT_DIR}/../config/admin.env" ]]; then
  source "${SCRIPT_DIR}/../config/admin.env"
else
  echo "ERROR: No config found. Expected config/user.env or config/admin.env." >&2
  exit 1
fi
source "${SCRIPT_DIR}/../config/backend.env" 2>/dev/null || true
[[ -n "${_CALLER_PROFILE}" ]] && AWS_PROFILE="${_CALLER_PROFILE}"

: "${AWS_REGION:?}" "${PROJECT_NAME:?}" "${TF_BACKEND_BUCKET:?}" "${TF_BACKEND_REGION:?}"

source "${SCRIPT_DIR}/users-s3.sh"

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
DEV_USERNAME="${DEV_USERNAME:-}"
if [[ -z "${DEV_USERNAME}" ]]; then
  echo "ERROR: DEV_USERNAME not set." >&2
  exit 1
fi

MIGRATE_LIVE="${MIGRATE_LIVE:-false}"
SPARE_USER="${DEV_USERNAME}-spare"
VAULT_HOST_DIR="${VAULT_HOST_DIR:-/vault}"
VAULT_DIR="${VAULT_HOST_DIR}/${DEV_USERNAME}"

VAULT_CREDENTIAL_PATHS=(
  ".claude"
  ".config/gh"
  ".config/atlassian-cli"
  ".atlassian-cli"
  ".jira.d"
  ".config/jira"
  ".atlcli"
  "acli-private.properties"
)

# Build tar exclude args from vault paths (used in step_backup_home)
TAR_EXCLUDES=(--exclude=./repos)
for _cp in "${VAULT_CREDENTIAL_PATHS[@]}"; do
  TAR_EXCLUDES+=(--exclude="./${_cp}")
done

# ---------------------------------------------------------------------------
# Export AWS credentials for Terraform (SSO tokens not usable by Terraform directly)
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
# Helpers
# ---------------------------------------------------------------------------

_get_instance_id() {
  local username="$1"
  local id
  id=$(aws ec2 describe-instances \
    --filters \
      "Name=tag:Username,Values=${username}" \
      "Name=tag:ProjectName,Values=${PROJECT_NAME}" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --region "${AWS_REGION}" \
    --output text 2>/dev/null || true)
  # describe-instances returns "None" when no match
  [[ "${id}" == "None" ]] && echo "" || echo "${id}"
}

_get_instance_state() {
  local instance_id="$1"
  aws ec2 describe-instances \
    --instance-ids "${instance_id}" \
    --region "${AWS_REGION}" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "unknown"
}

_get_launch_time() {
  local instance_id="$1"
  aws ec2 describe-instances \
    --instance-ids "${instance_id}" \
    --region "${AWS_REGION}" \
    --query 'Reservations[0].Instances[0].LaunchTime' \
    --output text 2>/dev/null || echo "unknown"
}

# Ensure instance is running; starts it if stopped (mirrors connect.sh lines 67-116).
_ensure_running() {
  local username="$1"
  local instance_id
  instance_id=$(_get_instance_id "${username}")

  if [[ -z "${instance_id}" ]]; then
    echo "ERROR: No instance found for '${username}'. Has 'admin.sh up ${username}' been run?" >&2
    exit 1
  fi

  local state
  state=$(_get_instance_state "${instance_id}")

  if [[ "${state}" != "running" ]]; then
    if [[ "${state}" == "stopped" ]]; then
      read -r -p "Instance '${username}' is stopped. Start it now? [y/N] " _sc
      if [[ ! "${_sc}" =~ ^[Yy]$ ]]; then echo "Aborted."; exit 0; fi
      echo "Starting ${instance_id}..."
      aws ec2 start-instances --instance-ids "${instance_id}" --region "${AWS_REGION}" > /dev/null
      echo "Waiting for instance to be running..."
      aws ec2 wait instance-running --instance-ids "${instance_id}" --region "${AWS_REGION}"
      _wait_for_ssm "${instance_id}" 24 5
    elif [[ "${state}" == "pending" ]]; then
      echo "Instance '${username}' is starting up, waiting..."
      aws ec2 wait instance-running --instance-ids "${instance_id}" --region "${AWS_REGION}"
    elif [[ "${state}" == "stopping" ]]; then
      echo "ERROR: Instance '${username}' is currently stopping. Try again in a moment." >&2
      exit 1
    else
      echo "ERROR: Instance '${username}' is in state '${state}' — cannot proceed." >&2
      exit 1
    fi
  fi

  echo "${instance_id}"
}

# Poll SSM until online. Args: instance_id max_attempts sleep_secs
_wait_for_ssm() {
  local instance_id="$1"
  local max_attempts="${2:-36}"
  local sleep_secs="${3:-10}"
  local i _ping
  echo "--- waiting for SSM agent on ${instance_id} ---"
  for i in $(seq 1 "${max_attempts}"); do
    _ping=$(aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=${instance_id}" \
      --query 'InstanceInformationList[0].PingStatus' \
      --region "${AWS_REGION}" \
      --output text 2>/dev/null || true)
    if [[ "${_ping}" == "Online" ]]; then
      echo "  SSM agent online."
      return 0
    fi
    echo "  Attempt ${i}/${max_attempts}: not ready yet (${_ping:-no response})..."
    sleep "${sleep_secs}"
  done
  echo "WARNING: SSM agent not responding after $((max_attempts * sleep_secs))s." >&2
  return 1
}

# Build SSH opts array for a given instance ID (mirrors connect.sh)
_build_ssh_opts() {
  local instance_id="$1"
  SSH_OPTS=(
    "-o" "StrictHostKeyChecking=no"
    "-o" "UserKnownHostsFile=/dev/null"
    "-o" "LogLevel=ERROR"
    "-o" "ProxyCommand=aws ssm start-session --target ${instance_id} --document-name AWS-StartSSHSession --parameters portNumber=22 --region ${AWS_REGION}"
  )
  if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
    SSH_OPTS+=("-A")
  elif [[ -n "${SSH_KEY_FILE:-}" ]]; then
    SSH_OPTS+=("-i" "${SSH_KEY_FILE}")
  fi
}

# Build a temporary SSH wrapper script for use with rsync -e
_build_ssh_wrapper() {
  local instance_id="$1"
  _build_ssh_opts "${instance_id}"
  local wrapper
  wrapper=$(mktemp)
  chmod 700 "${wrapper}"
  { echo '#!/bin/sh'; printf 'exec ssh'; printf ' %q' "${SSH_OPTS[@]}"; printf ' "$@"\n'; } > "${wrapper}"
  echo "${wrapper}"
}

# Read base Terraform outputs (subnet, sg, public IP flag). Requires base state to be init'd.
_read_base_outputs() {
  local base_outputs
  base_outputs=$(terraform -chdir="${TF_BASE_DIR}" output -json 2>/dev/null)
  SUBNET_ID=$(echo "${base_outputs}"         | jq -r '.subnet_id.value')
  ASSOC_PUBLIC_IP=$(echo "${base_outputs}"   | jq -r '.associate_public_ip.value')
  SECURITY_GROUP_ID=$(echo "${base_outputs}" | jq -r '.security_group_id.value')
}

# Init base Terraform state (read-only — just to read outputs)
_init_base() {
  local BASE_KEY="${PROJECT_NAME}/base/terraform.tfstate"
  terraform -chdir="${TF_BASE_DIR}" init -reconfigure \
    -backend-config="bucket=${TF_BACKEND_BUCKET}" \
    -backend-config="key=${BASE_KEY}" \
    -backend-config="region=${TF_BACKEND_REGION}" \
    > /dev/null 2>&1
}

# Init per-user Terraform state
_init_user() {
  local username="$1"
  local USER_KEY="${PROJECT_NAME}/users/${username}/terraform.tfstate"
  terraform -chdir="${TF_USER_DIR}" init -reconfigure \
    -backend-config="bucket=${TF_BACKEND_BUCKET}" \
    -backend-config="key=${USER_KEY}" \
    -backend-config="region=${TF_BACKEND_REGION}" \
    > /dev/null 2>&1
}

# Common terraform variable args for a user (reads from users_json)
_user_tf_vars() {
  local username="$1"
  local users_json="$2"
  local ssh_public_key git_user_name git_user_email preferred_shell
  ssh_public_key=$(jq -r --arg u "${username}" '.[$u].ssh_public_key'          "${users_json}")
  git_user_name=$(jq -r  --arg u "${username}" '.[$u].git_user_name'            "${users_json}")
  git_user_email=$(jq -r --arg u "${username}" '.[$u].git_user_email'           "${users_json}")
  preferred_shell=$(jq -r --arg u "${username}" '.[$u].preferred_shell // "bash"' "${users_json}")

  USER_TF_VARS=(
    -var="username=${username}"
    -var="ssh_public_key=${ssh_public_key}"
    -var="git_user_name=${git_user_name}"
    -var="git_user_email=${git_user_email}"
    -var="preferred_shell=${preferred_shell}"
    -var="project_name=${PROJECT_NAME}"
    -var="aws_region=${AWS_REGION}"
    -var="instance_type=${INSTANCE_TYPE:-t3.micro}"
    -var="use_spot=${USE_SPOT:-false}"
    -var="ebs_volume_size_gb=${EBS_VOLUME_SIZE_GB:-30}"
    -var="owner_email=${OWNER_EMAIL:-}"
    -var="subnet_id=${SUBNET_ID}"
    -var="associate_public_ip=${ASSOC_PUBLIC_IP}"
    -var="security_group_id=${SECURITY_GROUP_ID}"
    -var="autoshutdown_idle_minutes=${AUTOSHUTDOWN_IDLE_MINUTES:-30}"
  )
}

# ---------------------------------------------------------------------------
# Step functions
# ---------------------------------------------------------------------------

step_check_dirty() {
  local instance_id="$1"
  _build_ssh_opts "${instance_id}"
  echo "--- checking for uncommitted/unpushed git changes ---"
  local dirty_repos=""
  dirty_repos=$(ssh "${SSH_OPTS[@]}" developer@"${instance_id}" '
    shopt -s nullglob 2>/dev/null || true
    for repo in ~/repos/*/; do
      [[ -d "${repo}/.git" ]] || continue
      cd "${repo}" || continue
      uncommitted=$(git status --porcelain 2>/dev/null | wc -l | tr -d " ")
      unpushed=$(git log --branches --not --remotes --oneline 2>/dev/null | wc -l | tr -d " ")
      if [[ "${uncommitted}" -gt 0 || "${unpushed}" -gt 0 ]]; then
        echo "  ${repo}: uncommitted=${uncommitted} unpushed=${unpushed}"
      fi
    done
  ' 2>/dev/null || true)

  if [[ -n "${dirty_repos}" ]]; then
    echo ""
    echo "  WARNING: dirty repositories found on ${DEV_USERNAME}:"
    echo "${dirty_repos}"
    echo ""
    read -r -p "  Continue anyway? Changes will not be in the migrated environment. [y/N] " _dc
    if [[ ! "${_dc}" =~ ^[Yy]$ ]]; then
      echo "Aborted. Commit or push changes before migrating."
      exit 0
    fi
  else
    echo "  All repos clean."
  fi
}

step_extract_vault() {
  local instance_id="$1"
  echo "--- extracting credentials to local vault ---"
  mkdir -p "${VAULT_DIR}"
  chmod 700 "${VAULT_DIR}"

  local wrapper extracted=0
  wrapper=$(_build_ssh_wrapper "${instance_id}")
  trap 'rm -f "${wrapper}"' RETURN
  _build_ssh_opts "${instance_id}"

  for cred_path in "${VAULT_CREDENTIAL_PATHS[@]}"; do
    if ssh "${SSH_OPTS[@]}" developer@"${instance_id}" "test -e ~/${cred_path}" 2>/dev/null; then
      echo "  extracting ~/${cred_path}"
      mkdir -p "${VAULT_DIR}/$(dirname "${cred_path}")"
      rsync -az --delete \
        -e "${wrapper}" \
        developer@"${instance_id}":~/"${cred_path}" \
        "${VAULT_DIR}/${cred_path}" 2>/dev/null
      chmod -R go-rwx "${VAULT_DIR}/${cred_path}" 2>/dev/null || true
      extracted=$((extracted + 1))
    else
      echo "  skipping (not found): ~/${cred_path}"
    fi
  done
  echo "  ${extracted} credential path(s) extracted to ${VAULT_DIR}"
}

step_backup_home() {
  local instance_id="$1"
  local backup_key="${PROJECT_NAME}/users/${DEV_USERNAME}/home-backup.tar.gz"
  local backup_prev_key="${PROJECT_NAME}/users/${DEV_USERNAME}/home-backup.prev.tar.gz"
  _build_ssh_opts "${instance_id}"

  echo "--- rotating previous backup (if any) ---"
  aws s3 cp \
    "s3://${TF_BACKEND_BUCKET}/${backup_key}" \
    "s3://${TF_BACKEND_BUCKET}/${backup_prev_key}" \
    --region "${TF_BACKEND_REGION}" 2>/dev/null || true

  echo "--- streaming home dir backup to S3 (excluding repos and credentials) ---"
  # Stream tar from instance directly into S3 — no local intermediate file
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" developer@"${instance_id}" \
    "cd ~ && tar czf - $(printf '%q ' "${TAR_EXCLUDES[@]}") . 2>/dev/null" \
    | aws s3 cp - \
        "s3://${TF_BACKEND_BUCKET}/${backup_key}" \
        --region "${TF_BACKEND_REGION}"

  echo "  Backup uploaded: s3://${TF_BACKEND_BUCKET}/${backup_key}"
}

step_create_spare_registry() {
  local users_json="$1"
  echo "--- creating ${SPARE_USER} registry entry ---"
  if jq -e --arg u "${SPARE_USER}" '.[$u]' "${users_json}" > /dev/null 2>&1; then
    echo "  (overwriting existing ${SPARE_USER} registry entry)"
  fi
  jq --arg src "${DEV_USERNAME}" --arg dst "${SPARE_USER}" \
    '.[$dst] = .[$src]' \
    "${users_json}" > "${users_json}.tmp"
  mv "${users_json}.tmp" "${users_json}"
  users_s3_upload "${users_json}"
  echo "  Registry entry created for ${SPARE_USER}."
}

step_provision_spare() {
  local users_json="$1"
  echo "--- provisioning ${SPARE_USER} ---"
  _init_base
  _read_base_outputs
  _init_user "${SPARE_USER}"
  _user_tf_vars "${SPARE_USER}" "${users_json}"
  terraform -chdir="${TF_USER_DIR}" apply -auto-approve \
    "${USER_TF_VARS[@]}" \
    -var="ami_id="
  SPARE_INSTANCE_ID=$(terraform -chdir="${TF_USER_DIR}" output -raw instance_id 2>/dev/null)
  echo "  Spare instance: ${SPARE_INSTANCE_ID}"

  echo "--- waiting for spare instance to be running ---"
  aws ec2 wait instance-running \
    --instance-ids "${SPARE_INSTANCE_ID}" \
    --region "${AWS_REGION}"

  # New instances run cloud-init before SSM agent starts — use longer timeout
  _wait_for_ssm "${SPARE_INSTANCE_ID}" 36 10
  # Brief pause for SSH daemon to finish initializing after SSM comes online
  sleep 5
}

step_restore_home() {
  local spare_instance_id="$1"
  local backup_key="${PROJECT_NAME}/users/${DEV_USERNAME}/home-backup.tar.gz"
  _build_ssh_opts "${spare_instance_id}"
  echo "--- restoring home backup to ${SPARE_USER} ---"
  aws s3 cp \
    "s3://${TF_BACKEND_BUCKET}/${backup_key}" \
    - \
    --region "${TF_BACKEND_REGION}" \
    | ssh "${SSH_OPTS[@]}" developer@"${spare_instance_id}" \
        "cd ~ && tar xzf - 2>/dev/null || true"
  echo "  Home directory restored."
}

step_restore_vault() {
  local spare_instance_id="$1"
  echo "--- restoring credentials from vault to ${SPARE_USER} ---"
  if [[ ! -d "${VAULT_DIR}" ]]; then
    echo "  No local vault found — skipping credential restore."
    return 0
  fi

  local wrapper
  wrapper=$(_build_ssh_wrapper "${spare_instance_id}")
  trap 'rm -f "${wrapper}"' RETURN
  _build_ssh_opts "${spare_instance_id}"

  for cred_path in "${VAULT_CREDENTIAL_PATHS[@]}"; do
    if [[ -e "${VAULT_DIR}/${cred_path}" ]]; then
      echo "  restoring ~/${cred_path}"
      local parent_dir
      parent_dir=$(dirname "${cred_path}")
      ssh "${SSH_OPTS[@]}" developer@"${spare_instance_id}" \
        "mkdir -p ~/${parent_dir}" 2>/dev/null || true
      rsync -az \
        -e "${wrapper}" \
        "${VAULT_DIR}/${cred_path}" \
        developer@"${spare_instance_id}":~/"${cred_path}" 2>/dev/null
    fi
  done
  echo "  Credentials restored."
}

step_push_gitconfig() {
  local spare_instance_id="$1"
  local gitconfig_file="${GIT_CONFIG_FILE:-/host-gitconfig}"
  _build_ssh_opts "${spare_instance_id}"
  if [[ ! -f "${gitconfig_file}" ]]; then
    echo "  (no ~/.gitconfig found on host — skipping)"
    return 0
  fi
  echo "--- pushing .gitconfig to ${SPARE_USER} ---"
  ssh "${SSH_OPTS[@]}" developer@"${spare_instance_id}" \
    "tee ~/.gitconfig > /dev/null" < "${gitconfig_file}"
  echo "  .gitconfig pushed."
}

# ---------------------------------------------------------------------------
# Provisioning sequence (steps 1-8): used by both test and live runs
# ---------------------------------------------------------------------------
run_provision_sequence() {
  local users_json="$1"

  ORIG_INSTANCE_ID=$(_ensure_running "${DEV_USERNAME}")

  step_check_dirty    "${ORIG_INSTANCE_ID}"
  step_extract_vault  "${ORIG_INSTANCE_ID}"
  step_backup_home    "${ORIG_INSTANCE_ID}"
  step_create_spare_registry "${users_json}"
  step_provision_spare       "${users_json}"
  step_restore_home   "${SPARE_INSTANCE_ID}"
  step_restore_vault  "${SPARE_INSTANCE_ID}"
  step_push_gitconfig "${SPARE_INSTANCE_ID}"
}

# ---------------------------------------------------------------------------
# Promotion: dave-spare → dave
# ---------------------------------------------------------------------------
do_promote() {
  local users_json="$1"
  local spare_instance_id="$2"
  echo ""
  echo "=== Promoting ${SPARE_USER} → ${DEV_USERNAME} ==="

  # Safety net: back up original dave state before destroying it
  local orig_key="${PROJECT_NAME}/users/${DEV_USERNAME}/terraform.tfstate"
  local spare_key="${PROJECT_NAME}/users/${SPARE_USER}/terraform.tfstate"
  local backup_key="${PROJECT_NAME}/users/${DEV_USERNAME}/terraform.tfstate.migrate-backup"

  echo "--- backing up original Terraform state (recovery safety net) ---"
  aws s3 cp \
    "s3://${TF_BACKEND_BUCKET}/${orig_key}" \
    "s3://${TF_BACKEND_BUCKET}/${backup_key}" \
    --region "${TF_BACKEND_REGION}" 2>/dev/null || true

  # P1: Destroy original dave
  echo "--- destroying original ${DEV_USERNAME} instance ---"
  _init_base
  _read_base_outputs
  _init_user "${DEV_USERNAME}"
  _user_tf_vars "${DEV_USERNAME}" "${users_json}"
  terraform -chdir="${TF_USER_DIR}" destroy -auto-approve "${USER_TF_VARS[@]}"

  # P2: Move spare state to dave state path
  echo "--- copying spare Terraform state to ${DEV_USERNAME} state path ---"
  aws s3 cp \
    "s3://${TF_BACKEND_BUCKET}/${spare_key}" \
    "s3://${TF_BACKEND_BUCKET}/${orig_key}" \
    --region "${TF_BACKEND_REGION}"

  # P3: Apply with dave's variables to rename IAM role/profile and update tags.
  # The EC2 instance stays running; only IAM resources are recreated.
  echo "--- renaming IAM resources and tags to ${DEV_USERNAME} (instance stays running) ---"
  _init_user "${DEV_USERNAME}"
  _user_tf_vars "${DEV_USERNAME}" "${users_json}"
  terraform -chdir="${TF_USER_DIR}" apply -auto-approve \
    "${USER_TF_VARS[@]}" \
    -var="ami_id="

  # P4: Remove spare from registry
  echo "--- removing ${SPARE_USER} from registry ---"
  jq --arg u "${SPARE_USER}" 'del(.[$u])' "${users_json}" > "${users_json}.tmp"
  mv "${users_json}.tmp" "${users_json}"
  users_s3_upload "${users_json}"

  # P5: Delete spare Terraform state
  echo "--- deleting ${SPARE_USER} Terraform state ---"
  aws s3 rm \
    "s3://${TF_BACKEND_BUCKET}/${spare_key}" \
    --region "${TF_BACKEND_REGION}" 2>/dev/null || true

  # P6: Delete Terraform state safety net backup
  aws s3 rm \
    "s3://${TF_BACKEND_BUCKET}/${backup_key}" \
    --region "${TF_BACKEND_REGION}" 2>/dev/null || true

  # P7: Delete local vault
  if [[ -d "${VAULT_DIR}" ]]; then
    rm -rf "${VAULT_DIR}"
    echo "  Local vault deleted."
  fi

  # P8: Delete S3 home backup
  aws s3 rm \
    "s3://${TF_BACKEND_BUCKET}/${PROJECT_NAME}/users/${DEV_USERNAME}/home-backup.tar.gz" \
    --region "${TF_BACKEND_REGION}" 2>/dev/null || true
  aws s3 rm \
    "s3://${TF_BACKEND_BUCKET}/${PROJECT_NAME}/users/${DEV_USERNAME}/home-backup.prev.tar.gz" \
    --region "${TF_BACKEND_REGION}" 2>/dev/null || true

  echo ""
  echo "=== Migration complete. ${DEV_USERNAME} is now running on new infrastructure. ==="
  echo "    Connect: ./admin.sh connect ${DEV_USERNAME}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
USERS_JSON=$(mktemp)
trap 'rm -f "${USERS_JSON}"' EXIT

users_s3_download "${USERS_JSON}"

# Validate source user exists in registry
if ! jq -e --arg u "${DEV_USERNAME}" '.[$u]' "${USERS_JSON}" > /dev/null 2>&1; then
  echo "ERROR: User '${DEV_USERNAME}' not found in registry." >&2
  exit 1
fi

if [[ "${MIGRATE_LIVE}" == "true" ]]; then
  # --- Live run ---
  SPARE_INSTANCE_ID=$(_get_instance_id "${SPARE_USER}")

  if [[ -n "${SPARE_INSTANCE_ID}" ]]; then
    # Spare already exists from a prior test run — go straight to promotion
    LAUNCH_TIME=$(_get_launch_time "${SPARE_INSTANCE_ID}")
    echo ""
    echo "  ${SPARE_USER} already exists (provisioned ${LAUNCH_TIME})."
    echo "  Any changes to ${DEV_USERNAME} since then will not be in the migrated environment."
    echo ""
    read -r -p "  Promote ${SPARE_USER} → ${DEV_USERNAME} now? [y/N] " _lc
    if [[ ! "${_lc}" =~ ^[Yy]$ ]]; then
      echo "Aborted. ${SPARE_USER} is still running."
      echo "  To abandon: admin.sh down ${SPARE_USER}"
      exit 0
    fi
    do_promote "${USERS_JSON}" "${SPARE_INSTANCE_ID}"
  else
    # No spare — run full provision sequence then promote
    run_provision_sequence "${USERS_JSON}"
    echo ""
    echo "  ${SPARE_USER} is ready."
    echo "  Connect to validate: admin.sh connect ${SPARE_USER}"
    echo ""
    read -r -p "  Press Enter to promote ${SPARE_USER} → ${DEV_USERNAME} (Ctrl+C to abort)..." _
    do_promote "${USERS_JSON}" "${SPARE_INSTANCE_ID}"
  fi

else
  # --- Test run ---
  SPARE_INSTANCE_ID=$(_get_instance_id "${SPARE_USER}")

  if [[ -n "${SPARE_INSTANCE_ID}" ]]; then
    LAUNCH_TIME=$(_get_launch_time "${SPARE_INSTANCE_ID}")
    echo ""
    echo "  ${SPARE_USER} is already running (provisioned ${LAUNCH_TIME})."
    echo ""
    echo "  To promote:  admin.sh migrate ${DEV_USERNAME} --live"
    echo "  To abandon:  admin.sh down ${SPARE_USER}"
    exit 0
  fi

  run_provision_sequence "${USERS_JSON}"

  echo ""
  echo "=== Test migration complete. ${DEV_USERNAME} is untouched. ==="
  echo ""
  echo "  ${SPARE_USER} is running with your migrated environment."
  echo "  Connect to validate:  admin.sh connect ${SPARE_USER}"
  echo "  When satisfied:       admin.sh migrate ${DEV_USERNAME} --live"
  echo "  To abandon:           admin.sh down ${SPARE_USER}"
  echo ""
fi
