#!/usr/bin/env bash
# Prove the model-only PAT cannot reach repository mutation endpoints.
# Requires: WORKER_CONTAINER and REPO_SLUG as arguments or env vars.
set -euo pipefail

: "${WORKER_CONTAINER:?WORKER_CONTAINER is required (e.g. squad-worker-1)}"
: "${REPO_SLUG:?REPO_SLUG is required (e.g. owner/repo)}"

check_denied() {
  local label="$1"
  local endpoint="$2"
  local code
  code=$(docker exec "$WORKER_CONTAINER" sh -c '
    endpoint=$1
    curl --silent --show-error --output /dev/null --write-out "%{http_code}" \
      --request POST \
      --header "Accept: application/vnd.github+json" \
      --header "Authorization: Bearer ${COPILOT_PAT}" \
      --header "X-GitHub-Api-Version: 2022-11-28" \
      --data "{}" \
      "https://api.github.com/${endpoint}"
  ' sh "repos/${REPO_SLUG}/${endpoint}")

  case "$code" in
    401|403|404)
      printf '%s: denied (%s)\n' "$label" "$code"
      ;;
    *)
      echo "ERROR: Copilot PAT reached ${label} mutation endpoint (HTTP ${code}); rotate it with only Copilot Requests permission" >&2
      return 1
      ;;
  esac
}

check_denied "Git refs" "git/refs"
check_denied "Issues" "issues"
check_denied "Pull requests" "pulls"

echo "Copilot token publication boundary: PASS"
