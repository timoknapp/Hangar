#!/usr/bin/env bash
# Verify Copilot exposes a repository-configured MCP tool natively.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${WORKER_CONTAINER:?WORKER_CONTAINER is required}"
container="$WORKER_CONTAINER"
workspace="${MCP_WORKSPACE:-/tmp/mcp-capability-$RANDOM-$$}"
output_file=$(mktemp)
config_file=$(mktemp)

cleanup() {
  rm -f "$output_file"
  rm -f "$config_file"
  docker exec "$container" rm -rf "$workspace" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker exec "$container" mkdir -p "$workspace"
jq --arg script "$workspace/.squad-capability-mcp.mjs" \
  '.mcpServers["capability-probe"].args = [$script]' \
  "$script_dir/fixtures/squad-mcp-config.json" > "$config_file"
docker cp "$config_file" "$container:$workspace/.mcp.json"
docker cp "$script_dir/fixtures/squad-capability-mcp.mjs" "$container:$workspace/.squad-capability-mcp.mjs"
docker exec "$container" chown -R squad-agent:squad "$workspace"

if ! docker exec -u copilot "$container" bash -c '
  set -euo pipefail
  workspace=$1
  source /home/copilot/.workspace_env
  source /home/copilot/worker-loop.sh
  prompt="Call the capability_marker tool from the capability-probe MCP server. Do not use shell or file-reading tools to inspect or invoke the server. Respond with exactly the tool result."
  common_args=()
  for arg in "${COPILOT_COMMON_ARGS[@]}"; do
    [[ "$arg" == "--disable-builtin-mcps" ]] || common_args+=("$arg")
  done
  run_agent_copilot "$COPILOT_PAT" \
    -C "$workspace" \
    -p "$prompt" \
    --allow-all-tools \
    --silent \
    --stream off \
    "${common_args[@]}" \
    --disable-mcp-server github-mcp-server \
    --additional-mcp-config "@$workspace/.mcp.json" \
    --allow-all-mcp-server-instructions \
    --deny-tool=shell \
    --deny-tool=write \
    --deny-tool=url
  ' bash "$workspace" >"$output_file" 2>&1; then
  cat "$output_file" >&2
    docker exec -u squad-agent "$container" \
      cat "$workspace/.squad-capability-mcp-diagnostic" >&2 2>/dev/null || true
  exit 1
fi

grep -qx 'SQUAD_MCP_OK' "$output_file" \
  || {
    cat "$output_file" >&2
    docker exec -u squad-agent "$container" \
      cat "$workspace/.squad-capability-mcp-diagnostic" >&2 2>/dev/null || true
    echo "ERROR: repository MCP tool was not exposed natively" >&2
    exit 1
  }

echo "Native repository MCP capability: PASS"
