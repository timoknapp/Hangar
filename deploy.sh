#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Generate docker-compose.workers.yml from repos.json and run it
#
# Usage:
#   ./deploy.sh up                  # Generate compose file and start all workers
#   ./deploy.sh down                # Tear down all workers
#   ./deploy.sh restart [N]         # Restart a specific worker (e.g. ./deploy.sh restart 3)
#   ./deploy.sh reset [N]           # Delete workspace volume and restart worker N
#   ./deploy.sh generate            # Only generate the compose file (no docker action)
#   ./deploy.sh status              # Show running workers
#   ./deploy.sh set-model <model>   # Set Copilot model for ALL workers and recreate them
#
# Configuration:
#   repos.json      — Repo-to-worker assignment (only file you edit for fleet changes)
#   .env.workers    — Shared secrets (GH App, SSH key, Copilot PAT, ports)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_JSON="${REPOS_JSON:-$SCRIPT_DIR/repos.json}"
COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/docker-compose.workers.yml}"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.workers}"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if [[ ! -f "$REPOS_JSON" ]]; then
  echo "ERROR: repos.json not found at $REPOS_JSON"
  echo "  Copy from repos.example.json and customize:"
  echo "    cp ${SCRIPT_DIR}/repos.example.json ${REPOS_JSON}"
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env.workers not found at $ENV_FILE"
  echo "  Copy from .env.workers.example and fill in secrets:"
  echo "    cp ${SCRIPT_DIR}/.env.workers.example ${ENV_FILE}"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required. Install with: brew install jq"
  exit 1
fi

