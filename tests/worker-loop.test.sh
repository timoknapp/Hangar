#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154
# The sourced worker functions consume globals and printf -v assigns result
# variables dynamically, which static analysis cannot follow in this harness.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${TEST_DIR}/.." && pwd)"
WORKER_SCRIPT="${ROOT_DIR}/worker/worker-loop.sh"
ENTRYPOINT_SCRIPT="${ROOT_DIR}/worker/entrypoint.sh"
DEPLOY_SCRIPT="${ROOT_DIR}/deploy.sh"
REMOTE_DEPLOY_SCRIPT="${ROOT_DIR}/remote-deploy.sh"
TOKEN_BOUNDARY_SCRIPT="${ROOT_DIR}/tests/check-copilot-token-boundary.remote.sh"
SQUAD_CAPABILITY_SCRIPT="${ROOT_DIR}/tests/squad-capability-preflight.remote.sh"
TMP_ROOT=$(mktemp -d)
TEST_COUNT=0

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "not ok - $*" >&2
  exit 1
}

pass() {
  TEST_COUNT=$((TEST_COUNT + 1))
  echo "ok ${TEST_COUNT} - $*"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [[ "$actual" == "$expected" ]] || fail "${message}: expected '${expected}', got '${actual}'"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "${message}: missing '${needle}'"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "${message}: unexpectedly found '${needle}'"
}

assert_true() {
  local message="$1"
  shift
  "$@" || fail "$message"
}

run_and_capture_rc() {
  local __result_var="$1"
  shift
  local rc=0
  "$@" || rc=$?
  printf -v "$__result_var" '%s' "$rc"
}

# A real local diff gives run_critic deterministic review input.
REPO_DIR="${TMP_ROOT}/repo"
mkdir -p "$REPO_DIR/.github" "$REPO_DIR/.squad"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.name "Worker Loop Test"
git -C "$REPO_DIR" config user.email "worker-loop-test@example.invalid"
printf '%s\n' 'base' > "$REPO_DIR/example.txt"
git -C "$REPO_DIR" add example.txt
git -C "$REPO_DIR" commit -qm "base"
git -C "$REPO_DIR" branch -M main
git -C "$REPO_DIR" update-ref refs/remotes/origin/main "$(git -C "$REPO_DIR" rev-parse main)"
git -C "$REPO_DIR" checkout -qb feature
printf '%s\n' 'changed' > "$REPO_DIR/example.txt"
git -C "$REPO_DIR" commit -qam "change"
printf '%s\n' 'REPO_RULE_SENTINEL' > "$REPO_DIR/.github/copilot-instructions.md"
printf '%s\n' 'GREEN_CAPABILITY_SENTINEL' > "$REPO_DIR/.squad/roster.md"
printf '%s\n' '{"mcpServers":{}}' > "$REPO_DIR/.mcp.json"

# Fake Copilot emits controlled critic responses and records arguments.
FAKE_BIN="${TMP_ROOT}/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/copilot" <<'FAKE_COPILOT'
#!/usr/bin/env bash
if [[ -n "${FAKE_ARGS_FILE:-}" ]]; then
  printf '%s\n' "$@" > "$FAKE_ARGS_FILE"
fi
printf '%b' "${FAKE_COPILOT_OUTPUT:-}"
exit "${FAKE_COPILOT_EXIT:-0}"
FAKE_COPILOT
chmod +x "$FAKE_BIN/copilot"

export PATH="${FAKE_BIN}:$PATH"
export WORKER_ID="worker-test"
export WORKSPACE_DIR="$REPO_DIR"
AGENT_GROUP=$(id -gn)
export AGENT_GROUP
export GITHUB_OWNER="example"
export GITHUB_REPO="repo"
export REPO_BRANCH="main"
export POLL_INTERVAL=1
export LOOP_AUTONOMOUS=false
export LOOP_CRITIC=true
export LOOP_CRITIC_MODEL=""
export LOOP_CRITIC_RUBRIC=repo-aware
export LOOP_VERIFY=off
export LOOP_MAX_RETRIES=2
export LOOP_MAX_PRS_PER_DAY=1
export LOOP_MAX_OPEN_AUTO_ISSUES=1
export LOOP_GOAL_FILE=BACKLOG.md
export LOOP_WORK_SCOPE=green-fit
export LOOP_IMPLEMENTER=plain
export LOOP_STATE_DIR="${TMP_ROOT}/state"
export COPILOT_MODEL=""
export COPILOT_EFFORT=""
export COPILOT_CONTEXT=""
export COPILOT_PAT="test-token"

