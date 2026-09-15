#!/usr/bin/env bash
# Synthetic GitHub API fixtures and a real local Git ref store; no network writes.
# shellcheck disable=SC2034,SC2317,SC2218
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GITHUB_OWNER=example GITHUB_REPO=repo REPO_BRANCH=main
export WORKSPACE_DIR="$TMP/repo" LOOP_STATE_DIR="$TMP/state"
export LOOP_REQUIRED_LABELS='["implementation-approved"]'
export LOOP_MANUAL_ISSUE_CREATORS='["fixture-human"]'
export LOOP_UNATTENDED_LABELS='["squad"]' LOOP_MAX_ACTIVE_ISSUES=1 LOOP_MAX_PRS_PER_DAY=1
# shellcheck source=/dev/null
source "$ROOT/worker/worker-loop.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "PASS: $*"; }
reject() { if "$@"; then fail "unexpected success: $*"; fi; }
command git init -q "$WORKSPACE_DIR"
cd "$WORKSPACE_DIR"
command git config user.name Fixture
command git config user.email fixture@example.invalid
command git commit --allow-empty -qm base
BASE=$(git rev-parse HEAD)
TREE=$(git rev-parse HEAD:)
command git update-ref refs/remotes/origin/main "$BASE"
STORE="$TMP/remote.git"
command git clone -q --bare --no-hardlinks "$WORKSPACE_DIR" "$STORE"
CLEAN_REPO_URL="$STORE"
init_loop_state
CALLS="$TMP/calls"
: >"$CALLS"
HUMAN='{"number":7,"state":"OPEN","title":"Bounded fixture","body":"Implement the explicit fixture only.","author":{"login":"fixture-human","is_bot":false},"labels":[{"name":"squad"},{"name":"implementation-approved"}]}'
for n in 7 8 9; do jq --argjson n "$n" '.number=$n' <<<"$HUMAN" >"$TMP/issue-$n"; done
printf '[]' >"$TMP/active"
printf '[]' >"$TMP/prs"
printf '[[]]' >"$TMP/history"
MODE=normal
# API boundary only: real claim object creation and compare-and-swap Git refs.
gh() {
  printf '%s\n' "$*" >>"$CALLS"
  if [[ "$1 $2" == 'issue view' ]]; then
    if [[ "$*" == *'--jq .state'* ]]; then jq -r .state "$TMP/issue-$3"; return; fi
    [[ "$*" == *author* ]] || fail 'fresh issue query omitted author metadata'
    if [[ "$MODE" == revoke-after-claim ]] && command git --git-dir="$STORE" show-ref --verify --quiet "refs/heads/squad-claims/issue-$3"; then
      jq '.author.is_bot=true' "$TMP/issue-$3"
    else cat "$TMP/issue-$3"; fi
    return
  fi
  if [[ "$1 $2" == 'issue list' ]]; then cat "$TMP/active"; return; fi
  if [[ "$1 $2" == 'pr list' ]]; then cat "$TMP/prs"; return; fi
  if [[ "$1 $2" == 'issue edit' ]]; then
    local n="$3" arg op='' data
    shift 3
    data=$(cat "$TMP/issue-$n")
    for arg in "$@"; do
      case "$op" in
        --add-label) data=$(jq --arg v "$arg" '.labels += [{name:$v}] | .labels |= unique_by(.name)' <<<"$data");;
        --remove-label) data=$(jq --arg v "$arg" '.labels |= map(select(.name != $v))' <<<"$data");;
      esac
      op="$arg"
    done
    printf '%s\n' "$data" >"$TMP/issue-$n"
    return
  fi
  if [[ "$1 $2" == 'issue comment' || "$1 $2" == 'pr ready' ]]; then return 0; fi
  if [[ "$1" == api ]]; then
    local path='' arg ref='' sha='' message=''
    for arg in "$@"; do
      case "$arg" in
        repos/*) path="$arg";; ref=*) ref="${arg#ref=}";; sha=*) sha="${arg#sha=}";; message=*) message="${arg#message=}";;
      esac
    done
    if [[ "$path" == *'/issues?'* ]]; then
      [[ "$*" == *--paginate* ]] || fail 'manual queue must paginate'
      jq -c '.[]' "$TMP/queue"; return
    fi
    if [[ "$path" == *'/pulls?'* ]]; then
      [[ "$*" == *--paginate* ]] || fail 'PR history must paginate'
      if [[ "$MODE" == history-failure ]]; then jq -c '.[]' "$TMP/history"; return 1; fi
      jq -c '.[]' "$TMP/history"; return
    fi
    if [[ "$path" == */git/commits && "$*" == *'--method POST'* ]]; then
      printf '%s' "$message" | command git --git-dir="$STORE" -c user.name=Fixture -c user.email=fixture@example.invalid commit-tree "$TREE" -p "$BASE"
      return
    fi
    if [[ "$path" == */git/refs && "$*" == *'--method POST'* ]]; then
      command git --git-dir="$STORE" update-ref "$ref" "$sha" 0000000000000000000000000000000000000000
      return
    fi
    if [[ "$path" == */git/ref/heads/main ]]; then echo "$BASE"; return; fi
    if [[ "$path" == *'/git/ref/'* ]]; then command git --git-dir="$STORE" rev-parse --verify "refs/${path#*/git/ref/}"; return; fi
    if [[ "$path" == *'/git/commits/'* ]]; then
      if [[ "$*" == *'.tree.sha'* ]]; then echo "$TREE"; else command git --git-dir="$STORE" show -s --format=%B "${path##*/}"; fi
      return
    fi
    if [[ "$path" == *'/git/matching-refs/'* ]]; then
      if [[ "$MODE" == malformed-refs ]]; then echo '{}'; return; fi
      local refs
      refs=$(command git --git-dir="$STORE" for-each-ref --format='%(refname) %(objectname)' | awk -v prefix="refs/${path#*/git/matching-refs/}" 'index($1,prefix)==1')
      if [[ "$*" == *'--jq length'* ]]; then
        printf '%s\n' "$refs" | awk 'NF {n++} END {print n+0}'
      else
        local result
        result=$(printf '%s\n' "$refs" | jq -Rsc 'split("\n") | map(select(length>0) | split(" ") | {ref:.[0],object:{sha:.[1]}})')
        echo "$result"
      fi
      return
    fi
  fi
  echo "Unexpected fixture API: $*" >&2
  return 99
}
release_owned_ref() {
  printf 'release %s %s\n' "$1" "$2" >>"$CALLS"
  command git --git-dir="$STORE" update-ref -d "$1" "$2"
}
reset_local() {
  CURRENT_ISSUE="" CURRENT_CLAIM_REF="" CURRENT_CLAIM_OID="" CURRENT_WIP_REF=""
  CURRENT_MANUAL_INTAKE=false WIP_CREATED=false
}
reset_issue() { jq --argjson n "$1" '.number=$n' <<<"$HUMAN" >"$TMP/issue-$1"; }

