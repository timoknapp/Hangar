#!/usr/bin/env bash
# Deploy (recreate) specific workers by ID. Checks active claims for each
# unique repo before recreation. Replaces the old deploy-workers-3-4.remote.sh.
# Usage: deploy-workers.remote.sh <worker-id> [worker-id...]
# Example: deploy-workers.remote.sh 3 4
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <worker-id> [worker-id...]" >&2
  echo "Example: $0 3 4" >&2
  exit 1
fi

WORKER_IDS=("$@")
LOCK_DIR="/tmp/hangar-worker-deploy-${WORKER_IDS[*]// /-}.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "ERROR: another deployment for workers ${WORKER_IDS[*]} is active" >&2
  exit 1
fi
trap 'rmdir "$LOCK_DIR"' EXIT

export PAGER=cat
export GIT_PAGER=cat
export GH_PAGER=cat
export BUILDKIT_PROGRESS=plain
export COMPOSE_PROGRESS=plain

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.workers.yml}"
ENV_FILE="${ENV_FILE:-.env.workers}"
REPOS_JSON="${REPOS_JSON:-repos.json}"

copilot_pat=$(sed -n 's/^COPILOT_PAT=//p' "$ENV_FILE" | head -1)
case "$copilot_pat" in
  github_pat_*);;
  *)
    echo "ERROR: COPILOT_PAT must be a fine-grained token with only Copilot Requests permission" >&2
    exit 1
    ;;
esac

./deploy.sh generate
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" config -q

# Get a reference container to derive the image
first_worker="${WORKER_IDS[0]}"
ref_container="squad-worker-${first_worker}"
image=$(docker inspect -f '{{.Config.Image}}' "$ref_container" 2>/dev/null || true)
if [[ -z "$image" ]]; then
  echo "INFO: container $ref_container not running; using build image" >&2
  image="squad-worker:latest"
fi

pem=$(sed -n 's/^GH_APP_PEM_FILE=//p' "$ENV_FILE" | head -1)
test -f "$pem" || { echo "ERROR: PEM file not found: $pem" >&2; exit 1; }

# Check claims for each unique repo used by the target workers
checked_repos=()
for wid in "${WORKER_IDS[@]}"; do
  worker_key="worker-${wid}"
  repo_owner=$(jq -r --arg w "$worker_key" '.[$w].owner' "$REPOS_JSON")
  repo_name=$(jq -r --arg w "$worker_key" '.[$w].repo' "$REPOS_JSON")
  repo_slug="${repo_owner}/${repo_name}"

  # Skip if already checked this repo
  for checked in "${checked_repos[@]+"${checked_repos[@]}"}"; do
    [[ "$checked" == "$repo_slug" ]] && continue 2
  done
  checked_repos+=("$repo_slug")

  token=$(docker run --rm \
    --env-file "$ENV_FILE" \
    -e GH_APP_PEM_FILE=/run/secrets/gh-app-key.pem \
    -v "$pem":/run/secrets/gh-app-key.pem:ro \
    --entrypoint /home/copilot/generate-token.sh \
    "$image")
  claim_count=$(GH_TOKEN="$token" gh api \
    "repos/${repo_slug}/git/matching-refs/heads/squad-claims" --jq length)

  echo "Predeploy active claims for ${repo_slug}: ${claim_count}"
  if [[ "$claim_count" -ne 0 ]]; then
    echo "ERROR: ${repo_slug} has ${claim_count} active claims; wait for completion" >&2
    exit 1
  fi
done

# Recreate the target workers
services=()
for wid in "${WORKER_IDS[@]}"; do
  services+=("squad-worker-${wid}")
done

CACHE_BUST=$(date +%s) docker compose \
  -f "$COMPOSE_FILE" \
  --env-file "$ENV_FILE" \
  up -d --build "${services[@]}"

echo "Workers ${WORKER_IDS[*]} recreated successfully"