# shellcheck source=/dev/null
source "$WORKER_SCRIPT"
CURRENT_ISSUE=42
CURRENT_TOKEN="test-token"
branch_name="feature"

# Local tests do not have the image's squad-agent account. Preserve path
# confinement while replacing only the user switch.
read_repo_file() {
  local requested="$1" max_lines="${2:-1200}" resolved
  resolved=$(resolve_repo_file_path "$requested") || return 1
  sed -n "1,${max_lines}p" "$resolved"
}
remove_repo_file_as_agent() {
  local relative_path="$1"
  rm -f -- "$WORKSPACE_DIR/$relative_path"
}

# Unit tests run outside the worker image, so bypass sudo while preserving the
# exact Copilot argument construction under test.
run_agent_copilot() {
  local token="$1"
  shift
  [[ "$token" == "test-token" ]] || return 99
  command copilot "$@"
}

bash -n "$WORKER_SCRIPT" "$ENTRYPOINT_SCRIPT" "$DEPLOY_SCRIPT"
pass "modified shell scripts parse"

common_args="${COPILOT_COMMON_ARGS[*]}"
plain_policy_args="${COPILOT_IMPLEMENTER_POLICY_ARGS[*]}"
assert_eq "0" "${#IMPLEMENTER_AGENT_ARGS[@]}" "plain implementer custom-agent arg count"
assert_not_contains "$common_args" "--disable-builtin-mcps" "common policy leaves MCP selection to the session mode"
assert_contains "$common_args" "--no-bash-env" "common Copilot policy disables BASH_ENV injection"
assert_contains "$common_args" "--secret-env-vars=COPILOT_GITHUB_TOKEN,GITHUB_TOKEN,GH_TOKEN,COPILOT_PAT" "common Copilot policy strips auth secrets from tools"
assert_contains "$plain_policy_args" "--deny-tool=shell" "plain sessions cannot invoke shell wrappers"
assert_contains "$plain_policy_args" "--deny-tool=url" "plain sessions cannot access arbitrary URLs"
assert_contains "$plain_policy_args" "--disable-builtin-mcps" "plain sessions disable all MCP servers"
assert_contains "$plain_policy_args" "--deny-url=https://api.github.com" "plain sessions block GitHub API URLs"
pass "plain implementer remains shell-free"

LOOP_IMPLEMENTER=squad
configure_implementer_mode
squad_policy_args="${COPILOT_IMPLEMENTER_POLICY_ARGS[*]}"
assert_eq "--agent squad" "${IMPLEMENTER_AGENT_ARGS[*]}" "Squad implementer custom-agent arguments"
assert_contains "$squad_policy_args" "--allow-all-urls" "Squad can research external documentation"
assert_contains "$squad_policy_args" "--allow-all-mcp-server-instructions" "Squad receives repository MCP instructions"
assert_contains "$squad_policy_args" "--disable-mcp-server github-mcp-server" "Squad disables only the built-in GitHub MCP"
assert_not_contains "$squad_policy_args" "--disable-builtin-mcps" "Squad leaves repository MCP servers enabled"
assert_contains "$squad_policy_args" "--deny-tool=shell(git push)" "Squad publication barrier blocks git push"
assert_not_contains " ${squad_policy_args} " " --deny-tool=shell " "Squad must not receive a blanket shell denial"
assert_not_contains " ${squad_policy_args} " " --deny-tool=url " "Squad must not receive a blanket URL denial"
assert_not_contains "$squad_policy_args" "--deny-tool=shell(gh:*)" "Squad may perform read-only gh discovery without an auth credential"
squad_capabilities=$(implementer_capability_instructions)
assert_contains "$squad_capabilities" 'real Squad Team Mode session' "Squad prompt identifies the real orchestrator"
# shellcheck disable=SC2016 # Backticks are literal prompt text.
assert_contains "$squad_capabilities" 'Use the `task` tool' "Squad prompt requires real delegation"
assert_contains "$squad_capabilities" 'project builds/tests' "Squad prompt exposes local verification tools"
assert_contains "$squad_capabilities" 'repository-configured MCP servers' "Squad prompt exposes workspace MCPs"
configure_workspace_mcp_args
workspace_mcp_args="${WORKSPACE_MCP_ARGS[*]}"
expected_mcp_config=$(realpath "$REPO_DIR/.mcp.json")
assert_contains "$workspace_mcp_args" "--additional-mcp-config @${expected_mcp_config}" "Squad explicitly attaches repository MCP config"
pass "Squad implementer receives full local engineering capabilities"