is_manual_issue "$HUMAN"
reject is_autonomous_issue "$HUMAN"
for mutation in '.author.login="stranger"' '.author.is_bot=true' 'del(.author)' 'del(.author.is_bot)' '.author.login=""' '.author.is_bot="false"' '.labels |= map(select(.name != "implementation-approved"))' '.labels += [{name:"loop:auto"}]' '.state="CLOSED"'; do
  reject is_manual_issue "$(jq "$mutation" <<<"$HUMAN")"
done
LOOP_MANUAL_ISSUE_CREATORS='[]'
reject is_manual_issue "$HUMAN"
is_autonomous_issue "$HUMAN"
LOOP_MANUAL_ISSUE_CREATORS='["fixture-human"]'
for invalid in 'null' '{}' '[null]' '["fixture-human","FIXTURE-HUMAN"]' '["fixture[bot]"]' '[""]' '["bad/name"]'; do
  (LOOP_MANUAL_ISSUE_CREATORS="$invalid"; reject validate_manual_intake_policy)
done
for invalid in '[]' '[""]' '[" "]' '["squad"]' '["squad:processing"]' '["loop:auto"]'; do
  (LOOP_REQUIRED_LABELS="$invalid"; reject validate_manual_intake_policy; reject is_manual_issue "$HUMAN")
done
ok 'manual identity/approval predicate is explicit; missing, untrusted and bot identities have no exemption'

