#!/usr/bin/env bash
# Block 3b: input the Copilot CLI masks from every model never fails the
# attempt. The quality gates still pass everything else, publication becomes a
# forced draft with an explicit warning, and the issue waits for a human with
# squad:needs-decision. It is never promoted to Ready.
# shellcheck disable=SC1091,SC2016,SC2030,SC2031,SC2034,SC2317 # subshell-scoped scenarios
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export WORKSPACE_DIR="$TMP/repo" LOOP_STATE_DIR="$TMP/state"
export GITHUB_OWNER=example GITHUB_REPO=repo REPO_BRANCH=main
export AGENT_GROUP; AGENT_GROUP=$(id -gn)
source "$ROOT/worker/worker-loop.sh"
source "$ROOT/tests/fixtures/evidence-user-switch.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "PASS: $*"; }
mkdir -p "$WORKSPACE_DIR"; cd "$WORKSPACE_DIR"
git init -q; git config user.name Fixture; git config user.email fixture@example.invalid
printf 'seed\n' > seed.txt; git add .; git commit -qm base; git branch -M main
TASK_BASE_SHA=$(git rev-parse HEAD); TASK_START_HEAD="$TASK_BASE_SHA"
git checkout -qb feature; TASK_BRANCH=feature
printf 'const fixture = "Authorization: Bearer abcdefghijklmnop";\n' > auth.test.js
git add . && git commit -qm 'fixture with a real-looking token'
cat > "$TMP/filter.js" <<'JS'
module.exports = { secretFilterCreate: () => 1,
  secretFilterFilter: (h, s) => ({changed: /abcdefghijklmnop/.test(s), value: s}) };
JS
LOOP_CRITIC=true LOOP_CRITIC_MODEL=fixture-model LOOP_MAX_REVIEW_BYTES=1048576 LOOP_CRITIC_ATTEMPTS=2
LOOP_COPILOT_SECRET_FILTER_MODULE="$TMP/filter.js" COPILOT_PAT=fixture CRITIC_FINDINGS_LEDGER='[]'
CURRENT_ISSUE_CONTEXT='Add auth fixture.' issue_title=Fixture issue_body='Add auth fixture.'
SUMMARY=$'## Problem\np\n## Root Cause\nr\n## Solution\ns\n## Testing\nt\n## Future Work\nNone'
PR_EXECUTIVE_SUMMARY="$SUMMARY"
CALLS=0
run_agent_copilot() { CALLS=$((CALLS + 1)); fail 'masked input reached a model'; }
run_verify_with_corrections() { VERIFIED_HEAD=$(git rev-parse HEAD); return 0; }
take_correction() { fail 'masking consumed a code correction'; }

# --- critic classifies masking distinctly and never retries it ---
if run_critic_attempts >/dev/null 2>&1; then fail 'masked input approved'; fi
[[ "$CRITIC_FAILURE_KIND" == masked && "$CRITIC_MASKED_LINES" =~ ^[0-9,]+$ ]] || fail "kind=$CRITIC_FAILURE_KIND lines=$CRITIC_MASKED_LINES"
[[ "$CRITIC_FEEDBACK" != *abcdefghijklmnop* ]] || fail 'feedback leaked the masked text'
ok 'masked input is its own failure kind, named by line numbers only, never retried, never shown to a model'

# --- gates pass everything else and force a warned draft ---
TASK_KEEP_DRAFT=false
run_quality_gates >/dev/null 2>&1 || fail "masked review failed the attempt: $GATE_NOTE"
[[ "$TASK_KEEP_DRAFT" == true && -n "$TASK_MASKED_REVIEW" && "$GATE_NOTE" == 'Masked review input; draft for human review' ]] || fail 'not forced to draft'
[[ "$FINAL_PR_BODY" == *'Not independently reviewed'* && "$FINAL_PR_BODY" == *"lines ${TASK_MASKED_REVIEW}"* ]] || fail 'PR body lacks the warning'
[[ "$REVIEWED_HEAD" == "$(git rev-parse HEAD)" && "$REVIEW_BODY_HASH" == "$(printf '%s' "$FINAL_PR_BODY" | sha256sum | cut -d' ' -f1)" ]] ||
  fail 'warned draft not bound to its exact head and body'
ok 'everything else passes; the attempt becomes a draft whose body names the unreviewed lines'