# ---------------------------------------------------------------------------
# Generate docker-compose.workers.yml from repos.json
# ---------------------------------------------------------------------------
generate_compose() {
  echo ">>> Generating $COMPOSE_FILE from repos.json..."

  local TTYD_PORT_BASE=7691
  local SSH_PORT_BASE=2231
  # shellcheck disable=SC2016 # Compose expands this expression from --env-file.
  local bind_address_value='${BIND_ADDRESS:-127.0.0.1}'
  [[ -n "${HANGAR_BIND_ADDRESS:-}" ]] && bind_address_value="$HANGAR_BIND_ADDRESS"

  # JSON string encoding is valid YAML double-quoted scalar encoding. Quote the
  # full KEY=value item so literal commands (spaces, &&, #, etc.) remain one
  # Compose environment value instead of being parsed as YAML syntax.
  yaml_quote() {
    jq -Rn --arg value "$1" '$value'
  }

  # Header
  cat > "$COMPOSE_FILE" <<'HEADER'
# =============================================================================
# docker-compose.workers.yml — AUTO-GENERATED from repos.json
# DO NOT EDIT — run ./deploy.sh to regenerate.
# =============================================================================

name: hangar-fleet

services:
HEADER

  local VOLUMES=""
  local INDEX=0

  # Iterate over worker IDs in order
  for WORKER_ID in $(jq -r 'keys[]' "$REPOS_JSON" | sort -V); do
    local NUM="${WORKER_ID#worker-}"
    local TTYD_PORT=$((TTYD_PORT_BASE + INDEX))
    local SSH_PORT=$((SSH_PORT_BASE + INDEX))
    local MODEL EFFORT CONTEXT
    MODEL=$(jq -r --arg w "$WORKER_ID" '.[$w].model // ""' "$REPOS_JSON")
    EFFORT=$(jq -r --arg w "$WORKER_ID" '.[$w].effort // ""' "$REPOS_JSON")
    CONTEXT=$(jq -r --arg w "$WORKER_ID" '.[$w].context // ""' "$REPOS_JSON")
    local LOOP_AUTONOMOUS LOOP_CRITIC LOOP_CRITIC_MODEL LOOP_VERIFY
    local LOOP_MAX_RETRIES LOOP_MAX_PRS_PER_DAY LOOP_MAX_OPEN_AUTO_ISSUES LOOP_GOAL_FILE
    local LOOP_WORK_SCOPE LOOP_CRITIC_RUBRIC LOOP_IMPLEMENTER
    LOOP_AUTONOMOUS=$(jq -r --arg w "$WORKER_ID" '.[$w].loop.autonomous // false' "$REPOS_JSON")
    LOOP_CRITIC=$(jq -r --arg w "$WORKER_ID" '.[$w].loop.critic // false' "$REPOS_JSON")
    LOOP_CRITIC_MODEL=$(jq -r --arg w "$WORKER_ID" '.[$w].loop.criticModel // ""' "$REPOS_JSON")
    LOOP_VERIFY=$(jq -r --arg w "$WORKER_ID" '.[$w].loop.verify // "off"' "$REPOS_JSON")
    LOOP_MAX_RETRIES=$(jq -r --arg w "$WORKER_ID" '.[$w].loop.maxRetries // 2' "$REPOS_JSON")
    LOOP_MAX_PRS_PER_DAY=$(jq -r --arg w "$WORKER_ID" '.[$w].loop.maxPrsPerDay // 0' "$REPOS_JSON")
    LOOP_MAX_OPEN_AUTO_ISSUES=$(jq -r --arg w "$WORKER_ID" '.[$w].loop.maxOpenAutoIssues // 3' "$REPOS_JSON")
    LOOP_GOAL_FILE=$(jq -r --arg w "$WORKER_ID" '.[$w].loop.goalFile // "auto"' "$REPOS_JSON")
    LOOP_WORK_SCOPE=$(jq -r --arg w "$WORKER_ID" '.[$w].loop.workScope // "all"' "$REPOS_JSON")
    LOOP_CRITIC_RUBRIC=$(jq -r --arg w "$WORKER_ID" '.[$w].loop.criticRubric // "auto"' "$REPOS_JSON")
    LOOP_IMPLEMENTER=$(jq -r --arg w "$WORKER_ID" '.[$w].loop.implementer // "plain"' "$REPOS_JSON")

    cat >> "$COMPOSE_FILE" <<EOF
  squad-${WORKER_ID}:
    build:
      context: worker
      dockerfile: Dockerfile
      args:
        CACHE_BUST: \${CACHE_BUST:-0}
    container_name: squad-${WORKER_ID}
    hostname: squad-${WORKER_ID}
    init: true
    restart: unless-stopped
    environment:
      - WORKER_ID=${WORKER_ID}
      - GH_APP_ID=\${GH_APP_ID}
      - GH_APP_INSTALL_ID=\${GH_APP_INSTALL_ID}
      - GH_APP_PEM_FILE=/run/secrets/gh-app-key.pem
      - POLL_INTERVAL=\${POLL_INTERVAL:-60}
      - ENABLE_TTYD=\${ENABLE_TTYD:-false}
      - AUTO_UPDATE_CLI=\${AUTO_UPDATE_CLI:-false}
      - SSH_AUTHORIZED_KEY=\${SSH_AUTHORIZED_KEY:-}
      - COPILOT_PAT=\${COPILOT_PAT:-}
      - $(yaml_quote "COPILOT_MODEL=${MODEL}")
      - $(yaml_quote "COPILOT_EFFORT=${EFFORT}")
      - $(yaml_quote "COPILOT_CONTEXT=${CONTEXT}")
      - $(yaml_quote "LOOP_AUTONOMOUS=${LOOP_AUTONOMOUS}")
      - $(yaml_quote "LOOP_CRITIC=${LOOP_CRITIC}")
      - $(yaml_quote "LOOP_CRITIC_MODEL=${LOOP_CRITIC_MODEL}")
      - $(yaml_quote "LOOP_VERIFY=${LOOP_VERIFY}")
      - $(yaml_quote "LOOP_MAX_RETRIES=${LOOP_MAX_RETRIES}")
      - $(yaml_quote "LOOP_MAX_PRS_PER_DAY=${LOOP_MAX_PRS_PER_DAY}")
      - $(yaml_quote "LOOP_MAX_OPEN_AUTO_ISSUES=${LOOP_MAX_OPEN_AUTO_ISSUES}")
      - $(yaml_quote "LOOP_GOAL_FILE=${LOOP_GOAL_FILE}")
      - $(yaml_quote "LOOP_WORK_SCOPE=${LOOP_WORK_SCOPE}")
      - $(yaml_quote "LOOP_CRITIC_RUBRIC=${LOOP_CRITIC_RUBRIC}")
      - $(yaml_quote "LOOP_IMPLEMENTER=${LOOP_IMPLEMENTER}")
    ports:
      - $(yaml_quote "${bind_address_value}:\${TTYD_PORT_W${NUM}:-${TTYD_PORT}}:8080")
      - $(yaml_quote "${bind_address_value}:\${SSH_PORT_W${NUM}:-${SSH_PORT}}:22")
    volumes:
      - squad-${WORKER_ID}-workspace:/workspace
      - squad-${WORKER_ID}-copilot-data:/home/copilot/.local/share
      - squad-${WORKER_ID}-sshd:/etc/ssh
      - \${GH_APP_PEM_FILE:?Set GH_APP_PEM_FILE in .env.workers}:/run/secrets/gh-app-key.pem:ro
      - ./repos.json:/etc/squad/repos.json:ro

EOF

    VOLUMES="${VOLUMES}  squad-${WORKER_ID}-workspace:\n"
    VOLUMES="${VOLUMES}  squad-${WORKER_ID}-copilot-data:\n"
    VOLUMES="${VOLUMES}  squad-${WORKER_ID}-sshd:\n"

    INDEX=$((INDEX + 1))
  done

  # Volumes section
  echo "volumes:" >> "$COMPOSE_FILE"
  printf '%b' "$VOLUMES" >> "$COMPOSE_FILE"

  echo ">>> Generated $COMPOSE_FILE with $INDEX worker(s)"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
CMD="${1:-help}"

case "$CMD" in
  generate)
    generate_compose
    ;;

  up)
    generate_compose
    echo ">>> Starting worker fleet..."
    docker compose -p hangar-fleet -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --build
    ;;

  down)
    echo ">>> Stopping worker fleet..."
    docker compose -p hangar-fleet -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down
    ;;

  restart)
    WORKER_NUM="${2:?Usage: ./deploy.sh restart <worker-number>}"
    generate_compose
    echo ">>> Restarting squad-worker-${WORKER_NUM}..."
    docker compose -p hangar-fleet -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --build "squad-worker-${WORKER_NUM}"
    ;;

  reset)
    WORKER_NUM="${2:?Usage: ./deploy.sh reset <worker-number>}"
    echo ">>> Resetting squad-worker-${WORKER_NUM} (deleting workspace volume)..."
    docker compose -p hangar-fleet -f "$COMPOSE_FILE" --env-file "$ENV_FILE" stop "squad-worker-${WORKER_NUM}" 2>/dev/null || true
    VOLUME_PREFIX="hangar-fleet"
    docker volume rm "${VOLUME_PREFIX}_squad-worker-${WORKER_NUM}-workspace" 2>/dev/null || \
    docker volume rm "squad-worker-${WORKER_NUM}-workspace" 2>/dev/null || \
      echo "WARNING: Could not find workspace volume. It may have a different prefix."
    generate_compose
    docker compose -p hangar-fleet -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --build "squad-worker-${WORKER_NUM}"
    ;;

  status)
    docker compose -p hangar-fleet -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps
    ;;

  set-model)
    NEW_MODEL="${2:?Usage: ./deploy.sh set-model <model>}"
    echo ">>> Setting model='${NEW_MODEL}' for ALL workers in repos.json..."
    TMP_FILE="$(mktemp)"
    jq --arg m "$NEW_MODEL" 'with_entries(.value.model = $m)' "$REPOS_JSON" > "$TMP_FILE"
    mv "$TMP_FILE" "$REPOS_JSON"
    echo ">>> repos.json updated."
    generate_compose
    echo ">>> Recreating workers to apply new COPILOT_MODEL..."
    docker compose -p hangar-fleet -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --force-recreate --no-build
    echo ">>> Done. All workers now running model: ${NEW_MODEL}"
    ;;

  *)
    echo "Usage: ./deploy.sh {up|down|restart N|reset N|generate|status|set-model <model>}"
    echo ""
    echo "  up                Generate compose from repos.json and start all workers"
    echo "  down              Stop all workers"
    echo "  restart N         Restart worker N (regenerates compose first)"
    echo "  reset N           Delete worker N's workspace volume and restart fresh"
    echo "  generate          Only regenerate docker-compose.workers.yml"
    echo "  status            Show running workers"
    echo "  set-model <model> Set Copilot model for ALL workers in repos.json and recreate them"
    exit 1
    ;;
esac