# Priority includes a complete REST queue, not a truncated latest-100 window.
jq -n --argjson human "$HUMAN" '[[range(100) | {number:(1000+.),state:"open",title:"Scheduled fixture",body:"",user:{login:"scheduler",type:"Bot"},labels:[{name:"squad"},{name:"implementation-approved"}]}],
 [$human | .state="open" | .user={login:.author.login,type:"User"} | del(.author)]]' >"$TMP/queue"
selected=$(find_next_issue)
[[ "$(jq -r .number <<<"$selected")" == 7 ]] || fail 'manual did not outrank revision/auto queue'
if grep -q 'issue list' "$CALLS"; then fail 'manual priority queried lower-priority queue'; fi
jq '.[1][0].labels += [{name:"squad:revision"},{name:"squad:failed"}]' "$TMP/queue" >"$TMP/q2"; mv "$TMP/q2" "$TMP/queue"
[[ "$(find_next_issue | jq -r .number)" == 7 ]] || fail 'approved manual revision excluded'
# An existing claim without a processing label must not starve the next manual issue.
jq '.[1] += [.[1][0] | .number=8]' "$TMP/queue" >"$TMP/q2"; mv "$TMP/q2" "$TMP/queue"
command git --git-dir="$STORE" update-ref refs/heads/squad-claims/issue-7 "$BASE"
[[ "$(find_manual_issue | jq -r .number)" == 8 ]] || fail 'unmarked claim starved next manual issue'
[[ "$(command git --git-dir="$STORE" rev-parse refs/heads/squad-claims/issue-7)" == "$BASE" ]] || fail 'selector stole claim'
command git --git-dir="$STORE" update-ref -d refs/heads/squad-claims/issue-7
jq '.[1] |= .[0:1]' "$TMP/queue" >"$TMP/q2"; mv "$TMP/q2" "$TMP/queue"
# REST missing type and bot type cannot be inferred human from an allowlisted login.
for identity in 'null' '"Bot"'; do
  jq --argjson identity "$identity" '.[1][0].user.type=$identity' "$TMP/queue" >"$TMP/q2"
  mv "$TMP/q2" "$TMP/queue"
  [[ -z "$(find_manual_issue)" ]] || fail 'REST identity failed open'
done
ok 'manual queue above generated/revision work, complete beyond 100 entries, authoritative REST identity'

# Seed another issue's WIP, ready PR, and exhausted daily slot.
FOREIGN=$(printf '{"issue":"99","worker":"other"}' | command git --git-dir="$STORE" -c user.name=Fixture -c user.email=fixture@example.invalid commit-tree "$TREE" -p "$BASE")
command git --git-dir="$STORE" update-ref refs/heads/squad-claims/wip "$FOREIGN"
command git --git-dir="$STORE" update-ref "refs/$(budget_ref_prefix)/slot-1" "$BASE"
printf '[{"number":99,"labels":[{"name":"squad:review-pending"}]}]' >"$TMP/active"
printf '[{"headRefName":"squad/99-ready-fixture"}]' >"$TMP/prs"
: >"$CALLS"
reset_local
CURRENT_ISSUE=7
claim_issue 7
[[ "$CURRENT_MANUAL_INTAKE" == true && -z "$CURRENT_WIP_REF" ]] || fail 'manual claimed global WIP'
publication_authorized 7 squad squad:processing
if grep -Eq 'squad-claims/wip|squad-budget|issue list|pr list|pulls\?' "$CALLS"; then fail 'manual consulted global WIP/budget or history'; fi
reject create_issue_claim_ref 8
[[ "$CURRENT_CLAIM_REF" == refs/heads/squad-claims/issue-7 ]] || fail 'busy claim overwritten'
reject process_issue "$(cat "$TMP/issue-8")"
reject process_revision "$(cat "$TMP/issue-8")"
release_issue_claim
[[ "$(command git --git-dir="$STORE" rev-parse refs/heads/squad-claims/wip)" == "$FOREIGN" ]] || fail 'foreign WIP released'
reset_issue 7
ok 'manual starts with foreign WIP, ready PR and exhausted daily budget; busy worker and foreign ownership protected'

