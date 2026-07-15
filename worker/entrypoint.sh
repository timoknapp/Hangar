#!/bin/bash
# =============================================================================
# entrypoint.sh — Worker Container Entrypoint
# Runs as root: fixes volume permissions, clones repo, configures git,
# then drops to the copilot user and execs the worker loop.
# =============================================================================
set -e

WORKER_ID="${WORKER_ID:-worker-0}"
SESSION_USER="copilot"
AGENT_USER="squad-agent"
SHARED_GROUP="squad"
REPOS_CONFIG="/etc/squad/repos.json"

# ---------------------------------------------------------------------------
# Resolve repo config from repos.json (falls back to env vars)
# ---------------------------------------------------------------------------
if [[ -f "$REPOS_CONFIG" ]] && command -v jq &>/dev/null; then
  WORKER_CFG=$(jq -r --arg wid "$WORKER_ID" '.[$wid] // empty' "$REPOS_CONFIG" 2>/dev/null)
  if [[ -n "$WORKER_CFG" ]]; then
    echo ">>> [${WORKER_ID}] Loading config from repos.json..."
    REPO_URL=$(echo "$WORKER_CFG" | jq -r '.url // empty')
    REPO_BRANCH=$(echo "$WORKER_CFG" | jq -r '.branch // "main"')
    GITHUB_OWNER=$(echo "$WORKER_CFG" | jq -r '.owner // empty')
    GITHUB_REPO=$(echo "$WORKER_CFG" | jq -r '.repo // empty')
    WORKSPACE_DIR="/workspace/${GITHUB_REPO}"
  else
    echo ">>> [${WORKER_ID}] No entry in repos.json, using env vars..."
  fi
fi

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace/repo}"

echo ">>> [${WORKER_ID}] Starting Squad Worker container..."

if [[ -z "${COPILOT_PAT:-}" ]]; then
  echo "ERROR: COPILOT_PAT is required and must be separate from the GitHub App publisher token."
  exit 1
fi
case "$COPILOT_PAT" in
  github_pat_*) ;;
  *)
    echo "ERROR: COPILOT_PAT must be a user-owned fine-grained PAT with only the Copilot Requests account permission."
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Optionally update Copilot CLI + Squad CLI on container start.
# The Dockerfile only pulls @latest at BUILD time, so a plain restart (docker
# restart, host reboot via restart:unless-stopped, crash recovery) would keep a
# stale CLI. When explicitly enabled, this refreshes it on start. Runs as root
# (global npm prefix).
#
# It first does a fast version check (npm view, ~1s) and only runs the slower
# `npm install` when a newer version actually exists — so routine restarts are
# cheap and idempotent, and only the first start after a new release reinstalls.
#
# Set AUTO_UPDATE_CLI=false (e.g. in .env.workers) to pin to the baked-in
# versions for offline/air-gapped hosts or to freeze a known-good version.
# ---------------------------------------------------------------------------
AUTO_UPDATE_CLI="${AUTO_UPDATE_CLI:-false}"
if [[ "$AUTO_UPDATE_CLI" == "true" ]]; then
  echo ">>> [${WORKER_ID}] Checking for Copilot/Squad CLI updates..."
  installed_ver() { npm list -g "$1" --depth=0 2>/dev/null | awk -F@ -v p="$1" '$0 ~ p {print $NF}' | head -1; }

  COPILOT_CUR=$(installed_ver @github/copilot)
  SQUAD_CUR=$(installed_ver @bradygaster/squad-cli)
  COPILOT_LATEST=$(timeout 30 npm view @github/copilot version 2>/dev/null || echo "")
  SQUAD_LATEST=$(timeout 30 npm view @bradygaster/squad-cli version 2>/dev/null || echo "")

  if [[ -z "$COPILOT_LATEST" && -z "$SQUAD_LATEST" ]]; then
    echo ">>> [${WORKER_ID}] WARNING: could not reach npm registry (offline?). Keeping baked-in CLI (${COPILOT_CUR:-n/a})."
  elif { [[ -n "$COPILOT_LATEST" && "$COPILOT_CUR" != "$COPILOT_LATEST" ]] || \
         [[ -n "$SQUAD_LATEST" && "$SQUAD_CUR" != "$SQUAD_LATEST" ]]; }; then
    echo ">>> [${WORKER_ID}] Update available — copilot ${COPILOT_CUR:-none}->${COPILOT_LATEST:-?}, squad ${SQUAD_CUR:-none}->${SQUAD_LATEST:-?}. Installing..."
    if npm install -g @github/copilot@latest @bradygaster/squad-cli@latest >/tmp/cli-update.log 2>&1; then
      echo ">>> [${WORKER_ID}] CLI updated: copilot=$(installed_ver @github/copilot) squad=$(installed_ver @bradygaster/squad-cli)"
    else
      echo ">>> [${WORKER_ID}] WARNING: CLI update failed. Keeping ${COPILOT_CUR:-n/a}. See /tmp/cli-update.log"
    fi
  else
    echo ">>> [${WORKER_ID}] Copilot/Squad CLI already up to date (copilot ${COPILOT_CUR:-n/a})"
  fi
