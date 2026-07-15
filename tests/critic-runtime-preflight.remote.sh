#!/usr/bin/env bash
# Prove the independent read-only critic can launch through the guarded runtime.
set -euo pipefail

: "${WORKER_CONTAINER:?WORKER_CONTAINER is required}"
container="$WORKER_CONTAINER"
output_file=$(mktemp)
trap 'rm -f "$output_file"' EXIT

if docker exec "$container" pgrep -u squad-agent >/dev/null 2>&1; then
  echo "ERROR: squad-agent already has a live process; refusing to collide with worker activity" >&2
  exit 1
fi

if ! docker exec -u copilot "$container" bash -c '
  set -euo pipefail
  source /home/copilot/.workspace_env
  source /home/copilot/worker-loop.sh
  prompt="Respond with exactly these two lines:
VERDICT: APPROVE
- Critic runtime preflight."
  critic_args=(
    -p "$prompt"
    --allow-all-tools
    --silent
    --stream off
    "${COPILOT_COMMON_ARGS[@]}"
    "${COPILOT_READ_ONLY_ARGS[@]}"
  )
  critic_model="${LOOP_CRITIC_MODEL:-${COPILOT_MODEL:-}}"
  [[ -n "$critic_model" ]] && critic_args+=(--model "$critic_model")
  run_agent_copilot "$COPILOT_PAT" "${critic_args[@]}"
' >"$output_file" 2>&1; then
  cat "$output_file" >&2
  exit 1
fi

first_line=$(awk 'NF { sub(/\r$/, ""); print; exit }' "$output_file")
[[ "$first_line" == "VERDICT: APPROVE" ]] || {
  cat "$output_file" >&2
  echo "ERROR: critic did not return an approval verdict first" >&2
  exit 1
}
echo "Independent critic runtime preflight: PASS"