LOOP_IMPLEMENTER=plain
configure_implementer_mode

rubric=$(resolve_critic_rubric)
assert_contains "$rubric" "REPO_RULE_SENTINEL" "repo-aware rubric includes repository instructions"
pass "repo-aware rubric includes bounded repository context"

scope_context=$(resolve_work_scope_context)
assert_contains "$scope_context" "GREEN_CAPABILITY_SENTINEL" "green-fit scope includes capability guidance"
assert_contains "$scope_context" "Do NOT select architecture" "green-fit scope excludes high-risk work"
pass "green-fit work policy is explicit"

printf '%s\n' 'publisher-secret' > "${TMP_ROOT}/outside-secret"
ln -s "${TMP_ROOT}/outside-secret" "$REPO_DIR/.squad/outside-link.md"
if resolve_repo_file_path ".squad/outside-link.md" >/dev/null 2>&1; then
  fail "repository path confinement accepted a symlink outside the workspace"
fi
pass "repository content reads reject symlinks outside the workspace"

printf '%s\n' 'stale summary' > "$REPO_DIR/.squad/pr-summary.md"
printf '%s\n' 'stale critic input' > "$REPO_DIR/.critic-input.stale.md"
PR_EXECUTIVE_SUMMARY="previous task summary"
reset_task_scratch
assert_eq "" "$PR_EXECUTIVE_SUMMARY" "task summary memory reset"
[[ ! -e "$REPO_DIR/.squad/pr-summary.md" ]] || fail "stale on-disk summary survived task reset"
[[ ! -e "$REPO_DIR/.critic-input.stale.md" ]] || fail "stale critic input survived task reset"
pass "task reset clears PR summaries and stale critic inputs"

critic_nonce=0123456789abcdef0123456789abcdef
export CRITIC_INPUT_NONCE_OVERRIDE="$critic_nonce"
export FAKE_ARGS_FILE="${TMP_ROOT}/critic-args"
export FAKE_COPILOT_EXIT=0
export FAKE_COPILOT_OUTPUT="Review input loaded.
VERDICT: APPROVE
INPUT_NONCE: ${critic_nonce}
- Correct and covered.
"
run_and_capture_rc critic_rc run_critic
assert_eq "0" "$critic_rc" "valid critic approval"
critic_args=$(cat "$FAKE_ARGS_FILE")
assert_contains "$critic_args" "-C" "critic receives an explicit workspace"
assert_contains "$critic_args" ".critic-input." "critic prompt references the workspace input file"
assert_not_contains "$critic_args" "REPO_RULE_SENTINEL" "large rubric is absent from critic argv"
if find "$REPO_DIR" -maxdepth 1 -name '.critic-input.*.md' -print -quit | grep -q .; then
  fail "critic input file survived successful review"
fi
pass "critic accepts an attested approval with bounded argv and cleanup"

export FAKE_COPILOT_OUTPUT="VERDICT: REQUEST_CHANGES
INPUT_NONCE: ${critic_nonce}
- Missing regression coverage.
"
run_and_capture_rc critic_rc run_critic
assert_eq "1" "$critic_rc" "request-changes critic result"
assert_eq "review" "$CRITIC_FAILURE_KIND" "request-changes failure kind"
pass "critic returns actionable review failure"

export FAKE_COPILOT_OUTPUT=$'VERDICT: APPROVE\n- Nonce omitted.\n'
run_and_capture_rc critic_rc run_critic
assert_eq "1" "$critic_rc" "critic missing nonce"
assert_eq "infrastructure" "$CRITIC_FAILURE_KIND" "missing nonce failure kind"
pass "missing critic input attestation fails closed"

export FAKE_COPILOT_OUTPUT=$'VERDICT: APPROVE\nINPUT_NONCE: wrong-nonce\n'
run_and_capture_rc critic_rc run_critic
assert_eq "1" "$critic_rc" "critic wrong nonce"
assert_eq "infrastructure" "$CRITIC_FAILURE_KIND" "wrong nonce failure kind"
pass "incorrect critic input attestation fails closed"

export FAKE_COPILOT_EXIT=7
export FAKE_COPILOT_OUTPUT=$'transport failed\n'
run_and_capture_rc critic_rc run_critic
assert_eq "1" "$critic_rc" "critic command failure"
assert_eq "infrastructure" "$CRITIC_FAILURE_KIND" "critic command failure kind"
pass "critic process errors fail closed"