else
  echo ">>> [${WORKER_ID}] AUTO_UPDATE_CLI=false — skipping CLI update check"
fi

# ---------------------------------------------------------------------------
# Print tool versions (for diagnostics — visible in `docker logs`)
# ---------------------------------------------------------------------------
echo ">>> [${WORKER_ID}] Tool versions:"
printf "    node          : %s\n" "$(node --version 2>/dev/null || echo 'n/a')"
printf "    npm           : %s\n" "$(npm --version 2>/dev/null || echo 'n/a')"
printf "    git           : %s\n" "$(git --version 2>/dev/null | awk '{print $3}' || echo 'n/a')"
printf "    gh cli        : %s\n" "$(gh --version 2>/dev/null | head -1 | awk '{print $3}' || echo 'n/a')"
printf "    @github/copilot    : %s\n" "$(npm list -g @github/copilot --depth=0 2>/dev/null | awk -F@ '/@github\/copilot/ {print $NF}' | head -1 || echo 'n/a')"
printf "    @bradygaster/squad-cli : %s\n" "$(npm list -g @bradygaster/squad-cli --depth=0 2>/dev/null | awk -F@ '/@bradygaster\/squad-cli/ {print $NF}' | head -1 || echo 'n/a')"
printf "    COPILOT_MODEL : %s\n" "${COPILOT_MODEL:-<default>}"
printf "    COPILOT_EFFORT : %s\n" "${COPILOT_EFFORT:-<default>}"
printf "    COPILOT_CONTEXT : %s\n" "${COPILOT_CONTEXT:-<default>}"
printf "    LOOP          : autonomous=%s critic=%s verify=%s\n" "${LOOP_AUTONOMOUS:-false}" "${LOOP_CRITIC:-false}" "${LOOP_VERIFY:-off}"
printf "    LOOP POLICY   : implementer=%s scope=%s rubric=%s retries=%s prs/day=%s auto-issues=%s\n" \
  "${LOOP_IMPLEMENTER:-plain}" "${LOOP_WORK_SCOPE:-all}" "${LOOP_CRITIC_RUBRIC:-auto}" "${LOOP_MAX_RETRIES:-2}" \
  "${LOOP_MAX_PRS_PER_DAY:-0}" "${LOOP_MAX_OPEN_AUTO_ISSUES:-3}"

# ---------------------------------------------------------------------------
# Fix ownership on Docker volumes (created as root)
# ---------------------------------------------------------------------------
echo ">>> Fixing volume permissions..."
mkdir -p /home/$SESSION_USER/.config/gh
mkdir -p /home/$SESSION_USER/.local/share
mkdir -p /home/$SESSION_USER/.ssh
mkdir -p /home/$AGENT_USER/.config /home/$AGENT_USER/.local/share /home/$AGENT_USER/.cache /home/$AGENT_USER/.npm
mkdir -p "$WORKSPACE_DIR"
chown -R "$SESSION_USER":"$SHARED_GROUP" /home/$SESSION_USER/.config
chown -R "$SESSION_USER":"$SHARED_GROUP" /home/$SESSION_USER/.local
chown -R "$SESSION_USER":"$SHARED_GROUP" /home/$SESSION_USER/.ssh
chmod 700 /home/$SESSION_USER/.ssh
chown -R "$AGENT_USER":"$SHARED_GROUP" /home/$AGENT_USER
chmod 700 /home/$SESSION_USER /home/$AGENT_USER
chown "$AGENT_USER":"$SHARED_GROUP" "$WORKSPACE_DIR"
chmod 2770 "$WORKSPACE_DIR"

# ---------------------------------------------------------------------------
# SSH: set up authorized_keys from env var (survives restarts)
# ---------------------------------------------------------------------------
if [[ -n "${SSH_AUTHORIZED_KEY:-}" ]]; then
  echo "$SSH_AUTHORIZED_KEY" > /home/$SESSION_USER/.ssh/authorized_keys
  chown "$SESSION_USER":"$SHARED_GROUP" /home/$SESSION_USER/.ssh/authorized_keys
  chmod 600 /home/$SESSION_USER/.ssh/authorized_keys
  echo ">>> SSH authorized key configured"
fi

