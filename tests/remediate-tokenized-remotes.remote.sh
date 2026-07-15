#!/usr/bin/env bash
# Revoke legacy installation tokens embedded in persisted remotes, then rebuild
# Git config through the trusted worker sanitizer. Never prints token material.
# Iterates workers dynamically from repos.json or explicit WORKER_IDS.
set -euo pipefail

REPOS_JSON="${REPOS_JSON:-repos.json}"
WORKER_IDS="${WORKER_IDS:-}"

if [[ -n "$WORKER_IDS" ]]; then
  read -ra ids <<< "$WORKER_IDS"
else
  # Default: all workers from repos.json
  mapfile -t ids < <(jq -r 'keys[] | sub("worker-";"")' "$REPOS_JSON")
fi

for worker_num in "${ids[@]}"; do
  container="squad-worker-${worker_num}"
  worker_key="worker-${worker_num}"
  repo_name=$(jq -r --arg w "$worker_key" '.[$w].repo' "$REPOS_JSON")
  owner=$(jq -r --arg w "$worker_key" '.[$w].owner' "$REPOS_JSON")

  docker exec -i -u copilot "$container" bash -s -- "$repo_name" "$owner" <<'INNER'
set -euo pipefail
repo_name="$1"
owner="$2"
workspace="/workspace/${repo_name}"
remote=$(git -C "$workspace" remote get-url origin)
token_user="x-access-token"
github_host="github.com"
case "$remote" in
  https://"$token_user":*@"$github_host"/*)
    token_and_path=${remote#"https://${token_user}:"}
    embedded_token=${token_and_path%%@*}
    GH_TOKEN="$embedded_token" gh api --method DELETE /installation/token >/dev/null 2>&1 || true
    ;;
esac
source /home/copilot/.workspace_env
source /home/copilot/worker-loop.sh
sanitize_repository_git_config
clean_remote=$(git -C "$workspace" remote get-url origin)
test "$clean_remote" = "https://${github_host}/${owner}/${repo_name}.git"
INNER

  if docker exec -u squad-agent "$container" grep -Rqs 'x-access-token' "/workspace/${repo_name}/.git/config"; then
    echo "ERROR: worker-${worker_num} still exposes a tokenized remote" >&2
    exit 1
  fi
  echo "worker-${worker_num} persisted remote sanitized"
done