export FAKE_COPILOT_EXIT=0
export FAKE_COPILOT_OUTPUT="INPUT_NONCE: ${critic_nonce}
Everything looks good.
"
run_and_capture_rc critic_rc run_critic
assert_eq "1" "$critic_rc" "critic missing verdict"
assert_eq "infrastructure" "$CRITIC_FAILURE_KIND" "critic malformed failure kind"
pass "missing critic verdict fails closed"

export FAKE_COPILOT_OUTPUT="VERDICT: APPROVE
INPUT_NONCE: ${critic_nonce}
VERDICT: REQUEST_CHANGES
"
run_and_capture_rc critic_rc run_critic
assert_eq "1" "$critic_rc" "ambiguous critic verdict"
pass "multiple critic verdicts fail closed"

if find "$REPO_DIR" -maxdepth 1 -name '.critic-input.*.md' -print -quit | grep -q .; then
  fail "critic input file survived failed review"
fi
unset FAKE_ARGS_FILE CRITIC_INPUT_NONCE_OVERRIDE

# Replace external gate actions with deterministic in-process fakes.
VERIFY_CALLS=0
CRITIC_CALLS=0
FIX_CALLS=0
VERIFY_MODE="pass"
CRITIC_MODE="approve"

run_verify_gate() {
  VERIFY_CALLS=$((VERIFY_CALLS + 1))
  case "$VERIFY_MODE" in
    pass) return 0 ;;
    fail) VERIFY_LOG_TAIL="forced verify failure"; return 1 ;;
    first-pass-then-fail)
      [[ "$VERIFY_CALLS" -eq 1 ]] && return 0
      VERIFY_LOG_TAIL="forced post-critic verify failure"
      return 1
      ;;
    off) return 3 ;;
    unavailable) return 2 ;;
    *) return 1 ;;
  esac
}

run_critic() {
  CRITIC_CALLS=$((CRITIC_CALLS + 1))
  case "$CRITIC_MODE" in
    approve) return 0 ;;
    request-once)
      if [[ "$CRITIC_CALLS" -eq 1 ]]; then
        CRITIC_FAILURE_KIND="review"
        CRITIC_FEEDBACK="forced review request"
        return 1
      fi
      return 0
      ;;
    infrastructure)
      CRITIC_FAILURE_KIND="infrastructure"
      CRITIC_FEEDBACK="forced critic infrastructure failure"
      return 1
      ;;
    *) return 1 ;;
  esac
}

run_fix_session() {
  FIX_CALLS=$((FIX_CALLS + 1))
}

LOOP_VERIFY=literal
LOOP_CRITIC=true
LOOP_MAX_RETRIES=2
VERIFY_MODE=fail
CRITIC_MODE=approve
VERIFY_CALLS=0
CRITIC_CALLS=0
FIX_CALLS=0
run_and_capture_rc gate_rc run_quality_gates
assert_eq "1" "$gate_rc" "exhausted verify gate result"
assert_eq "true" "$PR_DRAFT" "exhausted verify gate draft flag"
assert_eq "3" "$VERIFY_CALLS" "initial verify plus two retries"
assert_eq "2" "$FIX_CALLS" "two verify correction sessions"
assert_eq "0" "$CRITIC_CALLS" "critic skipped after verify exhaustion"
pass "verify retries are bounded and unresolved work drafts"

VERIFY_MODE=pass
CRITIC_MODE=request-once
VERIFY_CALLS=0
CRITIC_CALLS=0
FIX_CALLS=0
run_and_capture_rc gate_rc run_quality_gates
assert_eq "0" "$gate_rc" "critic correction gate result"
assert_eq "false" "$PR_DRAFT" "successful critic correction draft flag"
assert_eq "2" "$VERIFY_CALLS" "initial and post-critic verification"
assert_eq "2" "$CRITIC_CALLS" "critic re-review count"
assert_eq "1" "$FIX_CALLS" "critic correction count"
pass "critic corrections are re-verified before approval"

LOOP_MAX_RETRIES=1
VERIFY_MODE=first-pass-then-fail
CRITIC_MODE=request-once
VERIFY_CALLS=0
CRITIC_CALLS=0
FIX_CALLS=0
run_and_capture_rc gate_rc run_quality_gates
assert_eq "1" "$gate_rc" "failed post-critic verification result"
assert_eq "true" "$PR_DRAFT" "failed post-critic verification draft flag"
assert_eq "1" "$CRITIC_CALLS" "critic cannot re-approve after failed re-verification"
pass "failed post-critic verification blocks re-approval"

