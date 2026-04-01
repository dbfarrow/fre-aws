
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

# Write runtime config so session_start.sh can look up SSM and Secrets Manager
# without hardcoding project/user/region values.
cat > /home/developer/.fre-config << EOF
FRE_PROJECT_NAME=${PROJECT_NAME}
FRE_USERNAME=${DEV_USERNAME}
FRE_REGION=${REGION}
FRE_AUTOSHUTDOWN_IDLE_MINUTES=${AUTOSHUTDOWN_IDLE_MINUTES}
EOF
chown developer:developer /home/developer/.fre-config
chmod 600 /home/developer/.fre-config

echo "=== Bootstrap complete ==="
