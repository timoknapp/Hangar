#!/usr/bin/env bash
# Diagnose a worker issue: show container state, recent logs, git state, and
# GitHub issue/PR info. All parameters are required explicitly.
set -euo pipefail

: "${WORKER_CONTAINER:?WORKER_CONTAINER is required}"
: "${ISSUE_NUMBER:?ISSUE_NUMBER is required}"
: "${REPO_SLUG:?REPO_SLUG is required (owner/repo)}"

repo_name="${REPO_SLUG#*/}"
workspace="${WORKSPACE_DIR_IN_CONTAINER:-/workspace/${repo_name}}"

echo "=== container ==="
docker inspect -f 'status={{.State.Status}} started={{.State.StartedAt}} restarts={{.RestartCount}}' "$WORKER_CONTAINER"
printf 'autonomous=%s critic=%s model=%s\n' \
  "$(docker exec "$WORKER_CONTAINER" printenv LOOP_AUTONOMOUS)" \
  "$(docker exec "$WORKER_CONTAINER" printenv LOOP_CRITIC)" \
  "$(docker exec "$WORKER_CONTAINER" printenv LOOP_CRITIC_MODEL)"

echo "=== recent worker events ==="
docker logs --since 20m "$WORKER_CONTAINER" 2>&1 \
  | grep -E 'Processing|Claimed|revision|Copilot|Verify|Critic|PR |Successfully|failed|ERROR|No issues|Daily PR|Permission' \
  | tail -120 || true

echo "=== local git state ==="
docker exec -u copilot "$WORKER_CONTAINER" bash -c \
  "source /home/copilot/.workspace_env; source /home/copilot/worker-loop.sh; cd '$workspace'; sanitize_repository_git_config; printf 'branch='; git branch --show-current; git status --short; git log --oneline --decorate -5"

echo "=== GitHub issue / PR ==="
token=$(docker exec -u copilot "$WORKER_CONTAINER" bash -c \
  'source /home/copilot/.workspace_env; /home/copilot/generate-token.sh')
GH_TOKEN="$token" gh issue view "$ISSUE_NUMBER" --repo "$REPO_SLUG" \
  --json number,title,state,labels,comments \
  --jq '{number,title,state,labels:[.labels[].name],recentComments:[.comments[-5:][] | {author:.author.login,body:.body,createdAt}]}'
GH_TOKEN="$token" gh pr list --repo "$REPO_SLUG" --state all --search "#${ISSUE_NUMBER}" \
  --json number,title,state,isDraft,headRefName,baseRefName,url \
  --jq '.'
