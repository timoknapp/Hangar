#!/usr/bin/env bash
# Controlled live proof that full Squad can use shell, delegation, web research,
# and repository MCP tools without publisher credentials or the real clone.
# Requires: WORKER_CONTAINER (defaults to first Squad worker found in repos.json)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_JSON="${REPOS_JSON:-repos.json}"

# Determine container from args or first squad worker in config
if [[ -n "${WORKER_CONTAINER:-}" ]]; then
  container="$WORKER_CONTAINER"
else
  first_squad_worker=$(jq -r 'to_entries[] | select(.value.loop.implementer == "squad") | .key' "$REPOS_JSON" | head -1)
  [[ -n "$first_squad_worker" ]] || { echo "ERROR: no squad worker found in repos.json" >&2; exit 1; }
  container="squad-${first_squad_worker}"
fi

# Derive workspace from container env
source_workspace=$(docker exec -u copilot "$container" printenv WORKSPACE_DIR 2>/dev/null || echo "/workspace/repo")
probe_dir="/tmp/squad-capability-$RANDOM-$$"
output_file=$(mktemp)
config_file=$(mktemp)

cleanup() {
  rm -f "$output_file"
  rm -f "$config_file"
  docker exec "$container" rm -rf "$probe_dir" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if docker exec "$container" pgrep -u squad-agent >/dev/null 2>&1; then
  echo "ERROR: squad-agent already has a live process; refusing to collide with worker activity" >&2
  exit 1
fi

docker exec -u squad-agent "$container" git \
  -c core.hooksPath=/dev/null \
  clone --shared "$source_workspace" "$probe_dir" >/dev/null
jq --arg script "$probe_dir/.squad-capability-mcp.mjs" \
  '.mcpServers["capability-probe"].args = [$script]' \
  "$script_dir/fixtures/squad-mcp-config.json" > "$config_file"
docker cp "$config_file" "$container:$probe_dir/.mcp.json"
docker cp "$script_dir/fixtures/squad-capability-mcp.mjs" "$container:$probe_dir/.squad-capability-mcp.mjs"
docker exec "$container" chown -R squad-agent:squad "$probe_dir"
docker exec "$container" chmod -R g+rwX "$probe_dir"

if ! docker exec -u copilot "$container" bash -c '
  set -euo pipefail
  probe_dir=$1
  source /home/copilot/.workspace_env
  source /home/copilot/worker-loop.sh
  test "$LOOP_IMPLEMENTER" = squad
  prompt="Capability preflight only; work in this disposable clone and do not contact GitHub.

You MUST complete all five checks:
1. Use the shell tool to run: printf \"SQUAD_SHELL_OK\\n\" > .squad-capability-shell
2. Use the shell tool to inspect readable /proc/[0-9]*/environ files and process command lines. Only if no environment contains a variable named COPILOT_GITHUB_TOKEN, GITHUB_TOKEN, GH_TOKEN, or COPILOT_PAT and no command line contains a PAT-looking github_pat_ value, write SQUAD_SECRET_ISOLATION_OK to .squad-capability-secret-isolation. Never print any environment or token value.
3. Use the task tool to delegate to one real project roster agent. That delegated agent must create .squad-capability-delegated with exactly SQUAD_DELEGATION_OK followed by a newline. The coordinator must not create this file itself.
4. Fetch https://example.com with the web/URL tool and confirm that the page title is Example Domain.
5. Call the capability_marker tool from the repository-configured capability-probe MCP server and confirm it returns SQUAD_MCP_OK.

After the delegated task has completed and the file exists, respond with these exact final lines:
SQUAD_ORCHESTRATOR_OK
SQUAD_SHELL_OK
SQUAD_SECRET_ISOLATION_OK
SQUAD_DELEGATION_OK
SQUAD_WEB_OK
SQUAD_MCP_OK"
  args=(
    "${IMPLEMENTER_AGENT_ARGS[@]}"
    -C "$probe_dir"
    -p "$prompt"
    --allow-all-tools
    "${COPILOT_COMMON_ARGS[@]}"
    "${COPILOT_IMPLEMENTER_POLICY_ARGS[@]}"
    --additional-mcp-config "@$probe_dir/.mcp.json"
  )
  [[ -n "$COPILOT_MODEL" ]] && args+=(--model "$COPILOT_MODEL")
  [[ -n "$COPILOT_EFFORT" ]] && args+=(--effort "$COPILOT_EFFORT")
  [[ -n "$COPILOT_CONTEXT" ]] && args+=(--context "$COPILOT_CONTEXT")
  run_agent_copilot "$COPILOT_PAT" "${args[@]}"
' bash "$probe_dir" >"$output_file" 2>&1; then
  cat "$output_file" >&2
  exit 1
fi

for marker in SQUAD_ORCHESTRATOR_OK SQUAD_SHELL_OK SQUAD_SECRET_ISOLATION_OK SQUAD_DELEGATION_OK SQUAD_WEB_OK SQUAD_MCP_OK; do
  grep -q "$marker" "$output_file" \
    || { cat "$output_file" >&2; echo "ERROR: missing $marker" >&2; exit 1; }
done

echo "Squad capability preflight: PASS"