LOOP_MAX_RETRIES=2
VERIFY_MODE=pass
CRITIC_MODE=infrastructure
VERIFY_CALLS=0
CRITIC_CALLS=0
FIX_CALLS=0
run_and_capture_rc gate_rc run_quality_gates
assert_eq "1" "$gate_rc" "critic infrastructure exhaustion result"
assert_eq "true" "$PR_DRAFT" "critic infrastructure exhaustion draft flag"
assert_eq "3" "$CRITIC_CALLS" "initial critic plus two infrastructure retries"
assert_eq "0" "$FIX_CALLS" "infrastructure failures must not trigger code changes"
assert_contains "$GATE_NOTE" "Independent critic unavailable" "critic infrastructure draft note"
assert_contains "$GATE_NOTE" "no valid critic verdict" "critic infrastructure missing-verdict disclosure"
pass "critic infrastructure exhaustion is explicit and fails closed"

LOOP_VERIFY=off
LOOP_CRITIC=false
LOOP_MAX_RETRIES=2
VERIFY_MODE=off
VERIFY_CALLS=0
CRITIC_CALLS=0
FIX_CALLS=0
run_and_capture_rc gate_rc run_quality_gates
assert_eq "0" "$gate_rc" "legacy gates disabled result"
assert_eq "false" "$PR_DRAFT" "legacy gates disabled draft flag"
assert_eq "0" "$FIX_CALLS" "legacy gates disabled corrections"
pass "legacy workers remain non-draft when all gates are explicitly off"

set +e
(CURRENT_ISSUE=""; CURRENT_CLAIM_REF=""; fatal_agent_isolation_breach >/dev/null 2>&1)
isolation_rc=$?
set -e
assert_eq "70" "$isolation_rc" "fatal agent-isolation exit code"
runner_source="$(sed -n '/^run_agent_copilot()/,/^}/p' "$WORKER_SCRIPT") $(declare -f run_agent_command)"
assert_contains "$runner_source" 'terminate_agent_processes || fatal_agent_isolation_breach' "runners enforce fatal cleanup failure"
assert_contains "$runner_source" '/usr/local/bin/credential-guard' "Copilot runner protects its credential-bearing process environment"
# shellcheck disable=SC2016 # Assertion intentionally matches literal shell source.
assert_contains "$runner_source" 'printf '\''%s'\'' "$token" | sudo' "Copilot token is delivered through an anonymous pipe"
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
assert_not_contains "$runner_source" 'COPILOT_GITHUB_TOKEN="$token"' "agent runner must not place the token in a parent environment"
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
assert_not_contains "$runner_source" 'GH_TOKEN="$token"' "agent runner must not expose its token as gh authentication"
pass "live residual coding processes stop the worker before publication"

today=$(date -u +%Y-%m-%d)
REMOTE_PR_COUNT=0
BUDGET_LOCK="${TMP_ROOT}/budget-slot"
CLAIM_LOCK="${TMP_ROOT}/issue-claim"
GH_MODE="budget"
PR_LOOKUP_MODE="empty"
count_remote_worker_prs_today() {
  printf '%s\n' "$REMOTE_PR_COUNT"
}
count_budget_reservations() {
  [[ -d "$BUDGET_LOCK" ]] && echo 1 || echo 0
}
# shellcheck disable=SC2329 # Invoked indirectly by sourced worker functions.
gh() {
  if [[ "$GH_MODE" == "pr_lookup" ]]; then
    case "$PR_LOOKUP_MODE" in
      error) return 1 ;;
      empty) printf '[]' ;;
      valid) printf '[{"url":"https://example.invalid/pr/1","headRefName":"feature","baseRefName":"main"}]' ;;
      mismatch) printf '[{"url":"https://example.invalid/pr/1","headRefName":"other","baseRefName":"main"}]' ;;
    esac
    return 0
  fi
  if [[ "$GH_MODE" == "claim" ]]; then
    if [[ "$1" == "issue" ]]; then
      return 0
    fi
    if [[ " $* " == *" --method POST "* ]]; then
      mkdir "$CLAIM_LOCK" 2>/dev/null
      return $?
    fi
    if [[ " $* " == *" --method DELETE "* ]]; then
      rmdir "$CLAIM_LOCK" 2>/dev/null
      return $?
    fi
    if [[ "$*" == *"/git/ref/heads/main"* ]]; then
      echo "deadbeef"
      return 0
    fi
    return 1
  fi
  if [[ " $* " == *" --method POST "* ]]; then
    mkdir "$BUDGET_LOCK" 2>/dev/null
    return $?
  fi
  [[ "$*" == *"/git/ref/"* ]] && [[ -d "$BUDGET_LOCK" ]]
}

