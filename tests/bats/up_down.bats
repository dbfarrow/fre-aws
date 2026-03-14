#!/usr/bin/env bats
# Tests for up.sh and down.sh — validates behavior without AWS calls.

setup() {
  TEST_DIR="$(mktemp -d)"
  mkdir -p "${TEST_DIR}/config" "${TEST_DIR}/scripts" "${TEST_DIR}/terraform" "${TEST_DIR}/bin"

  cat > "${TEST_DIR}/config/defaults.env" <<'EOF'
PROJECT_NAME=test-project
AWS_REGION=us-east-1
AWS_PROFILE=test-profile
INSTANCE_TYPE=t3.micro
USE_SPOT=true
NETWORK_MODE=public
EBS_VOLUME_SIZE_GB=20
OWNER_EMAIL=
EOF

  cat > "${TEST_DIR}/config/backend.env" <<'EOF'
TF_BACKEND_BUCKET=test-project-tfstate
TF_BACKEND_KEY=test-project/terraform.tfstate
TF_BACKEND_REGION=us-east-1
TF_BACKEND_DYNAMODB_TABLE=test-project-tflock
TF_BACKEND_KMS_KEY_ID=arn:aws:kms:us-east-1:123456789012:key/test-key
TF_BACKEND_ACCOUNT_ID=123456789012
EOF

  for script in up.sh down.sh; do
    cp "${BATS_TEST_DIRNAME}/../../scripts/${script}" "${TEST_DIR}/scripts/${script}"
    chmod +x "${TEST_DIR}/scripts/${script}"
  done

  export TEST_DIR
}

teardown() {
  rm -rf "${TEST_DIR}"
}

# --- up.sh ------------------------------------------------------------------

@test "up.sh exits with error when defaults.env is missing" {
  rm "${TEST_DIR}/config/defaults.env"
  run "${TEST_DIR}/scripts/up.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"defaults.env"* ]]
}

@test "up.sh exits with error when backend.env is missing" {
  rm "${TEST_DIR}/config/backend.env"
  run "${TEST_DIR}/scripts/up.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bootstrap.sh"* ]]
}

# --- down.sh ----------------------------------------------------------------

@test "down.sh exits with error when defaults.env is missing" {
  rm "${TEST_DIR}/config/defaults.env"
  run "${TEST_DIR}/scripts/down.sh"
  [ "$status" -ne 0 ]
}

@test "down.sh exits with error when backend.env is missing" {
  rm "${TEST_DIR}/config/backend.env"
  run "${TEST_DIR}/scripts/down.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bootstrap.sh"* ]]
}

@test "down.sh aborts when confirmation does not match project name" {
  # Use bash -c to properly pipe stdin to the script under test
  SCRIPTS="${TEST_DIR}/scripts" CONFIG="${TEST_DIR}/config"
  run bash -c "printf 'wrong-name\n' | SCRIPT_DIR='${TEST_DIR}/scripts' bash '${TEST_DIR}/scripts/down.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Aborted"* ]]
}