# Concurrent free workers may claim different manual issues; same issue remains atomic.
for pair in '7 8' '7 7'; do
  reset_issue 7; reset_issue 8
  read -r left right <<<"$pair"
  (reset_local; CURRENT_ISSUE="$left"; rc=0; create_issue_claim_ref "$left" || rc=$?; echo "$rc" >"$TMP/left") & a=$!
  (reset_local; CURRENT_ISSUE="$right"; rc=0; create_issue_claim_ref "$right" || rc=$?; echo "$rc" >"$TMP/right") & b=$!
  wait "$a" "$b"
  sum=$(( $(cat "$TMP/left") + $(cat "$TMP/right") ))
  if [[ "$left" != "$right" ]]; then [[ "$sum" == 0 ]] || fail 'distinct manual issues serialized globally'
  else [[ "$sum" == 1 ]] || fail 'same issue admitted multiple workers'; fi
  for n in 7 8; do command git --git-dir="$STORE" update-ref -d "refs/heads/squad-claims/issue-$n"; done
done
ok 'two manual issues use distinct claims; same-issue concurrent CAS has exactly one winner'

reset_local; CURRENT_ISSUE=7; MODE=revoke-after-claim
reject create_issue_claim_ref 7
reject command git --git-dir="$STORE" show-ref --verify --quiet refs/heads/squad-claims/issue-7
MODE=normal
ok 'fresh post-claim author revalidation revokes bypass and releases only the issue claim'

# Nonmanual scheduled work retains WIP checks even without loop:auto.
reset_local; CURRENT_ISSUE=9
jq '.author={login:"scheduler",is_bot:true}' <<<"$HUMAN" >"$TMP/issue-9"
# A closed issue avoids history lookup but the ready/active scan still blocks admission.
jq '.state="CLOSED"' <<<"$HUMAN" >"$TMP/issue-99"
reject create_issue_claim_ref 9
[[ "$CURRENT_MANUAL_INTAKE" == false ]] || fail 'scheduled bot classified manual'
printf '[]' >"$TMP/active"; printf '[]' >"$TMP/prs"
# With no WIP blocker, the already exhausted daily reservation still rejects.
reject create_issue_claim_ref 9
reject command git --git-dir="$STORE" show-ref --verify --quiet refs/heads/squad-claims/issue-9
reject command git --git-dir="$STORE" show-ref --verify --quiet refs/heads/squad-claims/wip
jq '.labels += [{name:"loop:auto"}]' "$TMP/issue-9" >"$TMP/i2"; mv "$TMP/i2" "$TMP/issue-9"
reject create_issue_claim_ref 9
ok 'scheduled bot without loop:auto and generated work retain autonomous WIP/daily limits'

# Complete history: a relevant open PR on the second page prevents release;
# a closed relevant PR beyond 100 unrelated historical PRs permits it.
reset_local
command git --git-dir="$STORE" update-ref refs/heads/squad-claims/wip "$FOREIGN"
jq '.state="OPEN"' <<<"$HUMAN" >"$TMP/issue-99"
jq -n '[[range(100) | {state:"closed",head:{ref:("unrelated/"+(.|tostring))}}],[{state:"open",head:{ref:"squad/99-fixture"}}]]' >"$TMP/history"
reconcile_closed_wip
[[ "$(command git --git-dir="$STORE" rev-parse refs/heads/squad-claims/wip)" == "$FOREIGN" ]] || fail 'late open PR missed'
MODE=history-failure
reject reconcile_closed_wip
MODE=malformed-refs
reject reconcile_closed_wip
MODE=normal
cp "$TMP/history" "$TMP/history-good"
printf '[[] , {"message":"denied"}]' >"$TMP/history"
reject reconcile_closed_wip
mv "$TMP/history-good" "$TMP/history"
jq '.[1][0].state="closed"' "$TMP/history" >"$TMP/h2"; mv "$TMP/h2" "$TMP/history"
command git --git-dir="$STORE" update-ref refs/heads/squad-claims/issue-99 "$BASE"
reject reconcile_closed_wip
command git --git-dir="$STORE" update-ref -d refs/heads/squad-claims/issue-99
# Neighboring issue prefix is not this issue's active claim.
command git --git-dir="$STORE" update-ref refs/heads/squad-claims/issue-990 "$BASE"
reconcile_closed_wip
reject command git --git-dir="$STORE" show-ref --verify --quiet refs/heads/squad-claims/wip
[[ "$(command git --git-dir="$STORE" rev-parse refs/heads/squad-claims/issue-990)" == "$BASE" ]] || fail 'neighbor claim deleted'
ok 'paginated >100 PR history, late open PR, partial/API failures, exact claim match and safe terminal release'

