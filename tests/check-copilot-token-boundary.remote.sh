#!/usr/bin/env bash
# Prove the model-only PAT cannot mutate repository state. Every request is a
# guaranteed collision or validation failure, so neither credential can create
# a ref, label, issue, or pull request. The write-capable App token is the
# positive control; an empty/malformed request is not an authorization test.
set -euo pipefail

: "${WORKER_CONTAINER:?WORKER_CONTAINER is required (e.g. squad-worker-1)}"
: "${REPO_SLUG:?REPO_SLUG is required (e.g. owner/repo)}"

docker exec -i -u copilot "$WORKER_CONTAINER" bash -s -- "$REPO_SLUG" <<'INNER'
set -euo pipefail

repo_slug="$1"
source /home/copilot/.workspace_env
[[ "$repo_slug" == "${GITHUB_OWNER}/${GITHUB_REPO}" ]]

publisher_token=$(cat /home/copilot/.github-app-token)
model_token="$COPILOT_PAT"
default_branch="$REPO_BRANCH"
default_ref="refs/heads/${default_branch}"
default_sha=$(GH_TOKEN="$publisher_token" gh api \
  "repos/${repo_slug}/git/ref/heads/${default_branch}" --jq '.object.sha')
[[ "$default_sha" =~ ^[0-9a-f]{40}$ ]]

headers=$(mktemp)
trap 'rm -f "$headers"' EXIT

request_status() {
  local token="$1"
  local endpoint="$2"
  local payload="$3"
  : > "$headers"
  printf 'header = "Authorization: Bearer %s"\n' "$token" \
    | curl --silent --show-error \
      --output /dev/null \
      --dump-header "$headers" \
      --write-out '%{http_code}' \
      --request POST \
      --header 'Accept: application/vnd.github+json' \
      --header 'Content-Type: application/json' \
      --header 'X-GitHub-Api-Version: 2022-11-28' \
      --data "$payload" \
      --config - \
      "https://api.github.com/repos/${repo_slug}/${endpoint}"
}

accepted_permissions() {
  tr -d '\r' < "$headers" \
    | awk 'BEGIN { IGNORECASE = 1 }
      /^x-accepted-github-permissions:/ {
        sub(/^[^:]*:[[:space:]]*/, "")
        value = $0
      }
      END { print value }'
}

assert_publisher_collision() {
  local label="$1"
  local endpoint="$2"
  local payload="$3"
  local code permissions
  code=$(request_status "$publisher_token" "$endpoint" "$payload")
  permissions=$(accepted_permissions)
  [[ "$code" == "422" ]] || {
    echo "ERROR: publisher positive control for ${label} returned HTTP ${code}, expected 422" >&2
    return 1
  }
  printf '%s publisher control: collision (%s; requires %s)\n' \
    "$label" "$code" "${permissions:-unknown}"
}

assert_model_denied() {
  local label="$1"
  local endpoint="$2"
  local payload="$3"
  local code permissions
  code=$(request_status "$model_token" "$endpoint" "$payload")
  permissions=$(accepted_permissions)
  case "$code" in
    401|403|404)
      printf '%s model token: denied (%s; requires %s)\n' \
        "$label" "$code" "${permissions:-unknown}"
      ;;
    *)
      echo "ERROR: model token reached ${label} write validation (HTTP ${code}); rotate it with only Copilot Requests permission" >&2
      return 1
      ;;
  esac
}

# Preconditions make the first two POSTs guaranteed duplicate collisions.
ref_before=$(GH_TOKEN="$publisher_token" gh api \
  "repos/${repo_slug}/git/ref/heads/${default_branch}" --jq '.object.sha')
[[ "$ref_before" == "$default_sha" ]]
label_before=$(GH_TOKEN="$publisher_token" gh api \
  "repos/${repo_slug}/labels/squad" --jq '[.id,.name,.color,.description] | @json')
pr_count_before=$(GH_TOKEN="$publisher_token" gh api \
  "repos/${repo_slug}/pulls?state=open&head=${GITHUB_OWNER}%3A${default_branch}&base=${default_branch}&per_page=100" \
  --jq 'length')

ref_payload=$(jq -nc --arg ref "$default_ref" --arg sha "$default_sha" \
  '{ref: $ref, sha: $sha}')
label_payload=$(jq -nc \
  '{name: "squad", color: "5319e7", description: "Hangar worker queue"}')
pull_payload=$(jq -nc --arg branch "$default_branch" \
  '{title: "Hangar permission boundary probe", head: $branch, base: $branch}')

assert_publisher_collision "Git refs" "git/refs" "$ref_payload"
assert_model_denied "Git refs" "git/refs" "$ref_payload"
assert_publisher_collision "Issues/labels" "labels" "$label_payload"
assert_model_denied "Issues/labels" "labels" "$label_payload"
assert_publisher_collision "Pull requests" "pulls" "$pull_payload"
assert_model_denied "Pull requests" "pulls" "$pull_payload"

# Verify the collided resources and impossible same-branch PR set are unchanged.
ref_after=$(GH_TOKEN="$publisher_token" gh api \
  "repos/${repo_slug}/git/ref/heads/${default_branch}" --jq '.object.sha')
label_after=$(GH_TOKEN="$publisher_token" gh api \
  "repos/${repo_slug}/labels/squad" --jq '[.id,.name,.color,.description] | @json')
pr_count_after=$(GH_TOKEN="$publisher_token" gh api \
  "repos/${repo_slug}/pulls?state=open&head=${GITHUB_OWNER}%3A${default_branch}&base=${default_branch}&per_page=100" \
  --jq 'length')
[[ "$ref_after" == "$ref_before" ]]
[[ "$label_after" == "$label_before" ]]
[[ "$pr_count_after" == "$pr_count_before" ]]

unset publisher_token model_token
echo "Copilot token publication boundary: PASS"
INNER
