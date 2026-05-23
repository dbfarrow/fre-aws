#!/usr/bin/env bash
# migrate.sh — Blue-green instance migration using a persistent EBS data volume.
#
# Usage (invoked via run.sh dispatch):
#   admin.sh migrate <username>         # test run: provision spare, leave spare running for validation
#   admin.sh migrate <username> --live  # live run: provision spare (or find existing), validate, promote
#
# Test run leaves dave-spare running for the operator to validate.
# Run with --live to promote dave-spare → dave, or 'admin.sh down dave-spare' to abandon.
#
# Two flows depending on whether a data volume already exists for the user:
#   Initial adoption: user has no data volume yet — creates one, populates it from the
#                     running instance via rsync, then provisions a spare against it.
#                     Original instance stays running and untouched until promotion.
#   Steady-state:     data volume already exists — stops original, detaches, provisions
#                     spare with volume attached, validates, promotes.
#
# Environment variables (injected by run.sh):
#   DEV_USERNAME          target user (e.g. "dave")
#   MIGRATE_LIVE          "true" if --live was passed
#   AWS_PROFILE           AWS profile for CLI calls
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_BASE_DIR="${SCRIPT_DIR}/../terraform"
TF_USER_DIR="${SCRIPT_DIR}/../terraform/user"
TF_USER_DATA_DIR="${SCRIPT_DIR}/../terraform/user-data"

# ---------------------------------------------------------------------------
# Config loading
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

# ---------------------------------------------------------------------------
# Export AWS credentials for Terraform
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
# Helpers — EC2 instance queries
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

_ensure_running() {
  local username="$1"
  local instance_id
  instance_id=$(_get_instance_id "${username}")

  if [[ -z "${instance_id}" ]]; then
    echo "ERROR: No instance found for '${username}'." >&2
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
      aws ec2 wait instance-running --instance-ids "${instance_id}" --region "${AWS_REGION}"
      _wait_for_ssm "${instance_id}" 24 5
    elif [[ "${state}" == "pending" ]]; then
      echo "Instance '${username}' is starting, waiting..."
      aws ec2 wait instance-running --instance-ids "${instance_id}" --region "${AWS_REGION}"
    elif [[ "${state}" == "stopping" ]]; then
      echo "ERROR: Instance '${username}' is stopping. Try again in a moment." >&2
      exit 1
    else
      echo "ERROR: Instance '${username}' is in state '${state}'." >&2
      exit 1
    fi
  fi

  echo "${instance_id}"
}