# Persist and resume real publication receipts; only API/check input is synthetic.
reset_local; reset_issue 7; CURRENT_ISSUE=7
claim_issue 7
TASK_BASE_SHA="$BASE" TASK_DEADLINE=$(( $(date +%s) + 600 ))
VERIFIED_HEAD="$BASE" REVIEWED_HEAD="$BASE" FINAL_PR_BODY='Fixture body'
REVIEW_BODY_HASH=$(printf '%s' "$FINAL_PR_BODY" | sha256sum | cut -d' ' -f1)
LOOP_REQUIRED_CHECKS='["fixture-check"]'
POLICY='{"policyHash":"fixture-policy"}'
resolve_check_policy() { echo "$POLICY"; }
REMOTE_HEAD="$BASE" REMOTE_DRAFT=true REMOTE_STATE=OPEN
read_pr_snapshot() {
  jq -n --arg head "$REMOTE_HEAD" --arg base "$BASE" --arg body "$FINAL_PR_BODY" --arg state "$REMOTE_STATE" --argjson draft "$REMOTE_DRAFT" --argjson policy "$POLICY" \
    '{state:$state,headRefOid:$head,baseRefOid:$base,body:$body,isDraft:$draft,mergeable:"MERGEABLE",checkPolicy:$policy,
      statusCheckRollup:[{name:"fixture-check",status:"COMPLETED",conclusion:"SUCCESS"}]}'
}
ensure_pr_is_draft() { printf 'ensure-draft\n' >>"$CALLS"; }
save_pending_publication 7 squad/7-fixture https://example.invalid/pr/7
jq -e '.manualIntake == true and .wip == ""' "$LOOP_STATE_DIR/pending.json" >/dev/null || fail 'manual receipt not persisted'
cp "$LOOP_STATE_DIR/pending.json" "$TMP/receipt"
reject create_issue_claim_ref 8
reset_local
CURRENT_MANUAL_INTAKE=false
: >"$CALLS"
resume_pending_publication
[[ "$CURRENT_MANUAL_INTAKE" == true ]] || fail 'manual receipt not restored on restart'
grep -q 'pr ready' "$CALLS" || fail 'manual receipt did not promote without global WIP'
REMOTE_DRAFT=false
jq '.promotedAt=0' "$LOOP_STATE_DIR/pending.json" >"$TMP/p2"; mv "$TMP/p2" "$LOOP_STATE_DIR/pending.json"
resume_pending_publication
[[ -f "$LOOP_STATE_DIR/ready-7.json" && ! -f "$LOOP_STATE_DIR/pending.json" ]] || fail 'manual ready not finalized'
if grep -q 'squad-claims/wip' "$CALLS"; then fail 'manual resume touched foreign WIP'; fi
ok 'manual receipt survives restart, promotes and finalizes through exact-head/claim gates without WIP'

