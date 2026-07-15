#!/usr/bin/env bash
# Check whether a worker can access failed Actions run logs.
# Requires explicit arguments or environment variables.
set -euo pipefail

: "${WORKER_CONTAINER:?WORKER_CONTAINER is required}"
: "${REPO_SLUG:?REPO_SLUG is required (owner/repo)}"
: "${BRANCH_NAME:?BRANCH_NAME is required}"

ENV_FILE="${ENV_FILE:-.env.workers}"

image=$(docker inspect -f '{{.Config.Image}}' "$WORKER_CONTAINER")
pem=$(sed -n 's/^GH_APP_PEM_FILE=//p' "$ENV_FILE" | head -1)
test -f "$pem"
token=$(docker run --rm \
  --env-file "$ENV_FILE" \
  -e GH_APP_PEM_FILE=/run/secrets/gh-app-key.pem \
  -v "$pem":/run/secrets/gh-app-key.pem:ro \
  --entrypoint /home/copilot/generate-token.sh \
  "$image")

runs=$(GH_TOKEN="$token" gh run list --repo "$REPO_SLUG" --branch "$BRANCH_NAME" --status failure \
  --limit 3 --json databaseId,name,conclusion)
count=$(printf '%s' "$runs" | jq 'length')
echo "Failed Actions runs accessible: ${count}"
if [[ "$count" -gt 0 ]]; then
  run_id=$(printf '%s' "$runs" | jq -r '.[0].databaseId')
  GH_TOKEN="$token" gh run view "$run_id" --repo "$REPO_SLUG" --log-failed >/dev/null
  echo "Failed Actions logs accessible: yes"
fi
