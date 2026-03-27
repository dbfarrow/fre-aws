#!/usr/bin/env bash
# entrypoint.sh — Runs on every container start before the actual command.
# If a corporate CA certificate is mounted at /certs/corp-ca.crt, installs it
# into the OS trust store so all tools (aws, terraform, git, curl) trust it.
# Transparent when no cert is mounted — zero overhead for standard setups.
set -euo pipefail

if [[ -f /certs/corp-ca.crt ]]; then
  cp /certs/corp-ca.crt /usr/local/share/ca-certificates/corp-ca.crt
  update-ca-certificates > /dev/null
fi

exec "$@"
