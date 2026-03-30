
# ---------------------------------------------------------------------------
# Invoke session launcher on interactive SSH login
# ---------------------------------------------------------------------------
if [[ "${PREFERRED_SHELL:-bash}" == "zsh" ]]; then
  _PROFILE=/home/developer/.zprofile
else
  _PROFILE=/home/developer/.bash_profile
fi

cat >> "${_PROFILE}" << 'PROFILE'

# Launch Claude Code session selector on interactive login (SSH or SSM browser terminal)
if [[ -t 0 && -z "${TMUX:-}" ]]; then
  exec /home/developer/session_start.sh
fi
PROFILE

chown developer:developer "${_PROFILE}"
echo "=== Bootstrap complete ==="
