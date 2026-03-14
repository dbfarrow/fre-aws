
# ---------------------------------------------------------------------------
# Invoke session launcher on interactive SSH login
# ---------------------------------------------------------------------------
cat >> /home/developer/.bash_profile << 'PROFILE'

# Launch Claude Code session selector on interactive SSH login
if [[ -n "${SSH_TTY:-}" ]]; then
  exec /home/developer/session_start.sh
fi
PROFILE

chown developer:developer /home/developer/.bash_profile
echo "=== Bootstrap complete ==="
