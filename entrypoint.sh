#!/bin/bash
# =============================================================================
# entrypoint.sh — Container entrypoint
# Starts ttyd serving a tmux session as the copilot user
# =============================================================================
set -e

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
TTYD_PORT="${TTYD_PORT:-7681}"
SESSION_USER="copilot"

# ---------------------------------------------------------------------------
# Optionally update Copilot CLI + Squad CLI on container start.
# The Dockerfile only installs these at BUILD time, so a plain restart (docker
# restart, host reboot via restart:unless-stopped, crash recovery) would keep a
# stale CLI. When explicitly enabled, this refreshes it on start. Runs as root
# (global npm prefix).
#
# It first does a fast version check (npm view, ~1s) and only runs the slower
# `npm install` when a newer version actually exists — so routine restarts are
# cheap and idempotent, and only the first start after a new release reinstalls.
#
# Set AUTO_UPDATE_CLI=false (e.g. in docker-compose.yml) to pin to the baked-in
# versions for offline/air-gapped hosts or to freeze a known-good version.
# ---------------------------------------------------------------------------
AUTO_UPDATE_CLI="${AUTO_UPDATE_CLI:-false}"
if [[ "$AUTO_UPDATE_CLI" == "true" ]]; then
  echo ">>> Checking for Copilot/Squad CLI updates..."
  installed_ver() { npm list -g "$1" --depth=0 2>/dev/null | awk -F@ -v p="$1" '$0 ~ p {print $NF}' | head -1; }

  COPILOT_CUR=$(installed_ver @github/copilot)
  SQUAD_CUR=$(installed_ver @bradygaster/squad-cli)
  COPILOT_LATEST=$(timeout 30 npm view @github/copilot version 2>/dev/null || echo "")
  SQUAD_LATEST=$(timeout 30 npm view @bradygaster/squad-cli version 2>/dev/null || echo "")

  if [[ -z "$COPILOT_LATEST" && -z "$SQUAD_LATEST" ]]; then
    echo ">>> WARNING: could not reach npm registry (offline?). Keeping baked-in CLI (${COPILOT_CUR:-n/a})."
  elif { [[ -n "$COPILOT_LATEST" && "$COPILOT_CUR" != "$COPILOT_LATEST" ]] || \
         [[ -n "$SQUAD_LATEST" && "$SQUAD_CUR" != "$SQUAD_LATEST" ]]; }; then
    echo ">>> Update available — copilot ${COPILOT_CUR:-none}->${COPILOT_LATEST:-?}, squad ${SQUAD_CUR:-none}->${SQUAD_LATEST:-?}. Installing..."
    if npm install -g @github/copilot@latest @bradygaster/squad-cli@latest >/tmp/cli-update.log 2>&1; then
      echo ">>> CLI updated: copilot=$(installed_ver @github/copilot) squad=$(installed_ver @bradygaster/squad-cli)"
    else
      echo ">>> WARNING: CLI update failed. Keeping ${COPILOT_CUR:-n/a}. See /tmp/cli-update.log"
    fi
  else
    echo ">>> Copilot/Squad CLI already up to date (copilot ${COPILOT_CUR:-n/a})"
  fi
else
  echo ">>> AUTO_UPDATE_CLI=false — skipping CLI update check"
fi

# Fix ownership on Docker volumes (created as root)
echo ">>> Fixing volume permissions..."
mkdir -p /home/$SESSION_USER/.ssh
mkdir -p /home/$SESSION_USER/.config/gh
mkdir -p /home/$SESSION_USER/.local/share
mkdir -p "$WORKSPACE_DIR"
chown -R "$SESSION_USER":"$SESSION_USER" /home/$SESSION_USER/.ssh
chown -R "$SESSION_USER":"$SESSION_USER" /home/$SESSION_USER/.config
chown -R "$SESSION_USER":"$SESSION_USER" /home/$SESSION_USER/.local
chown "$SESSION_USER":"$SESSION_USER" "$WORKSPACE_DIR"
chmod 700 /home/$SESSION_USER/.ssh

# SSH: ensure host keys exist (persisted via volume)
if [[ ! -f /etc/ssh/ssh_host_ed25519_key ]]; then
  echo ">>> Generating SSH host keys..."
  ssh-keygen -A
