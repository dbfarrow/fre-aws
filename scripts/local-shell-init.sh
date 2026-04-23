#!/usr/bin/env bash
# local-shell-init.sh — rcfile for ./user.sh local-shell sessions.
# Sourced by: bash --rcfile /workspace/scripts/local-shell-init.sh
# NOTE: Do NOT use set -euo pipefail here — this file is sourced as an rcfile
# and strict mode would cause the interactive shell to exit on any error.

# Source system defaults then user config
# bash: sources .user.bashrc if mounted; zsh: ~/.zshrc is sourced after this file automatically
[[ -f /etc/bash.bashrc ]] && source /etc/bash.bashrc
[[ -f /root/.user.bashrc ]] && source /root/.user.bashrc

# Coloured project-aware prompt (bash and zsh use different escape syntax)
if [[ -n "${ZSH_VERSION:-}" ]]; then
  export PROMPT="%F{cyan}[${FRE_PROJECT}]%f %n@%m:%~%# "
else
  export PS1="\[\e[1;36m\][${FRE_PROJECT}]\[\e[0m\] \u@\h:\w\$ "
fi

# csync: pull current project state from EC2
csync() { /workspace/scripts/csync.sh "$@"; }

# cpush: upload a file back to EC2 for Claude to read
cpush() { /workspace/scripts/cpush.sh "$@"; }

# export -f is bash-only; in zsh functions defined here are already in scope
[[ -n "${BASH_VERSION:-}" ]] && export -f csync cpush

# Land in the project directory
_local_proj="${FRE_LOCAL_DIR}/${FRE_PROJECT}"
mkdir -p "${_local_proj}"
cd "${_local_proj}"

# Activate venv if present
if [[ -f "${_local_proj}/.venv/bin/activate" ]]; then
  source "${_local_proj}/.venv/bin/activate"
fi

echo ""
echo "fre local shell  —  project: ${FRE_PROJECT}"
echo "  dir:   ${_local_proj}"
[[ -n "${VIRTUAL_ENV:-}" ]] && echo "  venv:  active (${VIRTUAL_ENV})"
echo ""
echo "  csync          pull '${FRE_PROJECT}' from EC2 into this directory"
echo "  cpush [file]   upload file (default: output.txt) back to Claude"
echo "                 Tell Claude 'done' after cpush completes."
echo ""