LOOP_MAX_PRS_PER_DAY=1
rm -rf "$BUDGET_LOCK"
run_and_capture_rc budget_rc pr_budget_remaining
assert_eq "0" "$budget_rc" "empty repository-wide PR budget"

set +e
(reserve_pr_budget >/dev/null 2>&1; echo $? > "${TMP_ROOT}/reservation-a") &
pid_a=$!
(reserve_pr_budget >/dev/null 2>&1; echo $? > "${TMP_ROOT}/reservation-b") &
pid_b=$!
wait "$pid_a" "$pid_b"
set -e
reservation_sum=$(( $(cat "${TMP_ROOT}/reservation-a") + $(cat "${TMP_ROOT}/reservation-b") ))
assert_eq "1" "$reservation_sum" "two-worker atomic reservation result"
pass "only one concurrent worker can reserve the final daily slot"

run_and_capture_rc budget_rc pr_budget_remaining
assert_eq "1" "$budget_rc" "reservation survives process restart through GitHub state"
pass "repository reservation enforces cap across workers and restarts"

rm -rf "$BUDGET_LOCK"
REMOTE_PR_COUNT=1
run_and_capture_rc budget_rc pr_budget_remaining
assert_eq "1" "$budget_rc" "existing repository worker PR budget"
pass "existing same-day worker PR consumes unreserved legacy slot"

GH_MODE="claim"
rm -rf "$CLAIM_LOCK"
CURRENT_CLAIM_REF=""
run_and_capture_rc claim_rc claim_issue 77
assert_eq "0" "$claim_rc" "first atomic issue claim"
first_claim_ref="$CURRENT_CLAIM_REF"
CURRENT_CLAIM_REF=""
run_and_capture_rc claim_rc claim_issue 77
assert_eq "1" "$claim_rc" "second atomic issue claim collision"
CURRENT_CLAIM_REF="$first_claim_ref"
release_issue_claim
[[ ! -d "$CLAIM_LOCK" ]] || fail "atomic issue claim was not released"
GH_MODE="budget"
pass "only one worker can atomically claim an issue"

GH_MODE="pr_lookup"
PR_LOOKUP_MODE="error"
run_and_capture_rc lookup_rc lookup_pr_url_for_branch feature
assert_eq "1" "$lookup_rc" "PR lookup API failure"
PR_LOOKUP_MODE="mismatch"
run_and_capture_rc lookup_rc lookup_pr_url_for_branch feature
assert_eq "1" "$lookup_rc" "PR identity mismatch"
PR_LOOKUP_MODE="valid"
valid_pr=$(lookup_pr_url_for_branch feature)
assert_eq "https://example.invalid/pr/1" "$valid_pr" "valid PR lookup URL"
GH_MODE="budget"
pass "PR lookup distinguishes API failure, identity mismatch, and confirmed state"

revision_source=$(sed -n '/^process_revision()/,/^}/p' "$WORKER_SCRIPT")
gate_line=$(printf '%s\n' "$revision_source" | grep -n 'run_quality_gates' | head -1 | cut -d: -f1)
draft_line=$(printf '%s\n' "$revision_source" | grep -n 'ensure_pr_is_draft' | head -1 | cut -d: -f1)
push_line=$(printf '%s\n' "$revision_source" | grep -n 'git push --force-with-lease' | head -1 | cut -d: -f1)
[[ -n "$gate_line" && -n "$draft_line" && -n "$push_line" ]] || fail "revision ordering markers missing"
[[ "$gate_line" -lt "$draft_line" && "$draft_line" -lt "$push_line" ]] || fail "revision must gate, then draft, then push"
pass "revision gates and draft downgrade precede force-push"

issue_source=$(sed -n '/^process_issue()/,/^}/p' "$WORKER_SCRIPT")
assert_contains "$issue_source" 'PR_EXECUTIVE_SUMMARY=""' "new issue resets PR summary"
assert_contains "$revision_source" 'PR_EXECUTIVE_SUMMARY=""' "revision resets PR summary"
pass "PR summaries cannot leak between sequential tasks"