fi

# SSH: copy user's GitHub SSH key as authorized_key if it exists and authorized_keys is empty
if [[ -f /home/$SESSION_USER/.ssh/id_ed25519.pub ]] && [[ ! -s /home/$SESSION_USER/.ssh/authorized_keys ]]; then
  cp /home/$SESSION_USER/.ssh/id_ed25519.pub /home/$SESSION_USER/.ssh/authorized_keys
  chown $SESSION_USER:$SESSION_USER /home/$SESSION_USER/.ssh/authorized_keys
  chmod 600 /home/$SESSION_USER/.ssh/authorized_keys
fi

# Clone primary repo on first run if REPO_URL is set and workspace is empty
if [[ -n "${REPO_URL:-}" ]] && [[ ! -d "$WORKSPACE_DIR/.git" ]]; then
  echo ">>> Cloning $REPO_URL into $WORKSPACE_DIR..."
  su - "$SESSION_USER" -c "git clone -b '${REPO_BRANCH:-main}' '$REPO_URL' '$WORKSPACE_DIR'" || \
    echo "WARNING: Clone failed. You can clone manually after auth setup."
fi

# Clone extra repos (comma-separated: "url#branch,url#branch,...")
# Each repo is cloned into /workspace/<repo-name>/
if [[ -n "${EXTRA_REPOS:-}" ]]; then
  IFS=',' read -ra REPOS <<< "$EXTRA_REPOS"
  for entry in "${REPOS[@]}"; do
    entry=$(echo "$entry" | xargs)  # trim whitespace
    [[ -z "$entry" ]] && continue
    # Parse url#branch (# avoids conflict with git@ URLs; no branch = remote default)
    repo_url="${entry%%#*}"
    repo_branch="${entry#*#}"
    [[ "$repo_branch" == "$repo_url" ]] && repo_branch=""
    # Derive directory name from URL (e.g. git@github.com:user/foo.git → foo)
    repo_name=$(basename "$repo_url" .git)
    repo_dir="/workspace/$repo_name"
    if [[ ! -d "$repo_dir/.git" ]]; then
      echo ">>> Cloning $repo_url${repo_branch:+ ($repo_branch)} into $repo_dir..."
      mkdir -p "$repo_dir"
      chown "$SESSION_USER":"$SESSION_USER" "$repo_dir"
      if [[ -n "$repo_branch" ]]; then
        su - "$SESSION_USER" -c "git clone -b '$repo_branch' '$repo_url' '$repo_dir'" || \
          echo "WARNING: Clone of $repo_url failed. Clone manually after auth setup."
      else
        su - "$SESSION_USER" -c "git clone '$repo_url' '$repo_dir'" || \
          echo "WARNING: Clone of $repo_url failed. Clone manually after auth setup."
      fi
    else
      echo ">>> Repo already exists: $repo_dir (skipping)"
    fi
  done
fi

# Write workspace dir into env so bashrc can cd into it
echo "export WORKSPACE_DIR=$WORKSPACE_DIR" > /home/$SESSION_USER/.workspace_env
chown "$SESSION_USER":"$SESSION_USER" /home/$SESSION_USER/.workspace_env

echo ">>> Starting SSH server on port 22..."
/usr/sbin/sshd

ENABLE_TTYD="${ENABLE_TTYD:-false}"

if [[ "$ENABLE_TTYD" == "true" ]]; then
  echo ">>> Starting nginx (toolbar proxy) on port 8080..."
  nginx

  echo ">>> Starting ttyd on port ${TTYD_PORT} (internal)..."
  exec ttyd \
    --port "$TTYD_PORT" \
    --writable \
    --max-clients 5 \
    --ping-interval 30 \
    --base-path / \
    --client-option enableWebGL=false \
    --client-option fontSize=14 \
    bash -c "cd $WORKSPACE_DIR && exec sudo -u $SESSION_USER -i"
else
  echo ">>> TTYD disabled (set ENABLE_TTYD=true to enable)"
  echo ">>> Starting idle keep-alive (use SSH to connect)..."
  exec tail -f /dev/null
fi
