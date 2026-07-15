#!/usr/bin/env bash
# =============================================================================
# remote-deploy.sh — Run deploy.sh on the docker host from your laptop
#
# Why this exists:
#   deploy.sh edits repos.json, regenerates docker-compose.workers.yml, and
#   talks to the local Docker daemon. All of that has to happen ON the docker
#   host. This wrapper SSHes in and runs deploy.sh there.
#
# Usage:
#   ./remote-deploy.sh sync                       # Push local deploy.sh + repos.json to host
#   ./remote-deploy.sh <deploy.sh args...>        # Run deploy.sh remotely
#   ./remote-deploy.sh sync-and <deploy.sh args>  # Sync first, then run
#
# Examples:
#   ./remote-deploy.sh status
#   ./remote-deploy.sh set-model <supported-model-id>
#   ./remote-deploy.sh sync-and set-model <supported-model-id>
#
# Configuration (override via env or .env.remote):
#   REMOTE_HOST   SSH host alias               (required — no default)
#   REMOTE_PATH   Path to hangar on remote     (default: ~/hangar)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Optional per-user overrides
if [[ -f "$SCRIPT_DIR/.env.remote" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env.remote"
fi

REMOTE_HOST="${REMOTE_HOST:?REMOTE_HOST is required. Set in .env.remote or environment.}"
REMOTE_PATH="${REMOTE_PATH:-~/hangar}"

# Files to push during `sync`. Keep this list intentionally narrow — we do
# NOT sync .env.workers (host-specific secrets) or the auto-generated compose
# file (deploy.sh regenerates it on the host).
SYNC_FILES=(
  deploy.sh
  Dockerfile
  entrypoint.sh
  auth-setup.sh
  repo-add.sh
  bashrc
  nginx.conf
  tmux.conf
  toolbar.js
  worker
)

# repos.json is gitignored but synced when present (operator-specific fleet config)
if [[ -f "$SCRIPT_DIR/repos.json" ]]; then
  SYNC_FILES+=(repos.json)
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
have_rsync() {
  command -v rsync >/dev/null 2>&1 &&
    ssh "$REMOTE_HOST" 'command -v rsync >/dev/null 2>&1'
}

do_sync() {
  local f
  local sync_sources=()
  for f in "${SYNC_FILES[@]}"; do
    sync_sources+=("$SCRIPT_DIR/$f")
  done

  echo ">>> Syncing local files to ${REMOTE_HOST}:${REMOTE_PATH} ..."
  if have_rsync; then
    rsync -avz --delete-excluded \
      --exclude='.env*' \
      --exclude='docker-compose.workers.yml' \
      "${sync_sources[@]}" \
      "${REMOTE_HOST}:${REMOTE_PATH}/"
  else
    echo ">>> rsync unavailable locally or remotely, falling back to scp"
    for f in "${SYNC_FILES[@]}"; do
      if [[ -d "$SCRIPT_DIR/$f" ]]; then
        # Match rsync's replacement behavior so deleted scripts cannot survive
        # indefinitely on hosts where rsync is unavailable.
        # shellcheck disable=SC2029 # REMOTE_PATH and SYNC_FILES are trusted configuration/constants.
        ssh "$REMOTE_HOST" "rm -rf ${REMOTE_PATH}/${f}"
      fi
      scp -r "$SCRIPT_DIR/$f" "${REMOTE_HOST}:${REMOTE_PATH}/"
    done
  fi
  # Ensure deploy.sh stays executable on the host
  # shellcheck disable=SC2029 # REMOTE_PATH is intentionally expanded from trusted local config.
  ssh "$REMOTE_HOST" "chmod +x ${REMOTE_PATH}/deploy.sh"
  echo ">>> Sync complete."
}

run_remote() {
  # All args are passed verbatim to deploy.sh on the host.
  # We use `printf %q` to preserve quoting for values like model names.
  local quoted=""
  for a in "$@"; do
    quoted+=" $(printf '%q' "$a")"
  done
  echo ">>> Running on ${REMOTE_HOST}: ./deploy.sh${quoted}"
  ssh -t "$REMOTE_HOST" "cd ${REMOTE_PATH} && ./deploy.sh${quoted}"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
CMD="${1:-help}"

case "$CMD" in
  sync)
    do_sync
    ;;

  sync-and)
    shift
    if [[ $# -eq 0 ]]; then
      echo "ERROR: sync-and requires a deploy.sh subcommand"
      exit 1
    fi
    do_sync
    run_remote "$@"
    ;;

  help|-h|--help)
    sed -n '2,/^# =\{20,\}/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;

  *)
    # Pass through everything to remote deploy.sh
    run_remote "$@"
    ;;
esac