_stop_instance() {
  local instance_id="$1"
  local label="$2"
  local state
  state=$(_get_instance_state "${instance_id}")
  if [[ "${state}" == "running" ]]; then
    echo "--- stopping ${label} (${instance_id}) ---"
    aws ec2 stop-instances --instance-ids "${instance_id}" --region "${AWS_REGION}" > /dev/null
    aws ec2 wait instance-stopped --instance-ids "${instance_id}" --region "${AWS_REGION}"
    echo "  Stopped."
  elif [[ "${state}" != "stopped" ]]; then
    echo "ERROR: Cannot stop ${label} — state is '${state}'." >&2
    exit 1
  fi
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

# Build SSH opts array for a given instance ID
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

# Read base Terraform outputs
_read_base_outputs() {
  local base_outputs
  base_outputs=$(terraform -chdir="${TF_BASE_DIR}" output -json 2>/dev/null)
  SUBNET_ID=$(echo "${base_outputs}"         | jq -r '.subnet_id.value')
  ASSOC_PUBLIC_IP=$(echo "${base_outputs}"   | jq -r '.associate_public_ip.value')
  SECURITY_GROUP_ID=$(echo "${base_outputs}" | jq -r '.security_group_id.value')
}

_init_base() {
  local BASE_KEY="${PROJECT_NAME}/base/terraform.tfstate"
  terraform -chdir="${TF_BASE_DIR}" init -reconfigure \
    -backend-config="bucket=${TF_BACKEND_BUCKET}" \
    -backend-config="key=${BASE_KEY}" \
    -backend-config="region=${TF_BACKEND_REGION}" \
    > /dev/null 2>&1
}

_init_user() {
  local username="$1"
  local USER_KEY="${PROJECT_NAME}/users/${username}/terraform.tfstate"
  terraform -chdir="${TF_USER_DIR}" init -reconfigure \
    -backend-config="bucket=${TF_BACKEND_BUCKET}" \
    -backend-config="key=${USER_KEY}" \
    -backend-config="region=${TF_BACKEND_REGION}" \
    > /dev/null 2>&1
}

_init_user_data() {
  local username="$1"
  local DATA_KEY="${PROJECT_NAME}/users/${username}/data.tfstate"
  terraform -chdir="${TF_USER_DATA_DIR}" init -reconfigure \
    -backend-config="bucket=${TF_BACKEND_BUCKET}" \
    -backend-config="key=${DATA_KEY}" \
    -backend-config="region=${TF_BACKEND_REGION}" \
    >&2
}

# Common terraform variable args for a user.
# Per-user compute fields in the registry (instance_type, use_spot, ebs_volume_size_gb,
# hibernation) take precedence over the global admin.env values when present.
_user_tf_vars() {
  local username="$1"
  local users_json="$2"
  local data_volume_id="${3:-}"

  # Identity fields
  local ssh_public_key git_user_name git_user_email preferred_shell
  ssh_public_key=$(jq -r  --arg u "${username}" '.[$u].ssh_public_key'            "${users_json}")
  git_user_name=$(jq -r   --arg u "${username}" '.[$u].git_user_name'             "${users_json}")
  git_user_email=$(jq -r  --arg u "${username}" '.[$u].git_user_email'            "${users_json}")
  preferred_shell=$(jq -r --arg u "${username}" '.[$u].preferred_shell // "bash"' "${users_json}")

  # Per-user compute overrides (registry value → global fallback)
  # Root EBS size is not per-user — it is fixed at the project-wide EBS_VOLUME_SIZE_GB.
  local eff_instance_type eff_use_spot eff_hibernation
  eff_instance_type=$(jq -r --arg u "${username}" '.[$u].instance_type // ""' "${users_json}")
  eff_instance_type="${eff_instance_type:-${INSTANCE_TYPE:-t3.micro}}"
  eff_use_spot=$(jq -r     --arg u "${username}" '.[$u].use_spot // ""'       "${users_json}")
  eff_use_spot="${eff_use_spot:-${USE_SPOT:-false}}"
  eff_hibernation=$(jq -r  --arg u "${username}" '.[$u].hibernation // ""'    "${users_json}")
  eff_hibernation="${eff_hibernation:-false}"

  if [[ "${eff_hibernation}" == "true" && "${eff_use_spot}" == "true" ]]; then
    echo "ERROR: ${username}: hibernation=true requires use_spot=false." >&2
    echo "       Set USE_SPOT=false in ${username}'s registry entry or in admin.env." >&2
    exit 1
  fi

  USER_TF_VARS=(
    -var="username=${username}"
    -var="ssh_public_key=${ssh_public_key}"
    -var="git_user_name=${git_user_name}"
    -var="git_user_email=${git_user_email}"
    -var="preferred_shell=${preferred_shell}"
    -var="project_name=${PROJECT_NAME}"
    -var="aws_region=${AWS_REGION}"
    -var="instance_type=${eff_instance_type}"
    -var="use_spot=${eff_use_spot}"
    -var="ebs_volume_size_gb=${EBS_VOLUME_SIZE_GB:-30}"
    -var="owner_email=${OWNER_EMAIL:-}"
    -var="subnet_id=${SUBNET_ID}"
    -var="associate_public_ip=${ASSOC_PUBLIC_IP}"
    -var="security_group_id=${SECURITY_GROUP_ID}"
    -var="autoshutdown_idle_minutes=${AUTOSHUTDOWN_IDLE_MINUTES:-30}"
    -var="data_volume_id=${data_volume_id}"
    -var="hibernation=${eff_hibernation}"
  )
}

# ---------------------------------------------------------------------------
# Helpers — data volume operations
# ---------------------------------------------------------------------------

# Find the data volume for a user by tags. Returns volume ID or empty string.
_get_data_volume_id() {
  local username="$1"
  local vol_id
  vol_id=$(aws ec2 describe-volumes \
    --filters \
      "Name=tag:Username,Values=${username}" \
      "Name=tag:ProjectName,Values=${PROJECT_NAME}" \
      "Name=tag:DataVolume,Values=true" \
    --query 'Volumes[0].VolumeId' \
    --region "${AWS_REGION}" \
    --output text 2>/dev/null || true)
  [[ "${vol_id}" == "None" ]] && echo "" || echo "${vol_id}"
}

# Detach a volume and wait for it to become available.
_detach_data_volume() {
  local volume_id="$1"
  local label="${2:-volume}"
  echo "--- detaching data volume ${volume_id} from ${label} ---"
  aws ec2 detach-volume \
    --volume-id "${volume_id}" \
    --region "${AWS_REGION}" > /dev/null 2>&1 || true
  echo "  Waiting for volume to become available..."
  aws ec2 wait volume-available \
    --volume-ids "${volume_id}" \
    --region "${AWS_REGION}"
  echo "  Volume available."
}

# Create a new data volume via terraform/user-data/ module.
# Returns the volume ID via stdout (call with $(...)).
_create_data_volume() {
  local username="$1"
  local subnet_id="$2"
  echo "--- creating data volume for ${username} ---" >&2
  _init_user_data "${username}"
  if ! terraform -chdir="${TF_USER_DATA_DIR}" apply -auto-approve \
    -var="username=${username}" \
    -var="project_name=${PROJECT_NAME}" \
    -var="aws_region=${AWS_REGION}" \
    -var="subnet_id=${subnet_id}" \
    -var="ebs_data_volume_size_gb=${EBS_DATA_VOLUME_SIZE_GB:-30}" \
    >&2; then
    echo "ERROR: terraform apply failed for data volume." >&2
    exit 1
  fi
  local vol_id
  vol_id=$(terraform -chdir="${TF_USER_DATA_DIR}" output -raw volume_id 2>/dev/null | grep -Eo 'vol-[0-9a-f]+')
  if [[ -z "${vol_id}" ]]; then
    echo "ERROR: Could not extract volume ID from Terraform output." >&2
    exit 1
  fi
  echo "${vol_id}"
}

# Attach a volume to an instance (temporary, for initial rsync population).
# Device /dev/sdg is used for temporary attachments to avoid conflict with /dev/sdf.
_attach_data_volume_temp() {
  local volume_id="$1"
  local instance_id="$2"
  echo "--- attaching data volume ${volume_id} to ${instance_id} (temp) ---"
  aws ec2 attach-volume \
    --volume-id "${volume_id}" \
    --instance-id "${instance_id}" \
    --device "/dev/sdg" \
    --region "${AWS_REGION}" > /dev/null
  echo "  Waiting for volume to be in-use..."
  aws ec2 wait volume-in-use \
    --volume-ids "${volume_id}" \
    --region "${AWS_REGION}"
  sleep 5  # give the OS a moment to expose the device
  echo "  Volume attached."
}

# Populate a blank data volume by rsyncing /home/developer/ from the running instance.
# Attaches volume temporarily, SSHes in to format + rsync, then detaches.
_populate_data_volume() {
  local volume_id="$1"
  local instance_id="$2"
  local username="$3"

  _attach_data_volume_temp "${volume_id}" "${instance_id}"

  echo "--- formatting and populating data volume on ${username} ---"
  _build_ssh_opts "${instance_id}"

  # Get the NVMe serial for /dev/sdg (vol-xxx → volxxx)
  local vol_serial="${volume_id//-/}"

  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" developer@"${instance_id}" "
    set -euo pipefail
    SYMLINK=\"/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${vol_serial}\"
    DATA_DEV=\"\"
    for i in \$(seq 1 30); do
      if [[ -L \"\${SYMLINK}\" ]]; then
        DATA_DEV=\$(readlink -f \"\${SYMLINK}\")
        break
      fi
      sleep 2
    done
    if [[ -z \"\${DATA_DEV}\" ]]; then
      echo 'ERROR: Data volume device not found after 60s.' >&2
      exit 1
    fi
    echo \"  Device: \${DATA_DEV}\"
    echo '  Formatting...'
    sudo mkfs.ext4 -L fre-user-data \"\${DATA_DEV}\"
    sudo mkdir -p /mnt/fre-data-tmp
    sudo mount \"\${DATA_DEV}\" /mnt/fre-data-tmp
    echo '  Rsyncing /home/developer/ → data volume...'
    sudo rsync -aAX --delete /home/developer/ /mnt/fre-data-tmp/
    sudo umount /mnt/fre-data-tmp
    sudo rmdir /mnt/fre-data-tmp
    echo '  Done.'
  " 2>&1

  _detach_data_volume "${volume_id}" "${username}"
}

# ---------------------------------------------------------------------------
# Git dirty check (warn about uncommitted / unpushed work)
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

# ---------------------------------------------------------------------------
# Spare registry entry
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Provision spare instance
# ---------------------------------------------------------------------------
step_provision_spare() {
  local users_json="$1"
  local data_volume_id="${2:-}"
  echo "--- provisioning ${SPARE_USER} ---"
  _init_base
  _read_base_outputs
  _init_user "${SPARE_USER}"
  _user_tf_vars "${SPARE_USER}" "${users_json}" "${data_volume_id}"
  terraform -chdir="${TF_USER_DIR}" apply -auto-approve \
    "${USER_TF_VARS[@]}" \
    -var="ami_id="
  SPARE_INSTANCE_ID=$(terraform -chdir="${TF_USER_DIR}" output -raw instance_id 2>/dev/null)
  echo "  Spare instance: ${SPARE_INSTANCE_ID}"

  echo "--- waiting for spare instance to be running ---"
  aws ec2 wait instance-running \
    --instance-ids "${SPARE_INSTANCE_ID}" \
    --region "${AWS_REGION}"

  _wait_for_ssm "${SPARE_INSTANCE_ID}" 36 10
  sleep 5
}

# ---------------------------------------------------------------------------
# Initial adoption flow: existing instance, no data volume yet
# ---------------------------------------------------------------------------
run_initial_adoption() {
  local users_json="$1"

  echo "=== Initial adoption: creating and populating data volume ==="
  echo ""
  echo "  The original instance (${DEV_USERNAME}) will stay running throughout."
  echo "  It is your fallback at every step."
  echo ""

  # Step 1 — ensure original instance is running
  _init_base
  _read_base_outputs
  local orig_instance_id
  orig_instance_id=$(_ensure_running "${DEV_USERNAME}")

  step_check_dirty "${orig_instance_id}"

  # Step 2 — create blank data volume
  DATA_VOLUME_ID=$(_create_data_volume "${DEV_USERNAME}" "${SUBNET_ID}")
  echo "  Data volume: ${DATA_VOLUME_ID}"

  # Step 3 — attach temp, format, rsync, detach
  _populate_data_volume "${DATA_VOLUME_ID}" "${orig_instance_id}" "${DEV_USERNAME}"

  # Step 4 — provision spare with data volume attached
  step_create_spare_registry "${users_json}"
  step_provision_spare "${users_json}" "${DATA_VOLUME_ID}"
}

# ---------------------------------------------------------------------------
# Steady-state migration flow: data volume already exists
# ---------------------------------------------------------------------------
run_steady_state() {
  local users_json="$1"
  local data_volume_id="$2"

  echo "=== Steady-state migration: moving data volume to new instance ==="
  echo ""

  _init_base
  _read_base_outputs

  # Step 1 — ensure original instance exists and check dirty repos
  local orig_instance_id
  orig_instance_id=$(_ensure_running "${DEV_USERNAME}")
  step_check_dirty "${orig_instance_id}"

  # Step 2 — stop original instance
  _stop_instance "${orig_instance_id}" "${DEV_USERNAME}"

  # Step 3 — detach data volume
  _detach_data_volume "${data_volume_id}" "${DEV_USERNAME}"

  # Step 4 — provision spare with data volume
  step_create_spare_registry "${users_json}"
  step_provision_spare "${users_json}" "${data_volume_id}"
}

# ---------------------------------------------------------------------------
# Rollback: undo steady-state migration (re-attach volume to original)
# ---------------------------------------------------------------------------
_rollback_steady_state() {
  local data_volume_id="$1"
  local orig_instance_id="$2"
  local spare_instance_id="${3:-}"

  echo ""
  echo "=== Rolling back ==="

  if [[ -n "${spare_instance_id}" ]]; then
    _stop_instance "${spare_instance_id}" "${SPARE_USER}"
    _detach_data_volume "${data_volume_id}" "${SPARE_USER}" 2>/dev/null || true
  fi

  echo "--- reattaching data volume to ${DEV_USERNAME} ---"
  aws ec2 attach-volume \
    --volume-id "${data_volume_id}" \
    --instance-id "${orig_instance_id}" \
    --device "/dev/sdf" \
    --region "${AWS_REGION}" > /dev/null
  aws ec2 wait volume-in-use \
    --volume-ids "${data_volume_id}" \
    --region "${AWS_REGION}"

  echo "--- starting ${DEV_USERNAME} ---"
  aws ec2 start-instances --instance-ids "${orig_instance_id}" --region "${AWS_REGION}" > /dev/null
  aws ec2 wait instance-running --instance-ids "${orig_instance_id}" --region "${AWS_REGION}"

  echo "  Rollback complete. ${DEV_USERNAME} is running with data volume restored."
}

# ---------------------------------------------------------------------------
# Promotion: dave-spare → dave
# ---------------------------------------------------------------------------
do_promote() {
  local users_json="$1"
  local spare_instance_id="$2"
  local data_volume_id="${3:-}"

  echo ""
  echo "=== Promoting ${SPARE_USER} → ${DEV_USERNAME} ==="

  local orig_key="${PROJECT_NAME}/users/${DEV_USERNAME}/terraform.tfstate"
  local spare_key="${PROJECT_NAME}/users/${SPARE_USER}/terraform.tfstate"
  local backup_key="${PROJECT_NAME}/users/${DEV_USERNAME}/terraform.tfstate.migrate-backup"

  # Safety net: back up original dave state
  echo "--- backing up original Terraform state ---"
  aws s3 cp \
    "s3://${TF_BACKEND_BUCKET}/${orig_key}" \
    "s3://${TF_BACKEND_BUCKET}/${backup_key}" \
    --region "${TF_BACKEND_REGION}" 2>/dev/null || true

  # For initial adoption, original instance is still running — stop it now.
  # For steady-state, original was already stopped and volume already detached.
  local orig_instance_id
  orig_instance_id=$(_get_instance_id "${DEV_USERNAME}")
  if [[ -n "${orig_instance_id}" ]]; then
    _stop_instance "${orig_instance_id}" "${DEV_USERNAME}"
    # Detach data volume from original if it is still attached (initial adoption only;
    # steady-state already detached it before provisioning spare)
    if [[ -n "${data_volume_id}" ]]; then
      local orig_vol_state
      orig_vol_state=$(aws ec2 describe-volumes \
        --volume-ids "${data_volume_id}" \
        --query 'Volumes[0].Attachments[?InstanceId==`'"${orig_instance_id}"'`].State' \
        --region "${AWS_REGION}" \
        --output text 2>/dev/null || echo "")
      if [[ -n "${orig_vol_state}" && "${orig_vol_state}" != "None" ]]; then
        _detach_data_volume "${data_volume_id}" "${DEV_USERNAME}"
      fi
    fi
  fi

  # P1: Destroy original dave EC2 state
  echo "--- destroying original ${DEV_USERNAME} instance ---"
  _init_base
  _read_base_outputs
  _init_user "${DEV_USERNAME}"
  _user_tf_vars "${DEV_USERNAME}" "${users_json}" "${data_volume_id}"
  terraform -chdir="${TF_USER_DIR}" destroy -auto-approve "${USER_TF_VARS[@]}"

  # P2: Move spare state to dave state path
  echo "--- copying spare Terraform state to ${DEV_USERNAME} state path ---"
  aws s3 cp \
    "s3://${TF_BACKEND_BUCKET}/${spare_key}" \
    "s3://${TF_BACKEND_BUCKET}/${orig_key}" \
    --region "${TF_BACKEND_REGION}"

  # P3: Apply with dave's variables to rename IAM role/profile and update tags.
  # EC2 instance stays running; only IAM resources are recreated.
  echo "--- renaming IAM resources and tags to ${DEV_USERNAME} (instance stays running) ---"
  _init_user "${DEV_USERNAME}"
  _user_tf_vars "${DEV_USERNAME}" "${users_json}" "${data_volume_id}"
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

  # P6: Delete safety net backup
  aws s3 rm \
    "s3://${TF_BACKEND_BUCKET}/${backup_key}" \
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

if ! jq -e --arg u "${DEV_USERNAME}" '.[$u]' "${USERS_JSON}" > /dev/null 2>&1; then
  echo "ERROR: User '${DEV_USERNAME}' not found in registry." >&2
  exit 1
fi

# Detect which flow to use
DATA_VOLUME_ID=$(_get_data_volume_id "${DEV_USERNAME}")

if [[ "${MIGRATE_LIVE}" == "true" ]]; then
  # --- Live run ---
  SPARE_INSTANCE_ID=$(_get_instance_id "${SPARE_USER}")

  if [[ -n "${SPARE_INSTANCE_ID}" ]]; then
    # Spare already exists — go straight to promotion
    LAUNCH_TIME=$(_get_launch_time "${SPARE_INSTANCE_ID}")
    # Determine data volume ID from spare's state if we don't have it yet
    if [[ -z "${DATA_VOLUME_ID}" ]]; then
      DATA_VOLUME_ID=$(_get_data_volume_id "${DEV_USERNAME}")
    fi
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
    do_promote "${USERS_JSON}" "${SPARE_INSTANCE_ID}" "${DATA_VOLUME_ID}"
  else
    # No spare — run full provision sequence then promote
    if [[ -z "${DATA_VOLUME_ID}" ]]; then
      run_initial_adoption "${USERS_JSON}"
    else
      run_steady_state "${USERS_JSON}" "${DATA_VOLUME_ID}"
    fi
    echo ""
    echo "  ${SPARE_USER} is ready."
    echo "  Connect to validate: admin.sh connect ${SPARE_USER}"
    echo ""
    read -r -p "  Press Enter to promote ${SPARE_USER} → ${DEV_USERNAME} (Ctrl+C to abort)..." _
    do_promote "${USERS_JSON}" "${SPARE_INSTANCE_ID}" "${DATA_VOLUME_ID}"
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

  if [[ -z "${DATA_VOLUME_ID}" ]]; then
    run_initial_adoption "${USERS_JSON}"
  else
    run_steady_state "${USERS_JSON}" "${DATA_VOLUME_ID}"
  fi

  echo ""
  echo "=== Test migration complete. ${DEV_USERNAME} is untouched. ==="
  echo ""
  echo "  ${SPARE_USER} is running with your migrated environment."
  echo "  Connect to validate:  admin.sh connect ${SPARE_USER}"
  echo "  When satisfied:       admin.sh migrate ${DEV_USERNAME} --live"
  echo "  To abandon:           admin.sh down ${SPARE_USER}"
  echo ""
fi
