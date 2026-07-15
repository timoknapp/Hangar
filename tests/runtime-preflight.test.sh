#!/usr/bin/env bash
# Container-level adversarial checks for the publisher/coding-user boundary.
set -euo pipefail

: "${WORKER_CONTAINER:?WORKER_CONTAINER is required}"

container="$WORKER_CONTAINER"
workspace="${WORKSPACE_DIR_IN_CONTAINER:-/workspace/repo}"

test "$(docker exec "$container" id -gn copilot)" = squad
test "$(docker exec "$container" id -gn squad-agent)" = squad
docker exec -u squad-agent "$container" test ! -r /home/copilot/.gh-app-key.pem
docker exec -u squad-agent "$container" test ! -r /home/copilot/.github-app-token

token_before=$(docker exec -u copilot "$container" cat /home/copilot/.github-app-token)
docker exec -u squad-agent "$container" ln -sf \
  /home/copilot/.github-app-token "$workspace/.squad/pr-summary.md"
docker exec -u copilot "$container" bash -c \
  "source /home/copilot/.workspace_env; source /home/copilot/worker-loop.sh; PR_EXECUTIVE_SUMMARY=stale; prepare_pr_summary; test -z \"\$PR_EXECUTIVE_SUMMARY\"; test ! -e '$workspace/.squad/pr-summary.md'"
token_after=$(docker exec -u copilot "$container" cat /home/copilot/.github-app-token)
test "$token_before" = "$token_after"

docker exec -u copilot "$container" bash -c \
  'source /home/copilot/.workspace_env; source /home/copilot/worker-loop.sh; run_agent_command "/usr/bin/tail -f /dev/null >/dev/null 2>&1 &"'
if docker exec "$container" pgrep -u squad-agent >/dev/null 2>&1; then
  echo "live squad-agent process survived cleanup" >&2
  exit 1
fi

echo "Worker runtime isolation: PASS"
