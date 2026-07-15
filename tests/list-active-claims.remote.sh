#!/usr/bin/env bash
# Report active worker claim refs and processing issues. Never prints tokens.
# All parameters are required explicitly.
set -euo pipefail

: "${WORKER_CONTAINER:?WORKER_CONTAINER is required}"
: "${REPO_SLUG:?REPO_SLUG is required (owner/repo)}"

ENV_FILE="${ENV_FILE:-.env.workers}"

image=$(docker inspect -f '{{.Config.Image}}' "$WORKER_CONTAINER")
pem=$(sed -n 's/^GH_APP_PEM_FILE=//p' "$ENV_FILE" | head -1)

token=$(docker run --rm \
  --env-file "$ENV_FILE" \
  -e GH_APP_PEM_FILE=/run/secrets/gh-app-key.pem \
  -v "$pem":/run/secrets/gh-app-key.pem:ro \
  --entrypoint /home/copilot/generate-token.sh \
  "$image")

GH_TOKEN="$token" gh api \
  "repos/${REPO_SLUG}/git/matching-refs/heads/squad-claims" \
  --jq '.[] | .ref'
GH_TOKEN="$token" gh issue list \
  --repo "$REPO_SLUG" \
  --state open \
  --label squad:processing \
  --json number,title,labels \
  --jq '.[] | {number, title, labels: [.labels[].name]}'