assert_contains "$issue_source" 'Always capture' "initial issue flow documents residual-edit capture"
residual_commit_line=$(printf '%s\n' "$issue_source" | grep -n 'local unstaged' | head -1 | cut -d: -f1)
# shellcheck disable=SC2016 # Assertion intentionally matches literal shell source.
zero_commit_guard_line=$(printf '%s\n' "$issue_source" | grep -n 'if \[\[ "$commit_count" -eq 0 \]\]' | head -1 | cut -d: -f1)
[[ -n "$residual_commit_line" && -n "$zero_commit_guard_line" ]] \
  || fail "residual commit ordering markers missing"
[[ "$residual_commit_line" -lt "$zero_commit_guard_line" ]] \
  || fail "residual edits must be committed before the final zero-commit guard"
pass "initial work commits residual edits after earlier Squad commits"

# shellcheck disable=SC2016 # Assertion intentionally matches literal shell source.
assert_contains "$revision_source" '--force-with-lease=refs/heads/${branch_name}:${revision_remote_oid}' "revision uses immutable explicit lease"
[[ "$revision_source" != *"git push --force origin"* ]] || fail "revision contains destructive force fallback"
pass "revision publishing uses an immutable lease without force fallback"

# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
assert_contains "$revision_source" 'revision_start_head=$(git rev-parse HEAD)' "revision captures starting HEAD"
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
assert_contains "$revision_source" '"$revision_head" == "$revision_start_head"' "revision rejects unchanged HEAD"
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
assert_contains "$revision_source" 'capability_instructions=$(implementer_capability_instructions)' "revision prompt uses mode-specific capabilities"
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
assert_contains "$issue_source" 'capability_instructions=$(implementer_capability_instructions)' "initial prompt uses mode-specific capabilities"
pass "implementation prompts use mode-specific capabilities and revision delta guard"

worker_source=$(cat "$WORKER_SCRIPT")
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
assert_contains "$worker_source" 'git/matching-refs/${prefix}' "budget uses matching-refs endpoint"
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
assert_contains "$worker_source" 'git/refs/${CURRENT_CLAIM_REF#refs/}' "claim deletion uses plural refs endpoint"
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
assert_contains "$worker_source" 'repos/${REPO_SLUG}/git/refs' "claim creation uses refs endpoint"
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
assert_contains "$worker_source" '-f ref="$claim_ref"' "claim creation sends the atomic ref name"
pass "claim and budget guards use the expected GitHub ref API paths"

label_setup_source=$(declare -f ensure_loop_labels)
for required_label in squad squad:processing squad:done squad:revision loop:auto; do
  assert_contains "$label_setup_source" "\"${required_label}\"" "label setup includes ${required_label}"
done
assert_contains "$label_setup_source" '--force' "label setup is idempotent"
main_source=$(sed -n '/^main()/,/^}/p' "$WORKER_SCRIPT")
assert_contains "$main_source" 'ensure_loop_labels' "worker startup provisions required labels"
pass "fresh repositories receive required queue and status labels"

verify_runner_source=$(declare -f run_agent_command)
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
assert_contains "$verify_runner_source" 'sudo -n -u "$AGENT_USER"' "verification uses coding user"
assert_contains "$verify_runner_source" '/usr/bin/env -i' "verification starts with empty environment"
[[ "$verify_runner_source" != *"GITHUB_TOKEN="* && "$verify_runner_source" != *"COPILOT_PAT="* ]] \
  || fail "verification runner must not inject publisher credentials"
