#!/usr/bin/env bats
# Tests for start.sh, stop.sh, and connect.sh — validates behavior without AWS calls.

setup() {
  TEST_DIR="$(mktemp -d)"
  mkdir -p "${TEST_DIR}/config" "${TEST_DIR}/scripts" "${TEST_DIR}/terraform" "${TEST_DIR}/bin"

  cat > "${TEST_DIR}/config/defaults.env" <<'EOF'
PROJECT_NAME=test-project
AWS_REGION=us-east-1
AWS_PROFILE=test-profile
EOF

  # Fake terraform that returns a known instance ID
  cat > "${TEST_DIR}/bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "i-1234567890abcdef0"
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/terraform"

  for script in start.sh stop.sh connect.sh; do
    cp "${BATS_TEST_DIRNAME}/../../scripts/${script}" "${TEST_DIR}/scripts/${script}"
    chmod +x "${TEST_DIR}/scripts/${script}"
    # Rewrite TF_DIR to point at our test terraform dir
    sed -i "s|SCRIPT_DIR}/../terraform|TEST_DIR}/terraform|g" "${TEST_DIR}/scripts/${script}" || true
  done

  export TEST_DIR
}

teardown() {
  rm -rf "${TEST_DIR}"
}

# --- start.sh ---------------------------------------------------------------

@test "start.sh exits with error when terraform state is unavailable" {
  # Override terraform to simulate missing state
  cat > "${TEST_DIR}/bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "No state file" >&2
exit 1
EOF
  PATH="${TEST_DIR}/bin:$PATH" run "${TEST_DIR}/scripts/start.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"up.sh"* ]]
}

# --- stop.sh ----------------------------------------------------------------

@test "stop.sh exits with error when terraform state is unavailable" {
  cat > "${TEST_DIR}/bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "No state file" >&2
exit 1
EOF
  PATH="${TEST_DIR}/bin:$PATH" run "${TEST_DIR}/scripts/stop.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"up.sh"* ]]
}

# --- connect.sh -------------------------------------------------------------

@test "connect.sh exits with error when terraform state is unavailable" {
  cat > "${TEST_DIR}/bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "No state file" >&2
exit 1
EOF
  PATH="${TEST_DIR}/bin:$PATH" run "${TEST_DIR}/scripts/connect.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"up.sh"* ]]
}

@test "connect.sh exits with error when instance is stopped" {
  # terraform returns an instance ID
  cat > "${TEST_DIR}/bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "i-1234567890abcdef0"
exit 0
EOF
  # aws returns stopped state
  cat > "${TEST_DIR}/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "stopped"
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/aws"
  PATH="${TEST_DIR}/bin:$PATH" run "${TEST_DIR}/scripts/connect.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"start.sh"* ]]
}

@test "connect.sh exits with error when AWS describe-instances fails" {
  cat > "${TEST_DIR}/bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "i-1234567890abcdef0"
exit 0
EOF
  cat > "${TEST_DIR}/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "An error occurred" >&2
exit 1
EOF
  chmod +x "${TEST_DIR}/bin/aws"
  PATH="${TEST_DIR}/bin:$PATH" run "${TEST_DIR}/scripts/connect.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"credentials"* ]]
}
