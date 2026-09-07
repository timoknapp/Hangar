#!/usr/bin/env bash
# Behavioral regressions with disposable local Git and explicit boundary/API fakes.
# These tests do NOT prove sudo/kernel/container isolation; run agent-launch.container.sh too.
# shellcheck disable=SC2034,SC2317,SC2218
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GITHUB_OWNER=example GITHUB_REPO=repo REPO_BRANCH=main
export WORKSPACE_DIR="$TMP/repo" LOOP_STATE_DIR="$TMP/state"
AGENT_GROUP=$(id -gn)
export AGENT_GROUP
# shellcheck source=/dev/null
source "$ROOT/worker/worker-loop.sh"
# shellcheck source=tests/fixtures/evidence-user-switch.sh
source "$ROOT/tests/fixtures/evidence-user-switch.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "PASS: $*"; }
reject() { if "$@"; then fail "unexpected success: $*"; fi; }
run_rc() { RC=0; "$@" || RC=$?; }
git init --bare -q "$TMP/remote"
git init -q "$WORKSPACE_DIR"
cd "$WORKSPACE_DIR"
git config user.name Fixture
git config user.email fixture@example.invalid
mkdir -p .squad
printf 'active policy\n' > .squad/GOVERNANCE.md
printf 'base\n' > app.txt
git add . && git commit -qm base && git branch -M main
git remote add origin "$TMP/remote"
# Sanitization must retain this fixture-only local destination, never a network remote.
CLEAN_REPO_URL="$TMP/remote"
git push -q origin main
init_loop_state
begin_task
prepare_task_base feature
BASE="$TASK_BASE_SHA"
[[ "$(git rev-parse HEAD)" == "$BASE" ]] || fail "fresh exact HEAD"
ok 'fresh preparation uses immutable fetched base'
printf 'unrelated\n' > keep.txt
before=$(git rev-parse HEAD)
reject prepare_task_base another
[[ -f keep.txt && "$(git rev-parse HEAD)" == "$before" ]] || fail 'dirty work discarded'
rm keep.txt
ok 'dirty preparation fails without deleting work'
# Fetch/checkout failures remain errors when the outer function is in || context.
git() { if [[ "$1" == fetch ]]; then return 44; fi; command git "$@"; }
reject prepare_task_base fetch-fails
[[ "$(git rev-parse HEAD)" == "$before" ]] || fail 'failed fetch changed head'
unset -f git
# Re-source only the trusted git wrapper; subsequent tests need real local Git.
eval "$(sed -n '/^git() {/,/^}/p' "$ROOT/worker/worker-loop.sh")"
git() { if [[ "$1" == checkout ]]; then return 45; fi; command git "$@"; }
reject prepare_task_base checkout-fails
[[ "$(git rev-parse HEAD)" == "$before" ]] || fail 'failed checkout changed head'
unset -f git
eval "$(sed -n '/^git() {/,/^}/p' "$ROOT/worker/worker-loop.sh")"
ok 'fetch and checkout failures propagate; no suppressed reset'
TASK_BASE_SHA="$BASE" TASK_START_HEAD="$BASE" TASK_BRANCH=feature
printf 'changed\n' > app.txt
git commit -qam change
HEAD_SHA=$(git rev-parse HEAD)
task_integrity
git checkout -qb wrong
reject task_integrity
git checkout -q feature
ok 'branch drift rejected, not renamed'
# Advance remote base without changing work branch.
git checkout -q main
printf 'shipped\n' > shipped.txt
git add shipped.txt && git commit -qm shipped && git push -q origin main
git checkout -q feature
reject fresh_base_unchanged
[[ -f app.txt ]] || fail 'base drift damaged work'
ok 'remote base advance invalidates task instead of showing reversions'
TASK_BASE_SHA="$BASE" TASK_START_HEAD="$BASE" TASK_BRANCH=feature
# Full >1500-line input and trusted base policy, actual final summary all delivered.
seq 1 1800 > late.txt
git add late.txt && git commit -qm 'large reviewed diff'
printf 'agent policy override\n' > .squad/GOVERNANCE.md
PR_EXECUTIVE_SUMMARY=$'## Problem\nConcrete problem.\n## Root Cause\nCause.\n## Solution\nSmall solution.\n## Testing\n### UI evidence\nUI: N/A — no UI change.\n## Future Work\nNone.'
FINAL_PR_BODY="$PR_EXECUTIVE_SUMMARY"
LOOP_CRITIC=true LOOP_CRITIC_RUBRIC=repo-aware LOOP_MAX_REVIEW_BYTES=262144
COPILOT_PAT=fixture
CRITIC_INPUT_NONCE_OVERRIDE=fixture-nonce
run_agent_copilot() {
  local input
  input=$(find "$WORKSPACE_DIR" -maxdepth 1 -name '.critic-input.*.md')
  grep -q '^+1800$' "$input" || fail 'late diff missing'
  grep -q 'active policy' "$input" || fail 'trusted policy missing'
  grep -q 'Actual final PR body' "$input" || fail 'summary not reviewed'
  grep -q 'UI: N/A' "$input" || fail 'nested UI summary lost'
  bash "$ROOT/tests/critic-complete-input.test.sh" --emit "$input"
}
run_critic
[[ "$REVIEWED_HEAD" == "$(git rev-parse HEAD)" && -n "$REVIEW_INPUT_HASH" && -n "$REVIEW_BODY_HASH" ]] || fail 'unbound review'
LOOP_MAX_REVIEW_BYTES=20
reject run_critic
[[ "$CRITIC_FAILURE_KIND" == incomplete || "$CRITIC_FAILURE_KIND" == infrastructure ]] || fail 'oversize not blocked'
LOOP_MAX_REVIEW_BYTES=262144
git restore .squad/GOVERNANCE.md
ok 'full late diff and base policy plus actual body reviewed; oversize fails closed'
FINAL_PR_BODY='### UI evidence
![actual view](evidence-fixture/images/screen.png)
![unapproved](other-fixture/screen.png)'
[[ "$(bind_review_asset_links "$HEAD_SHA")" == "$FINAL_PR_BODY" ]] || fail 'default path rewriting is not opt-in'
(
  LOOP_PROFILE_DIR="$TMP/profile"
  mkdir -p "$LOOP_PROFILE_DIR"
  printf 'evidence-fixture/images/\n' >"$LOOP_PROFILE_DIR/review-assets.txt"
  # Root-owned profile validation is exercised separately; this fixture tests data binding.
  read_profile_file() { cat "$LOOP_PROFILE_DIR/$1"; }
  linked=$(bind_review_asset_links "$HEAD_SHA")
  [[ "$linked" == *"/blob/${HEAD_SHA}/evidence-fixture/images/screen.png?raw=true"* ]] || fail 'image link not immutable'
  [[ "$linked" == *'](other-fixture/screen.png)'* ]] || fail 'unapproved root rewritten'
  for bad in '../' '/absolute/' 'evidence-fixture/../' 'evidence-fixture'; do
    printf '%s\n' "$bad" >"$LOOP_PROFILE_DIR/review-assets.txt"
    reject bind_review_asset_links "$HEAD_SHA"
  done
)
FINAL_PR_BODY="$PR_EXECUTIVE_SUMMARY"
ok 'private opt-in asset roots bound to immutable head; no shipped path or upload'
# Exact verification runner classification; sudo is intentionally replaced, not claimed tested.
sanitize_repository_git_config() { return 0; }
MODE=pass
run_agent_command() {
  if [[ "$1" == true && "$MODE" == launch-fail ]]; then echo 'launcher EPERM'; return 127; fi
  echo HANGAR_AGENT_STARTED
  [[ "$1" == true ]] && return 0
  case "$MODE" in
    code-fail) echo 'test failure'; return 1 ;;
    policy) echo 'missing real image evidence'; return 78 ;;
    timeout) return 124 ;;
    mutate) git commit --allow-empty -qm unexpected; return 0 ;;
    *) return 0 ;;
  esac
}
LOOP_VERIFY='fixture test'
MODE=launch-fail
run_rc run_verify_gate
[[ "$RC" == 4 && "$VERIFY_FAILURE_KIND" == infrastructure ]] || fail 'infra disguised as code'
MODE=code-fail
run_rc run_verify_gate
[[ "$RC" == 1 && "$VERIFY_FAILURE_KIND" == code ]] || fail 'test failure classification'
MODE=policy
run_rc run_verify_gate
[[ "$RC" == 5 && "$VERIFY_FAILURE_KIND" == policy ]] || fail 'evidence policy correction'
MODE=timeout
run_rc run_verify_gate
[[ "$RC" == 4 ]] || fail 'timeout classification'
MODE=mutate
run_rc run_verify_gate
[[ "$RC" == 4 ]] || fail 'head change accepted as verify success'
ok 'infra, policy, timeout and head mutation never become code failures'
# Source-owned redaction writes private files only; use obviously synthetic marker.
export GH_TOKEN=synthetic-secret-for-redaction
printf '%s\n' "$GH_TOKEN" > "$TMP/raw-log"
retain_gate_log "$TMP/raw-log" redaction
if grep -R -q synthetic-secret-for-redaction "$LOOP_STATE_DIR"; then fail 'secret log retention'; fi
[[ "$(stat -c %a "$LOOP_STATE_DIR")" == 700 ]] || fail 'state mode'
ok 'redacted evidence is private and outside checkout'
LOOP_REQUIRED_LABELS='["approved-work"]'
LOOP_UNATTENDED_LABELS='["squad"]'
ISSUE='{"state":"OPEN","title":"Design only","body":"No product code","labels":[{"name":"squad"},{"name":"approved-work"},{"name":"squad:processing"}]}'
issue_policy_authorized "$ISSUE"
is_autonomous_issue "$ISSUE"
ISSUE_CONTRACT_HASH=$(issue_contract_hash "$ISSUE")
CURRENT_CLAIM_REF=refs/heads/squad-claims/issue-1 CURRENT_CLAIM_OID=owned
REMOTE_OID=owned
gh() { if [[ "$1" == issue ]]; then echo "$ISSUE"; else echo "$REMOTE_OID"; fi; }
publication_authorized 1 squad squad:processing
ISSUE=$(jq '.labels |= map(select(.name != "approved-work"))' <<<"$ISSUE")
reject publication_authorized 1 squad squad:processing
ISSUE=$(jq '.labels += [{name:"approved-work"}] | .body="New scope"' <<<"$ISSUE")
reject publication_authorized 1 squad squad:processing
ISSUE=$(jq '.body="No product code"' <<<"$ISSUE")
REMOTE_OID=replacement
reject publication_authorized 1 squad squad:processing
ok 'same approval, contract hash and ownership enforced before publication'
# Required names must each have one successful exact-head rollup row; no missing/ambiguous/pending pass.
LOOP_REQUIRED_CHECKS='["CI", "Governance"]'
CHECKS='{"statusCheckRollup":[{"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"Governance","status":"COMPLETED","conclusion":"SUCCESS"}]}'
remote_checks_ready "$CHECKS"
reject remote_checks_ready "$(jq '.statusCheckRollup[0].status="IN_PROGRESS"' <<<"$CHECKS")"
reject remote_checks_ready "$(jq '.statusCheckRollup |= .[0:1]' <<<"$CHECKS")"
reject remote_checks_ready "$(jq '.statusCheckRollup += [.statusCheckRollup[0]]' <<<"$CHECKS")"
reject remote_checks_ready "$(jq '.statusCheckRollup[1].conclusion="FAILURE"' <<<"$CHECKS")"
LOOP_REQUIRED_CHECKS='[]'
reject remote_checks_ready "$CHECKS"
ok 'remote readiness rejects absent policy, pending, failure and ambiguous checks'
# Cleanup consumes terminal revision without deleting local code/branch.
CURRENT_CLAIM_REF="" CURRENT_CLAIM_OID=""
CALLS="$TMP/calls"
gh() { printf '%s\n' "$*" >>"$CALLS"; }
cleanup_issue 1 feature 'terminal fixture'
grep -q -- '--remove-label squad:revision' "$CALLS" || fail 'revision trigger survived'
if grep -q -- '--add-label squad:done' "$CALLS"; then fail 'failure marked done'; fi
git show-ref --verify --quiet refs/heads/feature || fail 'branch deleted'
ok 'terminal failure consumes retry trigger, retains branch, never marks done'
# Pending receipt is durable: no new model run; exact head/check/body transition only.
LOOP_REQUIRED_CHECKS='["CI", "Governance"]'
LOOP_REQUIRED_LABELS='["approved-work"]'
TASK_BASE_SHA="$BASE" TASK_KEEP_DRAFT=false
TASK_DEADLINE=$(( $(date +%s) + 600 ))
VERIFIED_HEAD=$(git rev-parse HEAD)
REVIEWED_HEAD="$VERIFIED_HEAD"
REVIEW_INPUT_HASH=review-input REVIEW_DIFF_HASH=diff
FINAL_PR_BODY="$PR_EXECUTIVE_SUMMARY"
REVIEW_BODY_HASH=$(printf '%s' "$FINAL_PR_BODY" | sha256sum | cut -d' ' -f1)
CURRENT_CLAIM_REF=refs/heads/squad-claims/issue-1 CURRENT_CLAIM_OID=owned
ISSUE=$(jq '.body="No product code"' <<<"$ISSUE")
ISSUE_CONTRACT_HASH=$(issue_contract_hash "$ISSUE")
REMOTE_OID=owned
REMOTE_DRAFT=true
PR_MODE=pending
GH_CALLS="$TMP/readiness-calls"
: > "$GH_CALLS"
release_owned_ref() { return 0; }
gh() {
  printf '%s\n' "$*" >>"$GH_CALLS"
  if [[ "$1 $2" == 'issue view' ]]; then echo "$ISSUE"; return 0; fi
  if [[ "$1" == api ]]; then
    if [[ "$2" == */pulls/1 ]]; then
      gh pr view fixture --json fixture | jq '{state:"open",draft:.isDraft,merged:false,
        head:{sha:.headRefOid},base:{sha:.baseRefOid},body,mergeable:true}'
    else echo "$REMOTE_OID"; fi
    return 0
  fi
  if [[ "$1 $2" == 'pr ready' ]]; then
    if [[ "$*" == *--undo* ]]; then REMOTE_DRAFT=true; else REMOTE_DRAFT=false; fi
    return 0
  fi
  if [[ "$1 $2" == 'pr view' ]]; then
    if [[ "$*" == *'--json number'* ]]; then echo 1; return 0; fi
    if [[ "$*" == *'--jq .isDraft'* ]]; then echo "$REMOTE_DRAFT"; return 0; fi
    local checks="$CHECKS" head="$VERIFIED_HEAD" body="$FINAL_PR_BODY"
    if [[ "$PR_MODE" == pending ]]; then checks=$(jq '.statusCheckRollup[0].status="IN_PROGRESS"' <<<"$checks"); fi
    if [[ "$PR_MODE" == failed ]]; then checks=$(jq '.statusCheckRollup[0].conclusion="FAILURE"' <<<"$checks"); fi
    if [[ "$PR_MODE" == drift ]]; then head=drift; fi
    jq --arg head "$head" --arg base "$BASE" --arg body "$body" --argjson draft "$REMOTE_DRAFT" \
      '. + {state:"OPEN",headRefOid:$head,baseRefOid:$base,body:$body,isDraft:$draft,mergeable:"MERGEABLE"}' <<<"$checks"
    return 0
  fi
}
save_pending_publication 1 feature https://example.invalid/pr/1
resume_pending_publication
[[ -f "$LOOP_STATE_DIR/pending.json" ]] || fail 'pending receipt lost'
if grep -q 'pr ready' "$GH_CALLS"; then fail 'pending checks marked ready'; fi
PR_MODE=success
resume_pending_publication
[[ "$(jq -r .phase "$LOOP_STATE_DIR/pending.json")" == promoting ]] || fail 'promoting phase not durable'
PR_MODE=pending
resume_pending_publication
[[ "$(grep -c 'pr ready' "$GH_CALLS")" == 1 ]] || fail 'Ready event triggered toggle/retry'
PR_MODE=success
POLL_INTERVAL=0
resume_pending_publication
[[ ! -f "$LOOP_STATE_DIR/pending.json" && -f "$LOOP_STATE_DIR/ready-1.json" ]] || fail 'ready not finalized'
grep -q 'pr ready' "$GH_CALLS" || fail 'successful draft not promoted'
grep -q -- '--add-label squad:done' "$GH_CALLS" || fail 'success status missing'
ok 'normal poll resumes receipt and only promotes after exact-head checks'
# Reset the receipt and prove terminal CI failure consumes it without Ready or code retry.
CURRENT_CLAIM_REF=refs/heads/squad-claims/issue-1 CURRENT_CLAIM_OID=owned
TASK_DEADLINE=$(( $(date +%s) + 600 ))
REMOTE_DRAFT=true
PR_MODE=failed
: > "$GH_CALLS"
save_pending_publication 1 feature https://example.invalid/pr/1
resume_pending_publication
[[ ! -f "$LOOP_STATE_DIR/pending.json" && -f "$LOOP_STATE_DIR/blocked-publication-1.json" ]] || fail 'failed checks stayed in retry loop'
if grep -q -- '--add-label squad:done' "$GH_CALLS"; then fail 'remote failure marked done'; fi
ok 'failed current-head CI is terminal without another outer attempt'
# Generic planner refreshes trusted goal content and skips identical input, no LLM churn.
CURRENT_ISSUE="" TASK_DEADLINE=0
LOOP_AUTONOMOUS=true LOOP_GOAL_FILE=BACKLOG.md LOOP_WORK_SCOPE=all
git checkout -q main
printf 'approved goal\n' > BACKLOG.md
git add BACKLOG.md && git commit -qm goal
git push -q origin HEAD:main
LOOP_MAX_OPEN_AUTO_ISSUES=3
count_open_auto_issues() { echo 0; }
PLANNER_CALLS="$TMP/planner-calls"
run_agent_copilot() { echo called >>"$PLANNER_CALLS"; echo NO_TASK; }
generate_work
generate_work
[[ "$(wc -l <"$PLANNER_CALLS")" == 1 ]] || fail 'identical no-op repeated model call'
ok 'planner refreshes trusted base and skips unchanged no-op input'
# WIP creates are atomic across workers and ownership is not shared across issues.
LOOP_MAX_ACTIVE_ISSUES=1
WIP_LOCK="$TMP/wip-lock"
CURRENT_ISSUE=7
CURRENT_CLAIM_REF=refs/heads/squad-claims/issue-7
CURRENT_CLAIM_OID=owner-a
REMOTE_WIP_ISSUE=other
CURRENT_WIP_REF=""
gh() {
  if [[ "$*" == *'--method POST'* ]]; then mkdir "$WIP_LOCK" 2>/dev/null; return $?; fi
  if [[ "$*" == *'/git/commits/'* ]]; then printf '{"issue":"%s"}\n' "$REMOTE_WIP_ISSUE"; return 0; fi
  echo existing-owner
}
set +e
(acquire_wip_slot >/dev/null 2>&1; echo $? >"$TMP/wip-a") & a=$!
(acquire_wip_slot >/dev/null 2>&1; echo $? >"$TMP/wip-b") & b=$!
wait "$a" "$b"
set -e
[[ $(( $(cat "$TMP/wip-a") + $(cat "$TMP/wip-b") )) == 1 ]] || fail 'WIP race admitted two workers'
reject acquire_wip_slot
ok 'repository WIP race admits one owner; another issue cannot take existing slot'