for mode in creator-config approval author author-bot author-untrusted generated body head legacy; do
  reset_local; reset_issue 7; CURRENT_ISSUE=7
  claim_issue 7
  TASK_DEADLINE=$(( $(date +%s) + 600 ))
  save_pending_publication 7 squad/7-fixture https://example.invalid/pr/7
  reset_local
  case "$mode" in
    creator-config) LOOP_MANUAL_ISSUE_CREATORS='[]';;
    approval) jq '.labels |= map(select(.name != "implementation-approved"))' "$TMP/issue-7" >"$TMP/i2"; mv "$TMP/i2" "$TMP/issue-7";;
    author) jq 'del(.author)' "$TMP/issue-7" >"$TMP/i2"; mv "$TMP/i2" "$TMP/issue-7";;
    author-bot) jq '.author.is_bot=true' "$TMP/issue-7" >"$TMP/i2"; mv "$TMP/i2" "$TMP/issue-7";;
    author-untrusted) jq '.author.login="untrusted"' "$TMP/issue-7" >"$TMP/i2"; mv "$TMP/i2" "$TMP/issue-7";;
    generated) jq '.labels += [{name:"loop:auto"}]' "$TMP/issue-7" >"$TMP/i2"; mv "$TMP/i2" "$TMP/issue-7";;
    body) jq '.body="Changed scope"' "$TMP/issue-7" >"$TMP/i2"; mv "$TMP/i2" "$TMP/issue-7";;
    head) REMOTE_HEAD=changed;;
    legacy) jq 'del(.manualIntake)' "$LOOP_STATE_DIR/pending.json" >"$TMP/p2"; mv "$TMP/p2" "$LOOP_STATE_DIR/pending.json";;
  esac
  : >"$CALLS"
  resume_pending_publication
  [[ ! -f "$LOOP_STATE_DIR/pending.json" && -f "$LOOP_STATE_DIR/blocked-publication-7.json" ]] || fail "$mode receipt failed open"
  if grep -q 'pr ready' "$CALLS"; then fail "$mode promoted despite revocation/drift"; fi
  LOOP_MANUAL_ISSUE_CREATORS='["fixture-human"]' REMOTE_HEAD="$BASE"
done
ok 'restart publication rejects config/approval/author/contract/head drift; legacy receipt is nonmanual'

# Invalid receipts retain the local busy barrier; never infer bool from strings or
# allow a manual receipt to carry/release another issue's stale WIP pointer.
for mutation in '.manualIntake="true"' '.wip="refs/heads/squad-claims/wip"'; do
  reset_local; reset_issue 7; CURRENT_ISSUE=7
  claim_issue 7
  save_pending_publication 7 squad/7-fixture https://example.invalid/pr/7
  jq "$mutation" "$LOOP_STATE_DIR/pending.json" >"$TMP/p2"; mv "$TMP/p2" "$LOOP_STATE_DIR/pending.json"
  reset_local; : >"$CALLS"
  resume_pending_publication
  [[ -f "$LOOP_STATE_DIR/pending.json" && ! -s "$CALLS" ]] || fail 'invalid receipt mutated remote state'
  reject worker_available
  mv "$LOOP_STATE_DIR/pending.json" "$TMP/invalid-receipt"
  release_issue_claim
done
reset_local; reset_issue 7; CURRENT_ISSUE=7
claim_issue 7
save_pending_publication 7 squad/7-fixture https://example.invalid/pr/7
command git --git-dir="$STORE" update-ref refs/heads/squad-claims/wip "$FOREIGN"
REMOTE_STATE=CLOSED
reset_local; : >"$CALLS"
resume_pending_publication
[[ -f "$LOOP_STATE_DIR/closed-7.json" && ! -f "$LOOP_STATE_DIR/pending.json" ]] || fail 'closed manual receipt not archived'
[[ "$(command git --git-dir="$STORE" rev-parse refs/heads/squad-claims/wip)" == "$FOREIGN" ]] || fail 'closed manual receipt released foreign WIP'
if grep -q 'squad-claims/wip' "$CALLS"; then fail 'manual closed path consulted global WIP'; fi
REMOTE_STATE=OPEN
ok 'malformed/manual-with-WIP receipts stay busy; closed manual publication never releases foreign WIP'

# Main's actual dispatch order must not run WIP reconciliation before manual selection.
(
  reset_local
  SHUTDOWN_REQUESTED=false WORKER_ID=worker-1
  ensure_token() { return 0; }
  ensure_loop_labels() { return 0; }
  agent_startup_canary() { return 0; }
  resume_pending_publication() { return 1; }
  find_manual_issue() { echo "$HUMAN"; }
  find_revision_issue() { fail 'manual priority reached nonmanual revisions'; }
  reconcile_closed_wip() { fail 'main reconciled global WIP before manual dispatch'; }
  pr_budget_remaining() { fail 'main budgeted manual issue'; }
  process_issue() {
    [[ "$(jq -r .number <<<"$1")" == 7 && "$2" == false ]] || fail 'main dispatched wrong class'
    SHUTDOWN_REQUESTED=true
    touch "$TMP/main-dispatched"
  }
  sleep() { :; }
  main
  [[ -f "$TMP/main-dispatched" ]] || fail 'main did not dispatch manual issue'
)
ok 'main selects manual before revisions/generation/WIP and does not check its daily budget'