# --- a real REQUEST_CHANGES is still a review failure, not a draft ---
(
  LOOP_COPILOT_SECRET_FILTER_MODULE=off TASK_KEEP_DRAFT=false TASK_MASKED_REVIEW=""
  run_critic_review() { CRITIC_FAILURE_KIND=review; CRITIC_FEEDBACK='fix it'; return 1; }
  take_correction() { return 1; }
  if run_quality_gates >/dev/null 2>&1; then fail 'review rejection turned into a draft'; fi
  [[ "$TASK_KEEP_DRAFT" == false && -z "$TASK_MASKED_REVIEW" ]] || fail 'review rejection marked as masked'
)
(
  run_critic_review() { CRITIC_FAILURE_KIND=incomplete; CRITIC_FEEDBACK='delivery gap'; return 1; }
  TASK_KEEP_DRAFT=false TASK_MASKED_REVIEW=""
  if run_quality_gates >/dev/null 2>&1; then fail 'delivery gap turned into a draft'; fi
  [[ "$TASK_KEEP_DRAFT" == false ]] || fail 'delivery gap forced draft'
)
ok 'review rejections and delivery gaps keep failing; only CLI masking becomes a draft'

# --- pending publication: forced draft waits for a human, never Ready ---
init_loop_state
EDITS="$TMP/edits" COMMENTS="$TMP/comments"; : >"$EDITS"; : >"$COMMENTS"
gh() {
  case "$1 $2" in
    'issue edit') printf '%s\n' "$*" >>"$EDITS" ;;
    'issue comment') printf '%s\n' "$*" >>"$COMMENTS" ;;
    'pr ready') fail 'masked draft promoted to Ready' ;;
    *) fail "unexpected gh: $*" ;;
  esac
}
head=$(git rev-parse HEAD) body="$FINAL_PR_BODY"
FIXTURE_SNAPSHOT=$(jq -n --arg h "$head" --arg b "$body" --arg base "$TASK_BASE_SHA" \
  '{state:"OPEN",headRefOid:$h,body:$b,baseRefOid:$base,isDraft:true,mergeable:"MERGEABLE",statusCheckRollup:[],checkPolicy:{policyHash:"p"}}')
read_pr_snapshot() { printf "%s\n" "$FIXTURE_SNAPSHOT"; }
publication_authorized() { return 0; }
pinned_base_contained() { return 0; }
ensure_pr_is_draft() { return 0; }
release_issue_claim() { return 0; }
claim_owned() { return 0; }
LOOP_REQUIRED_CHECKS='["ci"]'
jq -n --arg h "$head" --arg b "$body" --arg base "$TASK_BASE_SHA" --arg bh "$(printf '%s' "$body" | sha256sum | cut -d' ' -f1)" \
  --arg m "$TASK_MASKED_REVIEW" \
  '{attempt:{kind:"issue",startedAt:"1",credits:"5"},maskedLines:$m,issue:"7",branch:"feature",url:"https://example.invalid/pr/1",
    base:$base,head:$h,verified:$h,reviewed:$h,body:$b,bodyHash:$bh,claim:"refs/heads/squad-claims/issue-7",claimOid:"x",
    wip:"",manualIntake:false,deadline:9999999999,keepDraft:true,checkPolicy:{policyHash:"p"},ciRounds:0}' >"$LOOP_STATE_DIR/pending.json"
resume_pending_publication
grep -q -- '--add-label squad:needs-decision' "$EDITS" || fail "masked draft not routed to needs-decision: $(cat "$EDITS")"
! grep -q -- '--add-label squad:done' "$EDITS" || fail 'masked draft marked done'
grep -q "review-input lines ${TASK_MASKED_REVIEW}" "$COMMENTS" || fail 'comment does not name the lines'
grep -q '"outcome":"draft","class":"decision"' "$COMMENTS" || fail 'receipt does not record a decision draft'
[[ ! -f "$LOOP_STATE_DIR/pending.json" && -f "$LOOP_STATE_DIR/waiting-human-7.json" ]] || fail 'pending not archived for human'
ok 'pending masked draft waits on squad:needs-decision with the line numbers, never Ready or done'

: >"$EDITS"; : >"$COMMENTS"
jq '.maskedLines=""' "$LOOP_STATE_DIR/waiting-human-7.json" >"$LOOP_STATE_DIR/pending.json"; rm "$LOOP_STATE_DIR/waiting-human-7.json"
resume_pending_publication
grep -q -- '--add-label squad:review-pending' "$EDITS" || fail 'task-mandated draft lost its old label'
ok 'task-mandated drafts keep their existing squad:review-pending behaviour'

grep -q '"squad:needs-decision"' <<<"$(declare -f ensure_loop_labels)" || fail 'needs-decision label not provisioned'
ok 'squad:needs-decision is provisioned with the other labels'
