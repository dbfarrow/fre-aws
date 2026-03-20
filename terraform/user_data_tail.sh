
# ---------------------------------------------------------------------------
# Invoke session launcher on interactive SSH login
# ---------------------------------------------------------------------------
cat >> /home/developer/.bash_profile << 'PROFILE'

# Launch Claude Code session selector on interactive login (SSH or SSM browser terminal)
if [[ -t 0 && -z "${TMUX:-}" ]]; then
  exec /home/developer/session_start.sh
fi
PROFILE

chown developer:developer /home/developer/.bash_profile
echo "=== Bootstrap complete ==="