# ---------------------------------------------------------------------------
# Fix PEM file permissions (bind mount is root:root 600, read-only)
# Copy to a user-readable location so copilot can use it with openssl.
# ---------------------------------------------------------------------------
PEM_MOUNT="/run/secrets/gh-app-key.pem"
PEM_COPY="/home/$SESSION_USER/.gh-app-key.pem"
if [[ -f "$PEM_MOUNT" ]]; then
  echo ">>> Copying PEM file for $SESSION_USER access..."
  cp "$PEM_MOUNT" "$PEM_COPY"
  chmod 400 "$PEM_COPY"
  chown "$SESSION_USER":"$SHARED_GROUP" "$PEM_COPY"
  export GH_APP_PEM_FILE="$PEM_COPY"
else
  echo "WARNING: PEM file not found at $PEM_MOUNT"
fi

# ---------------------------------------------------------------------------
# Generate initial token for clone
# ---------------------------------------------------------------------------
echo ">>> Generating initial GitHub token..."
INITIAL_TOKEN=$(/home/$SESSION_USER/generate-token.sh 2>/dev/null) || {
  echo "WARNING: Initial token generation failed. Clone may fail if repo is private."
  INITIAL_TOKEN=""
}

if [[ -n "$INITIAL_TOKEN" && "$COPILOT_PAT" == "$INITIAL_TOKEN" ]]; then
  echo "ERROR: COPILOT_PAT must not reuse the GitHub App publisher installation token."
  exit 1
fi

TOKEN_FILE="/home/$SESSION_USER/.github-app-token"
if [[ -n "$INITIAL_TOKEN" ]]; then
  printf '%s' "$INITIAL_TOKEN" > "$TOKEN_FILE"
  chown "$SESSION_USER":"$SHARED_GROUP" "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
fi

# The helper contains no secret and only answers credential requests for
# https://github.com. The short-lived token remains publisher-readable only.
su - "$SESSION_USER" -c "git config --global --replace-all credential.helper '!/home/$SESSION_USER/git-credential-helper.sh'"

# ---------------------------------------------------------------------------
# Clone repo on first run if workspace is empty
# ---------------------------------------------------------------------------
if [[ -n "${REPO_URL:-}" ]] && [[ ! -d "$WORKSPACE_DIR/.git" ]]; then
  echo ">>> Cloning ${REPO_URL} into ${WORKSPACE_DIR}..."
  su - "$SESSION_USER" -c "git -c core.hooksPath=/dev/null clone -b '${REPO_BRANCH:-main}' '${REPO_URL}' '${WORKSPACE_DIR}'" || {
    echo "WARNING: Clone failed. Worker will retry on next loop iteration."
  }
fi

# ---------------------------------------------------------------------------
# Configure git identity
# ---------------------------------------------------------------------------
echo ">>> Configuring git for ${WORKER_ID}..."
su - "$SESSION_USER" -c "git config --global user.name 'Hangar Worker ${WORKER_ID}'"
su - "$SESSION_USER" -c "git config --global user.email 'hangar-worker@localhost'"
su - "$SESSION_USER" -c "git config --global init.defaultBranch main"
su - "$SESSION_USER" -c "git config --global pull.rebase false"
su - "$SESSION_USER" -c "git config --global --replace-all safe.directory '${WORKSPACE_DIR}'"
su - "$AGENT_USER" -c "git config --global --replace-all safe.directory '${WORKSPACE_DIR}'"

# Coding/test processes own the checkout; the publisher remains in the shared
# group and writes with a cooperative umask. Publisher secrets stay in its
# private home and are not readable by squad-agent.
chown -R "$AGENT_USER":"$SHARED_GROUP" "$WORKSPACE_DIR"
find "$WORKSPACE_DIR" -type d -exec chmod g+rws {} +
find "$WORKSPACE_DIR" -type f -exec chmod g+rw {} +

# ---------------------------------------------------------------------------
# Write workspace environment file. Values are shell-escaped because literal
# verification commands may contain spaces and operators such as &&. Sourcing
# this file must assign those commands, never execute them.
# ---------------------------------------------------------------------------
write_workspace_export() {
  local key="$1"
  local value="$2"
  printf 'export %s=%q\n' "$key" "$value"
}

