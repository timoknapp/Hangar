# Copilot workstation shell
source ~/.workspace_env 2>/dev/null || true
export PATH="/usr/local/bin:$PATH"
export TERM=xterm-256color

# Aliases
alias ll='ls -la'
alias gs='git status'
alias gl='git pull'
alias gp='git push'
alias glog='git log --oneline -20'
alias c='copilot'
alias cs='squad init && copilot --agent squad --yolo'
csr() {
  copilot --agent squad --yolo --resume="$@"
}

# Repo management
alias repos='repo-add'  # no args = list repos
repo() {
  local target="/workspace/${1}"
  if [[ -d "$target" ]]; then
    cd "$target"
  else
    echo "Not found: $target"
    echo "Available repos:"
    for d in /workspace/*/; do [[ -d "$d/.git" ]] && echo "  $(basename "$d")"; done
  fi
}

alias preview='npm run build && npm run preview:host'


# cd into workspace
if [[ -n "${WORKSPACE_DIR:-}" ]] && [[ -d "$WORKSPACE_DIR" ]]; then
  cd "$WORKSPACE_DIR"
fi

# Auto-attach to tmux session
if [[ -z "${TMUX:-}" ]] && command -v tmux &>/dev/null; then
  tmux attach-session -t copilot 2>/dev/null || tmux new-session -s copilot
fi

export NVM_DIR="$HOME/.nvm"
# Lazy-load NVM: defers ~260ms until first use of nvm/node/npm/npx
_nvm_lazy_load() {
  unset -f nvm node npm npx
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
  [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
}
nvm()  { _nvm_lazy_load; nvm  "$@"; }
node() { _nvm_lazy_load; node "$@"; }
npm()  { _nvm_lazy_load; npm  "$@"; }
npx()  { _nvm_lazy_load; npx  "$@"; }