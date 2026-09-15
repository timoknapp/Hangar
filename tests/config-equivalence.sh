#!/usr/bin/env bash
# Validate that workers sharing the same owner/repo have equivalent gate
# configuration. Autonomous mode may differ; all other loop fields must match.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOS_JSON="${REPOS_JSON:-${ROOT}/repos.json}"
if [[ ! -f "$REPOS_JSON" ]]; then
  REPOS_JSON="${ROOT}/repos.example.json"
fi
if [[ ! -f "$REPOS_JSON" ]]; then
  echo "SKIP: no repos.json or repos.example.json found" >&2
  exit 0
fi

# Group workers by owner/repo
groups=$(jq -r '[to_entries[] | {key: .key, owner: .value.owner, repo: .value.repo}] | group_by(.owner + "/" + .repo) | .[] | select(length > 1) | [.[].key] | join(",")' "$REPOS_JSON")

if [[ -z "$groups" ]]; then
  echo "Config equivalence: no shared-queue groups found (single-worker repos)"
  exit 0
fi

# Fields that MUST be equivalent within a group (autonomous excluded)
EQUIV_FIELDS=(critic criticModel criticRubric verify maxRetries maxPrsPerDay maxOpenAutoIssues workScope implementer requiredLabels manualIssueCreators unattendedLabels requiredChecks maxActiveIssues maxTaskSeconds maxReviewBytes profileDir checkBackend requiredWorkflows conditionalWorkflows ignoredWorkflows)

policy_value() {
  local worker="$1" field="$2"
  if [[ "$field" == manualIssueCreators ]]; then
    jq -c --arg w "$worker" '.[$w].loop.manualIssueCreators // [] | map(ascii_downcase) | sort' "$REPOS_JSON"
  else
    jq -r --arg w "$worker" --arg f "$field" '.[$w].loop[$f] // empty' "$REPOS_JSON"
  fi
}

FAIL=0
while IFS= read -r group; do
  [[ -n "$group" ]] || continue
  IFS=',' read -ra workers <<< "$group"
  reference="${workers[0]}"

  for field in "${EQUIV_FIELDS[@]}"; do
    ref_val=$(policy_value "$reference" "$field")
    for worker in "${workers[@]:1}"; do
      worker_val=$(policy_value "$worker" "$field")
      if [[ "$ref_val" != "$worker_val" ]]; then
        echo "FAIL: $field differs between $reference ($ref_val) and $worker ($worker_val)" >&2
        FAIL=1
      fi
    done
  done
done <<< "$groups"

if [[ "$FAIL" -eq 0 ]]; then
  echo "Shared-queue worker policy equivalence: PASS"
else
  exit 1
fi
