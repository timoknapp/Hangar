#!/usr/bin/env bash
# Clean an interrupted worker claim and leave the issue queued for revision.
# All parameters required explicitly.
set -euo pipefail

: "${ISSUE_NUMBER:?ISSUE_NUMBER is required}"
: "${REPO_SLUG:?REPO_SLUG is required (owner/repo)}"
: "${WORKER_CONTAINER:?WORKER_CONTAINER is required}"

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
export GH_TOKEN="$token"

claim_ref="heads/squad-claims/issue-${ISSUE_NUMBER}"
if gh api "repos/${REPO_SLUG}/git/ref/${claim_ref}" >/dev/null 2>&1; then
  gh api --method DELETE "repos/${REPO_SLUG}/git/refs/${claim_ref}" >/dev/null
fi

gh issue edit "$ISSUE_NUMBER" --repo "$REPO_SLUG" \
  --remove-label squad:processing \
  --add-label squad:revision >/dev/null

labels=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO_SLUG" --json labels --jq '[.labels[].name]')
printf '%s' "$labels" | jq -e 'index("squad:revision") != null and index("squad:processing") == null' >/dev/null

echo "Issue #${ISSUE_NUMBER} prepared for a clean revision retry"