entrypoint_source=$(cat "$ENTRYPOINT_SCRIPT")
dockerfile_source=$(cat "${ROOT_DIR}/worker/Dockerfile")
remote_deploy_source=$(cat "$REMOTE_DEPLOY_SCRIPT")
# shellcheck disable=SC2016 # Assertion intentionally matches literal shell source.
assert_contains "$remote_deploy_source" 'sync_sources+=("$SCRIPT_DIR/$f")' "rsync joins checkout path and synced filename"
token_boundary_source=$(cat "$TOKEN_BOUNDARY_SCRIPT")
assert_not_contains "$token_boundary_source" '--data "{}"' "token boundary must not use malformed empty payloads"
assert_contains "$token_boundary_source" 'assert_publisher_collision' "token boundary uses a write-capable positive control"
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
assert_contains "$token_boundary_source" 'git/ref/heads/${default_branch}' "token boundary queries the authoritative default ref"
# shellcheck disable=SC2016 # Assertions intentionally match literal jq source.
assert_contains "$token_boundary_source" 'head: $branch, base: $branch' "token boundary uses an impossible same-branch PR"
pass "token boundary uses non-mutating collision probes"
squad_capability_source=$(cat "$SQUAD_CAPABILITY_SCRIPT")
assert_not_contains "$squad_capability_source" 'printenv WORKSPACE_DIR' "capability proof must not expect workspace in container env"
assert_contains "$squad_capability_source" 'source /home/copilot/.workspace_env' "capability proof loads trusted runtime workspace config"
assert_contains "$squad_capability_source" '/workspace/*' "capability proof confines its source checkout"
pass "Squad capability proof resolves the protected workspace safely"
assert_contains "$dockerfile_source" 'useradd -m -s /bin/bash -g squad squad-agent' "worker image creates coding user"
assert_contains "$dockerfile_source" 'credential-guard-builder' "worker image builds the non-dumpable credential launcher"
assert_contains "$dockerfile_source" 'libcredential-guard.so' "worker image installs the post-exec non-dumpable guard"
# shellcheck disable=SC2016 # Assertion intentionally matches literal shell source.
assert_contains "$entrypoint_source" 'chmod 600 "$TOKEN_FILE"' "publisher token file is private"
[[ "$entrypoint_source" != *"x-access-token"* ]] || fail "entrypoint must not place tokens in clone URLs"
assert_contains "$entrypoint_source" "git-credential-helper.sh" "publisher uses host-restricted credential helper"
assert_contains "$entrypoint_source" 'COPILOT_PAT is required' "startup requires dedicated Copilot credential"
assert_contains "$entrypoint_source" 'github_pat_*' "startup requires a fine-grained Copilot credential"
assert_contains "$entrypoint_source" 'only the Copilot Requests account permission' "startup documents least-privilege Copilot scope"
assert_contains "$entrypoint_source" 'COPILOT_PAT must not reuse' "startup rejects publisher-token reuse"
pass "verification and publisher credentials use separate OS identities"

# shellcheck disable=SC2016 # Assertion intentionally matches literal shell source.
assert_contains "$remote_deploy_source" 'ssh "$REMOTE_HOST" "rm -rf ${REMOTE_PATH}/${f}"' "scp fallback removes stale remote directories"
pass "scp fallback mirrors directory replacement semantics"

# shellcheck disable=SC2016 # The assertion intentionally matches literal shell source.
assert_contains "$entrypoint_source" 'write_workspace_export LOOP_VERIFY "${LOOP_VERIFY:-off}"' "entrypoint routes verify through shell escaping"
literal_verify='npm --prefix backend ci && printf should-not-run'
escaped_export=$(printf 'export LOOP_VERIFY=%q\n' "$literal_verify")
unset LOOP_VERIFY
# shellcheck disable=SC1090,SC1091
source /dev/stdin <<<"$escaped_export"
assert_eq "$literal_verify" "$LOOP_VERIFY" "shell-escaped verify round trip"
pass "literal verify command survives shell export without execution"

# Undefine the gh override to prevent set -e interaction
unset -f gh || true

# Undefine the gh override to prevent set -e interaction
unset -f gh || true

# Compose generation tests — use repos.example.json if available, otherwise
# generate from a temporary synthetic config.
REPOS_EXAMPLE="${ROOT_DIR}/repos.example.json"
if [[ -f "$REPOS_EXAMPLE" ]]; then
  COMPOSE_FILE="${TMP_ROOT}/docker-compose.workers.yml"
  ENV_FILE_TMP="${TMP_ROOT}/.env.workers"
  # Create minimal env file for generate (no real secrets)
  cat > "$ENV_FILE_TMP" <<'ENVEOF'
GH_APP_ID=000000
GH_APP_INSTALL_ID=000000
GH_APP_PEM_FILE=/tmp/fake.pem
COPILOT_PAT=github_pat_test
POLL_INTERVAL=60
ENVEOF
  export REPOS_JSON="$REPOS_EXAMPLE"
  export COMPOSE_FILE
  export ENV_FILE="$ENV_FILE_TMP"
  "$DEPLOY_SCRIPT" generate >/dev/null

  # Generic assertions: every generated worker has init and implementer
  compose_content=$(cat "$COMPOSE_FILE")
  assert_contains "$compose_content" 'init: true' "generated compose uses init process"
  assert_contains "$compose_content" 'LOOP_IMPLEMENTER=' "generated compose sets implementer"
  # shellcheck disable=SC2016 # Compose expression must remain literal in generated YAML.
  assert_contains "$compose_content" '${BIND_ADDRESS:-127.0.0.1}' "generated compose reads bind address from env file"
  pass "generated compose from example config has expected structure"
fi

echo "1..${TEST_COUNT}"
