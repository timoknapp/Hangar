#!/usr/bin/env bash
set -euo pipefail

: "${WORKER_CONTAINER:?WORKER_CONTAINER is required}"
container="$WORKER_CONTAINER"
since="${SINCE:-30m}"
logs=$(docker logs --since "$since" "$container" 2>&1)

printf '%s' "$logs" | grep -q 'implementer=squad' \
  || { echo "ERROR: Squad implementer mode not present in logs" >&2; exit 1; }
printf '%s' "$logs" | grep -Eq 'Running copilot squad (implementation|revision) session' \
  || { echo "ERROR: no full Squad implementation session observed" >&2; exit 1; }
printf '%s' "$logs" | grep -q 'Squad v' \
  || { echo "ERROR: Squad coordinator startup was not observed" >&2; exit 1; }

if printf '%s' "$logs" | grep -q 'Permission to run this tool was denied'; then
  echo "ERROR: full Squad session encountered a denied tool" >&2
  exit 1
fi
if printf '%s' "$logs" | grep -q 'Permission to access this URL was denied'; then
  echo "ERROR: full Squad session encountered a denied URL" >&2
  exit 1
fi

processes=$(docker exec "$container" ps -o args= -u squad-agent 2>/dev/null || true)
if [[ -n "$processes" ]] && printf '%s' "$processes" | grep -q '[c]opilot'; then
  printf '%s' "$processes" | grep -q -- '--agent squad' \
    || { echo "ERROR: active implementation Copilot process lacks --agent squad" >&2; exit 1; }
fi

echo "Full Squad session behavior: PASS"