# Deployment generation only (never Docker), entrypoint export, and queue equivalence.
CONFIG="$TMP/repos.json"
ENV_FIXTURE="$TMP/env"
printf '# no credentials
' >"$ENV_FIXTURE"
jq -n '{"worker-1":{owner:"example",repo:"repo",loop:{manualIssueCreators:["fixture-human"],requiredLabels:["implementation-approved"]}}}' >"$CONFIG"
generate_fixture() {
  REPOS_JSON="$CONFIG" ENV_FILE="$ENV_FIXTURE" COMPOSE_FILE="$TMP/compose.yml" bash "$ROOT/deploy.sh" generate
}
generate_fixture
assignment=$(grep 'LOOP_MANUAL_ISSUE_CREATORS=' "$TMP/compose.yml" | sed 's/^ *- //' | jq -r .)
[[ "$assignment" == 'LOOP_MANUAL_ISSUE_CREATORS=["fixture-human"]' ]] || fail 'Compose lost creator configuration'
# Execute only the actual publisher-owned export helper and its new export line.
eval "$(sed -n '/^write_workspace_export() {/,/^}/p' "$ROOT/worker/entrypoint.sh")"
export_line=$(grep '^  write_workspace_export LOOP_MANUAL_ISSUE_CREATORS ' "$ROOT/worker/entrypoint.sh")
[[ -n "$export_line" ]] || fail 'entrypoint omitted creator option'
export "${assignment?}"
eval "$export_line" >"$TMP/workspace-env"
LOOP_MANUAL_ISSUE_CREATORS='[]'
# shellcheck source=/dev/null
source "$TMP/workspace-env"
[[ "$LOOP_MANUAL_ISSUE_CREATORS" == '["fixture-human"]' ]] || fail 'entrypoint changed JSON'
validate_manual_intake_policy
for invalid in 'null' 'false' '{}' '["fixture-human","FIXTURE-HUMAN"]' '["fixture[bot]"]' '[""]'; do
  jq --argjson bad "$invalid" '."worker-1".loop.manualIssueCreators=$bad' "$CONFIG" >"$TMP/config2"
  mv "$TMP/config2" "$CONFIG"
  reject generate_fixture
  (LOOP_MANUAL_ISSUE_CREATORS="$invalid"; reject validate_manual_intake_policy)
done
for invalid in '[]' '[""]' '[" "]' '["squad"]' '["squad:done"]' '["loop:auto"]'; do
  jq --argjson bad "$invalid" '."worker-1".loop.manualIssueCreators=["fixture-human"] | ."worker-1".loop.requiredLabels=$bad' "$CONFIG" >"$TMP/config2"
  mv "$TMP/config2" "$CONFIG"
  reject generate_fixture
  (LOOP_REQUIRED_LABELS="$invalid"; reject validate_manual_intake_policy)
done
jq -n '{"worker-1":{owner:"example",repo:"repo",loop:{manualIssueCreators:[]}},"worker-2":{owner:"example",repo:"repo",loop:{}}}' >"$CONFIG"
REPOS_JSON="$CONFIG" bash "$ROOT/tests/config-equivalence.sh"
generate_fixture
jq '."worker-2".loop.manualIssueCreators=["fixture-human"]' "$CONFIG" >"$TMP/config2"; mv "$TMP/config2" "$CONFIG"
reject env REPOS_JSON="$CONFIG" bash "$ROOT/tests/config-equivalence.sh"
jq '."worker-1".loop.manualIssueCreators=["FIXTURE-HUMAN"]' "$CONFIG" >"$TMP/config2"; mv "$TMP/config2" "$CONFIG"
REPOS_JSON="$CONFIG" bash "$ROOT/tests/config-equivalence.sh"
ok 'deploy/entrypoint JSON round trip, invalid opt-in fails both validators, shared-queue equivalence with legacy defaults'

echo 'Manual intake regressions: PASS'
