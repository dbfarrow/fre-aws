#!/usr/bin/env bats
# Tests for bootstrap.sh — validates behavior without making AWS calls.

setup() {
  # Create a temp directory with a valid config
  TEST_DIR="$(mktemp -d)"
  mkdir -p "${TEST_DIR}/config" "${TEST_DIR}/scripts"

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

  # Copy the script under test
  cp "${BATS_TEST_DIRNAME}/../../scripts/bootstrap.sh" "${TEST_DIR}/scripts/bootstrap.sh"
  chmod +x "${TEST_DIR}/scripts/bootstrap.sh"

  export TEST_DIR
}

teardown() {
  rm -rf "${TEST_DIR}"
}

@test "bootstrap.sh exits with error when config file is missing" {
  rm "${TEST_DIR}/config/defaults.env"
  run "${TEST_DIR}/scripts/bootstrap.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"defaults.env"* ]]
}

@test "bootstrap.sh exits with error when PROJECT_NAME is empty" {
  sed -i 's/^PROJECT_NAME=.*/PROJECT_NAME=/' "${TEST_DIR}/config/defaults.env"
  run "${TEST_DIR}/scripts/bootstrap.sh"
  [ "$status" -ne 0 ]
}

@test "bootstrap.sh exits with error when AWS_REGION is empty" {
  sed -i 's/^AWS_REGION=.*/AWS_REGION=/' "${TEST_DIR}/config/defaults.env"
  run "${TEST_DIR}/scripts/bootstrap.sh"
  [ "$status" -ne 0 ]
}

@test "bootstrap.sh exits with error when AWS credentials are invalid" {
  # Override aws to simulate a credential failure
  mkdir -p "${TEST_DIR}/bin"
  cat > "${TEST_DIR}/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "Unable to locate credentials" >&2
exit 1
EOF
  chmod +x "${TEST_DIR}/bin/aws"
  PATH="${TEST_DIR}/bin:$PATH" run "${TEST_DIR}/scripts/bootstrap.sh"
  [ "$status" -ne 0 ]
}
