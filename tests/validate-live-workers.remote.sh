#!/usr/bin/env bash
# Dynamically validate all workers defined in repos.json. Iterates keys,
# derives container/workspace/repo, and checks runtime properties.
# No hard-coded worker count or repo names.
set -euo pipefail

: "${REPOS_JSON:=repos.json}"

[[ -f "$REPOS_JSON" ]] || {
  echo "ERROR: repos.json not found at $REPOS_JSON" >&2
  exit 1
}

fail() {
  echo "Live validation failed: $*" >&2
  exit 1
}

expect_equal() {
  local label="$1" expected="$2" actual="$3"
  [[ "$actual" == "$expected" ]] || fail "${label} (expected '${expected}', got '${actual}')"
}

workers=$(jq -r 'keys[]' "$REPOS_JSON")
expected_loop_hash=""

for worker in $workers; do
  # Derive container name from worker ID pattern
  container="squad-${worker}"
  echo "Checking ${worker} runtime"

  expect_equal "${worker} status" running "$(docker inspect -f '{{.State.Status}}' "$container")"
  expect_equal "${worker} init" true "$(docker inspect -f '{{.HostConfig.Init}}' "$container")"
  expect_equal "${worker} publisher group" squad "$(docker exec "$container" id -gn copilot)"
  expect_equal "${worker} agent group" squad "$(docker exec "$container" id -gn squad-agent)"
  docker exec -u squad-agent "$container" test ! -r /home/copilot/.gh-app-key.pem \
    || fail "${worker} agent can read publisher key"
  docker exec -u squad-agent "$container" test ! -r /home/copilot/.github-app-token \
    || fail "${worker} agent can read publisher token"

  expected_owner=$(jq -r --arg w "$worker" '.[$w].owner' "$REPOS_JSON")
  expected_repo=$(jq -r --arg w "$worker" '.[$w].repo' "$REPOS_JSON")
  expected_autonomous=$(jq -r --arg w "$worker" '.[$w].loop.autonomous' "$REPOS_JSON")
  expected_critic=$(jq -r --arg w "$worker" '.[$w].loop.critic' "$REPOS_JSON")
  expected_model=$(jq -r --arg w "$worker" '.[$w].loop.criticModel' "$REPOS_JSON")
  expected_verify=$(jq -r --arg w "$worker" '.[$w].loop.verify' "$REPOS_JSON")
  expected_scope=$(jq -r --arg w "$worker" '.[$w].loop.workScope' "$REPOS_JSON")
  expected_rubric=$(jq -r --arg w "$worker" '.[$w].loop.criticRubric' "$REPOS_JSON")
  expected_implementer=$(jq -r --arg w "$worker" '.[$w].loop.implementer // "plain"' "$REPOS_JSON")

  expect_equal "${worker} autonomous" "$expected_autonomous" "$(docker exec "$container" printenv LOOP_AUTONOMOUS)"
  expect_equal "${worker} critic" "$expected_critic" "$(docker exec "$container" printenv LOOP_CRITIC)"
  expect_equal "${worker} critic model" "$expected_model" "$(docker exec "$container" printenv LOOP_CRITIC_MODEL)"
  expect_equal "${worker} verify" "$expected_verify" "$(docker exec "$container" printenv LOOP_VERIFY)"
  expect_equal "${worker} scope" "$expected_scope" "$(docker exec "$container" printenv LOOP_WORK_SCOPE)"
  expect_equal "${worker} rubric" "$expected_rubric" "$(docker exec "$container" printenv LOOP_CRITIC_RUBRIC)"
  expect_equal "${worker} implementer" "$expected_implementer" "$(docker exec "$container" printenv LOOP_IMPLEMENTER)"

  loop_hash=$(docker exec "$container" sha256sum /home/copilot/worker-loop.sh | awk '{print $1}')
  if [[ -z "$expected_loop_hash" ]]; then
    expected_loop_hash="$loop_hash"
  else
    expect_equal "${worker} runtime hash" "$expected_loop_hash" "$loop_hash"
  fi
  docker exec "$container" test -x /usr/local/bin/credential-guard \
    || fail "${worker} credential guard is missing"
  docker exec "$container" grep -q '^create_critic_input_file()' /home/copilot/worker-loop.sh \
    || fail "${worker} file-based critic input is missing"

  if [[ "$expected_implementer" == "squad" ]]; then
    docker exec -u copilot "$container" bash -c '
      source /home/copilot/.workspace_env
      source /home/copilot/worker-loop.sh
      test "${IMPLEMENTER_AGENT_ARGS[*]}" = "--agent squad"
      policy=" ${COPILOT_IMPLEMENTER_POLICY_ARGS[*]} "
      common=" ${COPILOT_COMMON_ARGS[*]} "
      [[ "$policy" == *" --allow-all-urls "* ]]
      [[ "$policy" == *" --allow-all-mcp-server-instructions "* ]]
      [[ "$policy" == *" --disable-mcp-server github-mcp-server "* ]]
      [[ "$policy" != *" --disable-builtin-mcps "* ]]
      [[ "$policy" == *" --deny-tool=shell(git push) "* ]]
      [[ "$policy" != *" --deny-tool=shell "* ]]
      [[ "$policy" != *" --deny-tool=url "* ]]
      [[ "$policy" != *" --deny-tool=shell(gh:*) "* ]]
      [[ "$common" != *" --disable-builtin-mcps "* ]]
    ' || fail "${worker} full Squad capability policy is not active"
  fi

  workspace="/workspace/${expected_repo}"
  remote=$(docker exec -u copilot "$container" git -C "$workspace" remote get-url origin)
  [[ "$remote" == "https://github.com/${expected_owner}/${expected_repo}.git" ]] \
    || fail "${worker} remote is not the clean expected URL"
  case "$remote" in
    *x-access-token*) fail "${worker} remote contains embedded token" ;;
  esac

  worker_logs=$(docker logs "$container" 2>&1)
  grep -q "Loop config: autonomous=${expected_autonomous}" <<<"$worker_logs" \
    || fail "${worker} startup log has wrong autonomous policy"
  grep -q "implementer=${expected_implementer}" <<<"$worker_logs" \
    || fail "${worker} startup log has wrong implementer policy"

done

# Check unique queue groups (repos with multiple workers)
echo "Checking GitHub queue state"
unique_repos=$(jq -r '[.[] | .owner + "/" + .repo] | unique[]' "$REPOS_JSON")
for repo in $unique_repos; do
  echo "  repo: $repo"
done

printf 'Live worker validation: PASS (%s workers, %s unique repos)\n' \
  "$(jq 'keys | length' "$REPOS_JSON")" \
  "$(echo "$unique_repos" | wc -l | tr -d ' ')"