# Losing a claim must not remove a replacement owner's processing/revision labels.
CURRENT_CLAIM_REF=refs/heads/squad-claims/issue-7 CURRENT_CLAIM_OID=old-owner
LOST_CALLS="$TMP/lost-claim-calls"
gh() { printf '%s\n' "$*" >>"$LOST_CALLS"; echo replacement-owner; }
reject cleanup_issue 7 feature 'ownership changed'
if grep -q 'issue edit' "$LOST_CALLS"; then fail 'cleanup mutated replacement owner labels'; fi
ok 'terminal cleanup preserves replacement claim owner state'
# Actions fallback preserves exact head/branch/event and latest attempt semantics.
LOOP_CHECK_BACKEND=actions
LOOP_REQUIRED_WORKFLOWS='["CI", "Governance"]'
LOOP_REQUIRED_CHECKS='["test", "scope"]'
ACTIONS_MODE=pass
JOBS_REQUESTED="$TMP/jobs-requested"
gh() {
  if [[ "$1 $2" == 'pr view' ]]; then
    if [[ "$*" == *'--json number'* ]]; then echo 7; return 0; fi
    printf '{"state":"OPEN","isDraft":true,"headRefOid":"head-a","baseRefOid":"base-a","body":"body","mergeable":"MERGEABLE"}\n'
    return 0
  fi
  if [[ "$1" == api && "$2" == */pulls/7 ]]; then
    printf '{"state":"open","draft":true,"merged":false,"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"base":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"body":"body","mergeable":true}\n'
    return 0
  fi
  if [[ "$*" == *'--method GET'* ]]; then
    local data='{"total_count":4,"workflow_runs":[
      {"id":1,"workflow_id":1,"run_number":1,"run_attempt":1,"name":"CI","head_sha":"head-a","head_branch":"feature","event":"pull_request","status":"completed","conclusion":"failure"},
      {"id":2,"workflow_id":1,"run_number":2,"run_attempt":1,"name":"CI","head_sha":"head-a","head_branch":"feature","event":"pull_request","status":"completed","conclusion":"success"},
      {"id":3,"workflow_id":2,"run_number":1,"run_attempt":1,"name":"Governance","head_sha":"head-a","head_branch":"feature","event":"pull_request","status":"completed","conclusion":"success"},
      {"id":4,"workflow_id":3,"run_number":1,"run_attempt":1,"name":"Other head","head_sha":"head-b","head_branch":"feature","event":"pull_request","status":"completed","conclusion":"failure"}]}'
    [[ "$ACTIONS_MODE" != missing ]] || data=$(jq '.workflow_runs |= map(select(.id != 3)) | .total_count=(.workflow_runs|length)' <<<"$data")
    jq '(.workflow_runs[] | select(.head_sha=="head-a") | .head_sha)="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' <<<"$data"; return 0
  fi
  if [[ "$*" == *'/jobs?'* ]]; then
    [[ "$ACTIONS_MODE" != denied ]] || return 1
    echo "$*" >>"$JOBS_REQUESTED"
    local name=test
    [[ "$*" != *'/runs/3/'* ]] || name=scope
    printf '{"total_count":1,"jobs":[{"name":"%s","status":"completed","conclusion":"success"}]}\n' "$name"
    return 0
  fi
  return 1
}
snapshot=$(read_pr_snapshot feature)
remote_checks_ready "$snapshot"
if grep -qE '/runs/(1|4)/' "$JOBS_REQUESTED"; then fail 'wrong head/old attempt jobs queried'; fi
ACTIONS_MODE=missing
snapshot=$(read_pr_snapshot feature)
reject remote_checks_ready "$snapshot"
ACTIONS_MODE=denied
reject read_pr_snapshot feature
ok 'Actions backend handles inaccessible check rollup without skipping workflows/jobs'