{
  write_workspace_export WORKSPACE_DIR "$WORKSPACE_DIR"
  write_workspace_export WORKER_ID "$WORKER_ID"
  write_workspace_export GITHUB_OWNER "${GITHUB_OWNER:-}"
  write_workspace_export GITHUB_REPO "${GITHUB_REPO:-}"
  write_workspace_export REPO_BRANCH "${REPO_BRANCH:-main}"
  write_workspace_export GH_APP_ID "${GH_APP_ID:-}"
  write_workspace_export GH_APP_INSTALL_ID "${GH_APP_INSTALL_ID:-}"
  write_workspace_export GH_APP_PEM_FILE "${GH_APP_PEM_FILE:-/run/secrets/gh-app-key.pem}"
  write_workspace_export POLL_INTERVAL "${POLL_INTERVAL:-60}"
  write_workspace_export COPILOT_PAT "${COPILOT_PAT:-}"
  write_workspace_export COPILOT_MODEL "${COPILOT_MODEL:-}"
  write_workspace_export COPILOT_EFFORT "${COPILOT_EFFORT:-}"
  write_workspace_export COPILOT_CONTEXT "${COPILOT_CONTEXT:-}"
  write_workspace_export LOOP_AUTONOMOUS "${LOOP_AUTONOMOUS:-false}"
  write_workspace_export LOOP_CRITIC "${LOOP_CRITIC:-false}"
  write_workspace_export LOOP_CRITIC_MODEL "${LOOP_CRITIC_MODEL:-}"
  write_workspace_export LOOP_VERIFY "${LOOP_VERIFY:-off}"
  write_workspace_export LOOP_MAX_RETRIES "${LOOP_MAX_RETRIES:-2}"
  write_workspace_export LOOP_MAX_PRS_PER_DAY "${LOOP_MAX_PRS_PER_DAY:-0}"
  write_workspace_export LOOP_MAX_OPEN_AUTO_ISSUES "${LOOP_MAX_OPEN_AUTO_ISSUES:-3}"
  write_workspace_export LOOP_GOAL_FILE "${LOOP_GOAL_FILE:-auto}"
  write_workspace_export LOOP_WORK_SCOPE "${LOOP_WORK_SCOPE:-all}"
  write_workspace_export LOOP_CRITIC_RUBRIC "${LOOP_CRITIC_RUBRIC:-auto}"
  write_workspace_export LOOP_IMPLEMENTER "${LOOP_IMPLEMENTER:-plain}"
} > /home/$SESSION_USER/.workspace_env
chown "$SESSION_USER":"$SHARED_GROUP" /home/$SESSION_USER/.workspace_env
chmod 600 /home/$SESSION_USER/.workspace_env

# Existing workspace volumes may contain legacy tokenized remotes or
# repository-controlled hooks/helpers from older worker versions. Rebuild the
# local Git config from trusted values before the loop can perform any action.
if [[ -d "$WORKSPACE_DIR/.git" ]]; then
  su - "$SESSION_USER" -c "source /home/$SESSION_USER/.workspace_env && source /home/$SESSION_USER/worker-loop.sh && sanitize_repository_git_config" \
    || { echo "ERROR: failed to sanitize persisted repository Git configuration"; exit 1; }
fi

# ---------------------------------------------------------------------------
# Drop to copilot user and exec the worker loop
# ---------------------------------------------------------------------------
echo ">>> [${WORKER_ID}] Starting services..."

# SSH server
if [[ ! -f /etc/ssh/ssh_host_ed25519_key ]]; then
  echo ">>> Generating SSH host keys..."
  ssh-keygen -A
fi
echo ">>> Starting SSH server on port 22..."
/usr/sbin/sshd

ENABLE_TTYD="${ENABLE_TTYD:-false}"

if [[ "$ENABLE_TTYD" == "true" ]]; then
  # ---------------------------------------------------------------------------
  # TTYD mode: worker loop in tmux, ttyd as foreground process
  # ---------------------------------------------------------------------------
  echo ">>> Starting nginx (toolbar proxy) on port 8080..."
  nginx

  TTYD_PORT="${TTYD_PORT:-7681}"
  WORKER_LOG="/tmp/worker.log"
  touch "$WORKER_LOG"
  chown "$SESSION_USER":"$SHARED_GROUP" "$WORKER_LOG"

  echo ">>> Starting worker loop in tmux session..."
  su - "$SESSION_USER" -c "source /home/$SESSION_USER/.workspace_env && tmux new-session -d -s worker '/home/$SESSION_USER/worker-loop.sh 2>&1 | tee $WORKER_LOG; exec bash'"

  # Background tail to forward worker log to PID 1 stdout (docker logs)
  tail -f "$WORKER_LOG" &

  echo ">>> Starting ttyd on port ${TTYD_PORT} (internal)..."
  exec ttyd \
    --port "$TTYD_PORT" \
    --writable \
    --max-clients 5 \
    --ping-interval 30 \
    --base-path / \
    --client-option enableWebGL=false \
    --client-option fontSize=14 \
    bash -c "cd $WORKSPACE_DIR && exec sudo -u $SESSION_USER -i tmux attach-session -t worker"
else
  # ---------------------------------------------------------------------------
  # Headless mode: worker loop as PID 1 (output goes directly to docker logs)
  # ---------------------------------------------------------------------------
  echo ">>> TTYD disabled (set ENABLE_TTYD=true to enable)"
  echo ">>> [${WORKER_ID}] Launching worker loop as ${SESSION_USER}..."
  exec su - "$SESSION_USER" -c "source /home/$SESSION_USER/.workspace_env && exec /home/$SESSION_USER/worker-loop.sh"
fi
