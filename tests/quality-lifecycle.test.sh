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
# #409: coding-user directories created with umask 0022 blocked publisher fetches.
mkdir -p .git/objects/zz "$WORKSPACE_DIR/build-output/nested"
chmod 2755 .git/objects/zz "$WORKSPACE_DIR/build-output/nested"; chmod 0700 "$WORKSPACE_DIR/build-output"
printf 'x\n' > .git/objects/zz/keep; chmod 0444 .git/objects/zz/keep
printf 'build-output/\n' >> .git/info/exclude
begin_task
prepare_task_base feature
for d in .git/objects/zz build-output build-output/nested; do
  [[ "$(( 0$(stat -c %a "$d") & 070 ))" == 56 ]] || fail "group access not restored on $d"
done
[[ "$(stat -c %a .git/objects/zz)" == 2775 && "$(stat -c %a build-output)" == 770 ]] || fail 'other/setgid bits changed'
[[ "$(stat -c %a .git/objects/zz/keep)" == 444 ]] || fail 'file modes changed'
rm -rf .git/objects/zz build-output; sed -i '/^build-output\/$/d' .git/info/exclude
# #410: a publisher-owned 2755 dir (operator docker exec, umask 0022) cannot be
# changed by the coding user; the publisher repairs its own directories.
mkdir -p .git/objects/yy; chmod 2755 .git/objects/yy
REPAIR_CALLS="$TMP/repair-calls"
# Evidence checks keep the fixture user switch; only the coding-user repair
# pass fails (it cannot chmod a publisher-owned directory in production).
eval "fixture_$(declare -f sudo)"
sudo() { echo "$*" >>"$REPAIR_CALLS"; [[ "$*" != *" /usr/bin/find "* ]] || return 7; fixture_sudo "$@"; }
begin_task
prepare_task_base feature
[[ "$(stat -c %a .git/objects/yy)" == 2775 ]] || fail 'publisher-owned dir not repaired by publisher'
grep -q -- "-n -u $AGENT_USER /usr/bin/env -i HOME=$AGENT_HOME" "$REPAIR_CALLS" || fail 'repair not run as coding user'
rm -rf .git/objects/yy
# A directory neither owner may change blocks before the fetch.
mkdir -p .git/objects/xx; chmod 2755 .git/objects/xx
id() { echo 99999; }
before=$(git rev-parse HEAD)
reject prepare_task_base feature
unset -f id
[[ "$(git rev-parse HEAD)" == "$before" && "$(stat -c %a .git/objects/xx)" == 2755 ]] || fail 'residual foreign dir changed head/mode'
rm -rf .git/objects/xx
unset -f sudo fixture_sudo
source "$ROOT/tests/fixtures/evidence-user-switch.sh"
ok 'base preparation restores group access per owner (coding user, publisher); residual dirs block before fetch'
# Two archives of the same branch within one second get distinct names.
git checkout -q --detach "$BASE"
git branch -f same-second "$BASE"
date() { if [[ "$*" == *'%Y%m%dT%H%M%SZ'* ]]; then echo 20260101T000000Z; else command date "$@"; fi; }
archive_unpublished_task_branch same-second || fail 'first archive failed'
git branch -f same-second "$BASE"
archive_unpublished_task_branch same-second || fail 'same-second archive collided'
unset -f date
for ref in same-second-20260101T000000Z same-second-20260101T000000Z-2; do
  git show-ref --verify --quiet "refs/heads/squad-archive/${ref}" || fail "archive ref ${ref} missing"
done
git checkout -q feature
ok 'same-second branch archives never collide or overwrite'
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
# A retained blocked attempt branch must not block the next fresh attempt forever.
git checkout -q --detach "$BASE"
git checkout -qb retained-attempt
printf 'unpublished\n' > retained.txt
git add retained.txt && git commit -qm 'retained unpublished work'
RETAINED=$(git rev-parse HEAD)
git checkout -q --detach "$BASE"
begin_task
prepare_task_base retained-attempt || fail 'retained local branch blocked fresh attempt'
[[ "$(git rev-parse HEAD)" == "$TASK_BASE_SHA" && "$(git branch --show-current)" == retained-attempt ]] || fail 'fresh branch not at base'
archived=$(git for-each-ref --format='%(refname:short) %(objectname)' 'refs/heads/squad-archive/retained-attempt-*')
[[ "$archived" == *" $RETAINED" ]] || fail 'retained commits not archived'
git checkout -q feature; git branch -q -D retained-attempt
ok 'retained unpublished branch is archived, never deleted, before fresh attempt'
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
fresh_base_compatible || fail "clean master advance blocked: $BASE_DRIFT_REASON"
[[ "$TASK_BASE_SHA" == "$BASE" && "$(git rev-parse HEAD)" == "$HEAD_SHA" && -f app.txt ]] || fail 'base drift moved pin or work'
SHIPPED=$(git rev-parse main)
ok 'clean master advance keeps the pinned base and publishes nothing different'
# A real conflict with the newer master blocks with the conflicting paths.
git checkout -q -B conflicting-main "$SHIPPED"
printf 'master rewrote this line\n' > app.txt
git commit -qam 'conflicting master change' && git push -q origin HEAD:main
git checkout -q feature
reject fresh_base_compatible
[[ "$BASE_DRIFT_REASON" == *'conflicts with HEAD in: app.txt'* ]] || fail "conflict reason: $BASE_DRIFT_REASON"
[[ "$TASK_BASE_SHA" == "$BASE" && "$(git rev-parse HEAD)" == "$HEAD_SHA" ]] || fail 'conflict check changed work'
# Rewritten history (pinned base no longer contained) blocks as well.
git checkout -q --orphan rewritten && git commit -qm rewritten
git push -q -f origin HEAD:main
git checkout -q -f feature
reject fresh_base_compatible
[[ "$BASE_DRIFT_REASON" == *'no longer contains the pinned base'* ]] || fail "rewrite reason: $BASE_DRIFT_REASON"
git push -q -f origin "$SHIPPED:main"
git branch -q -D conflicting-main rewritten
[[ -f app.txt ]] || fail 'base drift damaged work'
ok 'only a real conflict or rewritten master blocks, with the conflicting file list'
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
# Screenshots must not flood the critic with base85 patch lines.
python3 -c 'import os,sys; sys.stdout.buffer.write(b"\x89PNG\r\n\x1a\n"+os.urandom(60000))' > shot.png
git add shot.png && git commit -qm 'binary evidence'
PNG_BLOB=$(git rev-parse HEAD:shot.png)
run_agent_copilot() {
  local input
  input=$(find "$WORKSPACE_DIR" -maxdepth 1 -name '.critic-input.*.md')
  grep -q 'GIT binary patch' "$input" && fail 'binary payload sent to critic'
  grep -q "Binary files .*shot.png differ" "$input" || fail 'binary change not listed'
  grep -q "index 0\{40\}\.\.${PNG_BLOB}" "$input" || fail 'binary blob not bound by full ID'
  (( $(wc -l < "$input") < 2500 )) || fail 'binary inflated critic input'
  bash "$ROOT/tests/critic-complete-input.test.sh" --emit "$input"
}
run_critic || fail 'binary-only addition blocked review'
ok 'binary files reviewed by full blob ID, not base85 payload'
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
PR_BASE="$BASE" PR_MERGEABLE=MERGEABLE COMPARE_STATUS=ahead COMMENTS_MODE=""
CI_COMMENTS="$TMP/ci-comments.json"
echo '[]' >"$CI_COMMENTS"
gh() {
  printf '%s\n' "$*" >>"$GH_CALLS"
  if [[ "$1 $2" == 'issue view' ]]; then echo "$ISSUE"; return 0; fi
  if [[ "$1 $2" == 'issue comment' ]]; then
    [[ "$COMMENTS_MODE" != fail ]] || return 1
    jq --arg body "${@: -1}" '. + [{body:$body}]' "$CI_COMMENTS" >"$CI_COMMENTS.tmp" && mv "$CI_COMMENTS.tmp" "$CI_COMMENTS"; return 0
  fi
  if [[ "$1" == api ]]; then
    if [[ "$2" == --paginate && "$3" == */issues/1/comments* ]]; then
      [[ "$COMMENTS_MODE" != fail ]] || return 1
      cat "$CI_COMMENTS"
    elif [[ "$2" == */compare/* ]]; then
      [[ "$2" == */compare/"${BASE}...${PR_BASE}" ]] || return 1
      echo "$COMPARE_STATUS"
    elif [[ "$2" == */pulls/1 ]]; then
      gh pr view fixture --json fixture | jq '{state:"open",draft:.isDraft,merged:false,
        head:{sha:.headRefOid},base:{sha:.baseRefOid},body,mergeable:(if .mergeable=="MERGEABLE" then true elif .mergeable=="CONFLICTING" then false else null end)}'
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
    jq --arg head "$head" --arg base "$PR_BASE" --arg body "$body" --argjson draft "$REMOTE_DRAFT" --arg mergeable "$PR_MERGEABLE" \
      '. + {state:"OPEN",headRefOid:$head,baseRefOid:$base,body:$body,isDraft:$draft,mergeable:$mergeable}' <<<"$checks"
    return 0
  fi
}
save_pending_publication 1 feature https://example.invalid/pr/1
resume_pending_publication
[[ -f "$LOOP_STATE_DIR/pending.json" ]] || fail 'pending receipt lost'
if grep -q 'pr ready' "$GH_CALLS"; then fail 'pending checks marked ready'; fi
PR_MODE=success
# Other PRs merged meanwhile: GitHub reports a newer PR base that still contains
# the pinned base. Evidence stays valid (was a hard block before).
PR_BASE=$(git rev-parse origin/main)
[[ "$PR_BASE" != "$BASE" ]] || fail 'fixture base did not move'
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
ok 'PR base moved by other merges keeps evidence while it contains the pinned base'
# PR base that no longer contains the pinned base (or unverifiable) still blocks.
fresh_receipt() {
  CURRENT_CLAIM_REF=refs/heads/squad-claims/issue-1 CURRENT_CLAIM_OID=owned
  TASK_DEADLINE=$(( $(date +%s) + 600 )) REMOTE_DRAFT=true
  rm -f "$LOOP_STATE_DIR"/blocked-publication-1.json "$LOOP_STATE_DIR"/ci-revision-1.json
  : > "$GH_CALLS"
  save_pending_publication 1 feature https://example.invalid/pr/1
}
for COMPARE_STATUS in diverged behind; do
  fresh_receipt; PR_MODE=success
  resume_pending_publication
  [[ -f "$LOOP_STATE_DIR/blocked-publication-1.json" ]] || fail "$COMPARE_STATUS PR base accepted"
  grep -q 'no longer contains the pinned base' "$LOOP_STATE_DIR/blocked-1.json" || fail 'base block reason'
  if grep -q 'pr ready' "$GH_CALLS"; then fail 'unrelated base promoted'; fi
done
COMPARE_STATUS=ahead
ok 'PR base without the pinned base blocks; head/body remain exact'
# A red required check requeues a bounded CI revision; the draft stays, the
# claim is released only after the durable retry trigger, no Ready, no model run.
LOOP_MAX_CI_ROUNDS=2
for round in 1 2; do
  fresh_receipt; PR_MODE=failed
  resume_pending_publication
  [[ ! -f "$LOOP_STATE_DIR/pending.json" && -f "$LOOP_STATE_DIR/ci-revision-1.json" ]] || fail "CI round $round not requeued"
  [[ "$(jq -r .ciRounds "$LOOP_STATE_DIR/ci-revision-1.json")" == "$round" ]] || fail 'receipt round count'
  grep -q -- '--add-label squad:revision' "$GH_CALLS" || fail 'revision trigger missing'
  if grep -qE '^pr ready|--add-label squad:(done|failed)' "$GH_CALLS"; then fail 'CI failure promoted or terminal'; fi
  [[ -z "$CURRENT_CLAIM_REF" && -z "$CURRENT_ISSUE" ]] || fail 'claim not released after requeue'
  # Next round is a new head (the revision pushes new commits).
  git commit -q --allow-empty -m "ci fix $round"
  VERIFIED_HEAD=$(git rev-parse HEAD) REVIEWED_HEAD=$(git rev-parse HEAD)
done
[[ "$(ci_rounds_used 1 https://example.invalid/pr/1)" == 2 ]] || fail 'round markers not counted per head'
fresh_receipt; PR_MODE=failed
resume_pending_publication
[[ -f "$LOOP_STATE_DIR/blocked-publication-1.json" && ! -f "$LOOP_STATE_DIR/ci-revision-1.json" ]] || fail 'exhausted budget requeued'
grep -q 'budget exhausted (2/2)' "$LOOP_STATE_DIR/blocked-1.json" || fail 'exhausted reason'
if grep -qE '^pr ready [^-]*$|--add-label squad:revision' "$GH_CALLS"; then fail 'exhausted CI round retried'; fi
ok 'red required check requeues at most LOOP_MAX_CI_ROUNDS revisions, then blocks'
# Unreadable round history, disabled budget and a PR conflict with master.
echo '[]' >"$CI_COMMENTS"
COMMENTS_MODE=fail; fresh_receipt; PR_MODE=failed
resume_pending_publication
grep -q 'CI round history unavailable' "$LOOP_STATE_DIR/blocked-1.json" || fail 'history failure did not block closed'
COMMENTS_MODE=""
LOOP_MAX_CI_ROUNDS=0; fresh_receipt
resume_pending_publication
grep -q 'automatic CI revisions disabled' "$LOOP_STATE_DIR/blocked-1.json" || fail 'disabled budget requeued'
LOOP_MAX_CI_ROUNDS=2
fresh_receipt; PR_MODE=success PR_MERGEABLE=CONFLICTING
resume_pending_publication
[[ -f "$LOOP_STATE_DIR/ci-revision-1.json" ]] || fail 'conflict waited instead of requeue'
[[ "$(jq -r .ciCause "$LOOP_STATE_DIR/ci-revision-1.json")" == 'PR conflicts with main' ]] || fail 'conflict cause'
PR_MERGEABLE=MERGEABLE
fresh_receipt; save_pending_publication 1 feature https://example.invalid/pr/1
jq '.ciRounds=2' "$LOOP_STATE_DIR/pending.json" >"$TMP/p2"; mv "$TMP/p2" "$LOOP_STATE_DIR/pending.json"
echo '[]' >"$CI_COMMENTS"; PR_MODE=failed
resume_pending_publication
grep -q 'budget exhausted (2/2)' "$LOOP_STATE_DIR/blocked-1.json" || fail 'receipt counter ignored when markers missing'
ok 'CI rounds fail closed on unreadable history, honor receipt counter; conflicts requeue instead of waiting forever'
# Checks start only after publication: the receipt keeps at least the check wait.
fresh_receipt; TASK_DEADLINE=$(( $(date +%s) + 5 ))
save_pending_publication 1 feature https://example.invalid/pr/1
(( $(jq -r .deadline "$LOOP_STATE_DIR/pending.json") >= $(date +%s) + LOOP_CHECK_WAIT_SECONDS - 5 )) || fail 'no bounded check wait'
rm -f "$LOOP_STATE_DIR/pending.json"
ok 'pending checks get a bounded wait even after a long implementation'
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
    # Concurrency-cancelled newer run beside a successful run of the same workflow/head.
    [[ "$ACTIONS_MODE" != superseded ]] || data=$(jq '.workflow_runs += [{"id":5,"workflow_id":2,"run_number":2,"run_attempt":1,"name":"Governance","head_sha":"head-a","head_branch":"feature","event":"pull_request","status":"completed","conclusion":"cancelled"}] | .total_count=(.workflow_runs|length)' <<<"$data")
    [[ "$ACTIONS_MODE" != allcancelled ]] || data=$(jq '.workflow_runs |= map(if .id == 3 then .conclusion="cancelled" else . end)' <<<"$data")
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
ACTIONS_MODE=superseded
: >"$JOBS_REQUESTED"
snapshot=$(read_pr_snapshot feature)
remote_checks_ready "$snapshot" || fail 'concurrency-cancelled duplicate run blocked a green head'
if grep -q '/runs/5/' "$JOBS_REQUESTED"; then fail 'superseded cancelled run was evaluated'; fi
ACTIONS_MODE=allcancelled
snapshot=$(read_pr_snapshot feature)
reject remote_checks_ready "$snapshot"
jq -e 'any(.statusCheckRollup[]; .name=="workflow:Governance" and .conclusion=="CANCELLED")' <<<"$snapshot" >/dev/null || fail 'sole cancelled run hidden'
ok 'cancelled run superseded only by another run of the same workflow and head'
ACTIONS_MODE=missing
snapshot=$(read_pr_snapshot feature)
reject remote_checks_ready "$snapshot"
ACTIONS_MODE=denied
reject read_pr_snapshot feature
ok 'Actions backend handles inaccessible check rollup without skipping workflows/jobs'

# A policy refusal stays terminal and is reported as policy, not infrastructure.
(
  run_verify_gate() { VERIFY_LOG_TAIL='fixture authorization revoked'; return 5; }
  take_correction() { fail 'policy refusal entered a code correction'; }
  reject run_verify_with_corrections
  [[ "$GATE_NOTE" == 'Operator policy blocked verification; no code correction attempted. fixture authorization revoked' ]] || fail 'policy diagnostic lost'
)
ok 'operator policy failure stays terminal with precise diagnosis'

# Stale revision branches: another PR merged into the default branch after the
# revision branch was published. Integrate instead of blocking; conflicts are
# bounded, announced to the implementer and enforced after its session.
(
  R2="$TMP/rev-remote" W2="$TMP/rev-work"
  command git init --bare -q "$R2"
  command git init -q "$W2"
  cd "$W2"
  WORKSPACE_DIR="$W2" CLEAN_REPO_URL="$R2"
  mkdir -p .squad
  printf 'active policy\n' > .squad/GOVERNANCE.md
  printf 'v1\n' > notes.txt
  git add . && git commit -qm base && git branch -M main
  git remote add origin "$R2"
  git push -q origin main
  git checkout -qb rev
  printf 'feature\n' > feature.txt
  git add feature.txt && git commit -qm feature
  git push -q origin rev
  REV1=$(git rev-parse HEAD)
  git checkout -q main
  printf 'other\n' > other.txt
  git add other.txt && git commit -qm 'other PR merged'
  git push -q origin main
  MAIN2=$(git rev-parse HEAD)
  git checkout -q --detach "$MAIN2"
  git branch -q -D rev

  begin_task
  prepare_task_base rev true || fail 'clean stale revision blocked'
  [[ "$REVISION_BASE_MODE" == merged ]] || fail "expected merged, got $REVISION_BASE_MODE"
  [[ "$TASK_BASE_SHA" == "$MAIN2" && "$TASK_START_HEAD" == "$REV1" ]] || fail 'base/start pinning'
  [[ "$(git rev-parse HEAD^1)" == "$REV1" && "$(git rev-parse HEAD^2)" == "$MAIN2" ]] || fail 'merge parents'
  [[ -f other.txt && -f feature.txt && "$(git branch --show-current)" == rev ]] || fail 'merged tree/branch'
  task_integrity || fail 'integrity after clean integration'
  finish_revision_base_integration || fail 'clean integration needs no resolution'
  revision_base_prompt | grep -q 'already done by the worker' || fail 'merged prompt'
  ok 'stale revision without conflicts gets a worker merge of the fresh base'

  # Conflicting metadata (e.g. two PRs claiming the same release entry).
  git checkout -q -B rev2 "$MAIN2"
  printf 'v1\nrev2 entry\n' > notes.txt
  git commit -qam rev2
  git push -q origin rev2
  REV2=$(git rev-parse HEAD)
  git checkout -q main
  printf 'v1\nmain entry\n' > notes.txt
  git commit -qam 'main entry'
  git push -q origin main
  MAIN3=$(git rev-parse HEAD)
  git checkout -q --detach "$MAIN3"
  git branch -q -D rev2
  (LOOP_MAX_BASE_CONFLICTS=0; reject integrate_revision_base rev2 "$MAIN3" "$REV2")
  begin_task
  prepare_task_base rev2 true || fail 'conflicting stale revision blocked before implementer'
  [[ "$REVISION_BASE_MODE" == conflict && "$REVISION_BASE_CONFLICTS" == notes.txt ]] || fail 'conflict classification'
  [[ "$(git rev-parse HEAD)" == "$REV2" && "$TASK_START_HEAD" == "$REV2" ]] || fail 'conflict start head'
  task_integrity || fail 'announced pending conflict rejected before implementer'
  reject finish_revision_base_integration
  prompt=$(revision_base_prompt)
  [[ "$prompt" == *"git merge --no-ff $MAIN3"* && "$prompt" == *"- notes.txt"* ]] || fail 'conflict prompt'
  # Implementer commits conflict markers: never accepted as a resolution.
  git merge --no-ff "$MAIN3" >/dev/null 2>&1 || true
  git add notes.txt && git commit -q --no-edit
  reject finish_revision_base_integration
  # Proper resolution keeps both entries.
  printf 'v1\nmain entry\nrev2 entry\n' > notes.txt
  git commit -qam 'resolve release notes'
  finish_revision_base_integration || fail 'resolved integration rejected'
  [[ "$REVISION_BASE_MODE" == resolved ]] || fail 'resolution not recorded'
  task_integrity || fail 'integrity after resolution'
  ok 'conflicting stale revision is handed to the implementer and enforced afterwards'

  # A local revision branch left behind by an earlier attempt: fast-forward when
  # published, archive (never delete) when it carries unpublished commits.
  git checkout -q -B rev3 "$MAIN3"
  printf 'three\n' > three.txt
  git add three.txt && git commit -qm three
  OLD3=$(git rev-parse HEAD)
  printf 'three more\n' >> three.txt
  git commit -qam 'three more'
  git push -q origin rev3
  PUB3=$(git rev-parse HEAD)
  git checkout -q --detach "$MAIN3"
  git branch -q -f rev3 "$OLD3"
  begin_task
  prepare_task_base rev3 true || fail 'published-behind local branch blocked'
  [[ "$REVISION_BASE_MODE" == contained && "$(git rev-parse HEAD)" == "$PUB3" ]] || fail 'fast-forward'
  git checkout -q --detach "$MAIN3"
  git branch -q -f rev3 "$MAIN3"
  git checkout -q rev3
  printf 'unpublished\n' > local.txt
  git add local.txt && git commit -qm unpublished
  LOCAL3=$(git rev-parse HEAD)
  git checkout -q --detach "$MAIN3"
  begin_task
  prepare_task_base rev3 true || fail 'diverged local branch blocked'
  [[ "$(git rev-parse HEAD)" == "$PUB3" ]] || fail 'published head not checked out'
  archived=$(git for-each-ref --format='%(objectname)' 'refs/heads/squad-archive/rev3-*')
  [[ "$archived" == "$LOCAL3" ]] || fail 'unpublished local work not archived'
  ok 'stale local revision branches are fast-forwarded or archived, never deleted'
)


# End-to-end offline dry run through the REAL process_issue/process_revision:
# local Git remote, real gates/critic parser/publisher; fakes only at the GitHub
# API, model and credential boundaries. The fake model pushes a master commit in
# the middle of its session (and the critic during review).
(
  R="$TMP/e2e-remote" P="$TMP/e2e-pusher" CALLS="$TMP/e2e-calls" OUT="$TMP/e2e-out"
  WORKSPACE_DIR="$TMP/e2e-work" CLEAN_REPO_URL="$R"
  begin_task; TASK_DEADLINE=0 LOOP_STATE_DIR="$TMP/e2e-state" LOOP_REQUIRED_LABELS='[]' LOOP_MAX_ACTIVE_ISSUES=0
  LOOP_CHECK_BACKEND=checks LOOP_REQUIRED_CHECKS='["CI"]' LOOP_REQUIRED_WORKFLOWS='[]'
  LOOP_CONDITIONAL_WORKFLOWS='[]' LOOP_IGNORED_WORKFLOWS='[]' LOOP_PROFILE_DIR=""
  LOOP_VERIFY=true LOOP_CRITIC=true LOOP_CRITIC_RUBRIC=auto LOOP_COPILOT_SECRET_FILTER_MODULE=off
  CRITIC_INPUT_NONCE_OVERRIDE=fixture-nonce COPILOT_PAT=fixture-model-credential
  command git init -q --bare "$R"
  command git init -q -b main "$TMP/e2e-seed"
  (cd "$TMP/e2e-seed" && mkdir .squad && printf 'active policy\n' >.squad/GOVERNANCE.md &&
    printf 'shared v1\n' >shared.txt && command git add . && command git commit -qm base && command git push -q "$R" main)
  command git --git-dir="$R" symbolic-ref HEAD refs/heads/main
  command git clone -q --no-hardlinks "$R" "$WORKSPACE_DIR"
  command git clone -q "$R" "$P"
  cd "$WORKSPACE_DIR"
  init_loop_state
  # Real sanitizer (an earlier fixture replaced it); the remote is the local bare repo.
  eval "$(sed -n '/^sanitize_repository_git_config() {/,/^}/p' "$ROOT/worker/worker-loop.sh")"
  sanitize_repository_git_config
  push_master() { (cd "$P" && command git pull -q --ff-only origin main && printf '%s\n' "$2" >"$1" &&
    command git add "$1" && command git commit -qm "master: $1" && command git push -q origin HEAD:main); }
  # Boundaries: credentials, user switch for scratch files, launcher, GitHub API, model.
  ensure_token() { return 0; }
  read_repo_file() { local r; r=$(resolve_repo_file_path "$1") || return 1; sed -n "1,${2:-1200}p" "$r"; }
  remove_repo_file_as_agent() { rm -f -- "$WORKSPACE_DIR/$1"; }
  run_agent_command() { echo HANGAR_AGENT_STARTED; /usr/bin/bash --noprofile --norc -c "$1"; }
  claim_issue() { CURRENT_CLAIM_REF="refs/heads/squad-claims/issue-$1" CURRENT_CLAIM_OID=e2e-owner CURRENT_MANUAL_INTAKE=false
    ISSUE_CONTRACT_HASH=$(issue_contract_hash "$E2E_ISSUE"); }
  release_owned_ref() { return 0; }
  gh() {
    printf '%s\n' "$*" >>"$CALLS"
    case "$1 $2" in
      'issue view') if [[ "$*" == *'--json comments'* ]]; then echo '[owner] Also add revision.txt.'; else echo "$E2E_ISSUE"; fi ;;
      'issue comment'|'issue edit'|'pr edit') return 0 ;;
      'pr list') if [[ -f "$TMP/e2e-pr" ]]; then jq -n --arg b "$E2E_BRANCH" '[{url:"https://example.invalid/pr/5",headRefName:$b,baseRefName:"main"}]'; else echo '[]'; fi ;;
      'pr create') touch "$TMP/e2e-pr"; echo https://example.invalid/pr/5 ;;
      'pr view') echo true ;;
      'run list') return 1 ;;
      api*) if [[ "$*" == *'/comments'* ]]; then echo '[]'; else echo "$CURRENT_CLAIM_OID"; fi ;;
      *) echo "unexpected gh $*" >&2; return 1 ;;
    esac
  }
  run_agent_copilot() {
    local arg prev="" prompt=""
    for arg in "$@"; do [[ "$prev" != -p ]] || prompt="$arg"; prev="$arg"; done
    if [[ " $* " == *' --output-format json '* ]]; then
      [[ -z "${E2E_REVIEW_PUSH:-}" ]] || push_master "$E2E_REVIEW_PUSH" 'moved during review'
      bash "$ROOT/tests/critic-complete-input.test.sh" --emit "$(find "$WORKSPACE_DIR" -maxdepth 1 -name '.critic-input.*.md')"
      return
    fi
    echo "$prompt" >"$TMP/e2e-prompt"
    printf '%s\n' "$E2E_CHANGE" >"$E2E_FILE"
    command git add "$E2E_FILE" && command git commit -qm "work on $E2E_FILE"
    push_master "$E2E_MASTER_FILE" "$E2E_MASTER_TEXT"
    mkdir -p .squad
    printf '## Problem\nMissing file.\n## Root Cause\nNever added.\n## Solution\nAdd it.\n## Testing\nCI-verified (CI).\n### UI evidence\nUI: N/A — no UI.\n## Future Work\nNone.\n' >.squad/pr-summary.md
  }
  e2e_issue() { E2E_ISSUE=$(jq -n --argjson n "$1" --arg t "$2" '{number:$n,state:"OPEN",title:$t,body:"Add the requested file.",labels:[{name:"squad"},{name:"squad:processing"}]}')
    E2E_BRANCH="squad/$1-$(slugify "$2")"; rm -f "$TMP/e2e-pr" "$LOOP_STATE_DIR/pending.json"; : >"$CALLS"
    CURRENT_ISSUE="" CURRENT_CLAIM_REF=""; }

  # 1) master moves (clean) during implementation and again during review.
  e2e_issue 5 'Add feature file'
  PINNED=$(command git -C "$P" rev-parse HEAD)
  E2E_FILE=feature.txt E2E_CHANGE=feature E2E_MASTER_FILE=other.txt E2E_MASTER_TEXT='other PR' E2E_REVIEW_PUSH=review.txt
  process_issue "$E2E_ISSUE" false >"$OUT" 2>&1 || { cat "$OUT"; fail 'clean master drift blocked publication'; }
  HEAD5=$(git rev-parse HEAD)
  [[ "$(command git --git-dir="$R" rev-parse "refs/heads/$E2E_BRANCH")" == "$HEAD5" ]] || fail 'published head differs'
  jq -e --arg b "$PINNED" --arg h "$HEAD5" '.base==$b and .head==$h and .verified==$h and .reviewed==$h' \
    "$LOOP_STATE_DIR/pending.json" >/dev/null || fail 'receipt not bound to pinned base and exact head'
  [[ "$(grep -c 'HEAD merges cleanly, pinned base kept' "$OUT")" -ge 2 ]] || fail 'master move not logged'
  grep -q -- '--draft' "$CALLS" || fail 'not draft-first'
  if grep -q -- '--add-label squad:failed' "$CALLS"; then fail 'clean drift marked failed'; fi
  ok 'E2E: master moves during implementation and review; draft published at the pinned base'

  # 2) Revision on the existing PR while master moves again (base integration + drift).
  mv "$LOOP_STATE_DIR/pending.json" "$TMP/e2e-pending-1"; touch "$TMP/e2e-pr"; : >"$CALLS"
  CURRENT_ISSUE="" CURRENT_CLAIM_REF="" E2E_REVIEW_PUSH=""
  E2E_FILE=revision.txt E2E_CHANGE=revision E2E_MASTER_FILE=third.txt E2E_MASTER_TEXT='third PR'
  process_revision "$E2E_ISSUE" >"$OUT" 2>&1 || { cat "$OUT"; fail 'revision with master drift blocked'; }
  grep -q 'Fresh Base Integration' "$TMP/e2e-prompt" || fail 'revision base integration not announced'
  [[ "$(command git --git-dir="$R" rev-parse "refs/heads/$E2E_BRANCH")" == "$(git rev-parse HEAD)" ]] || fail 'revision not pushed'
  git merge-base --is-ancestor "$HEAD5" HEAD || fail 'revision rewrote published history'
  grep -q 'HEAD merges cleanly, pinned base kept' "$OUT" || fail 'revision drift not logged'
  ok 'E2E: revision integrates the moved base and publishes with lease while master moves again'

  # 3) A conflicting master commit during implementation blocks with the file list.
  mv "$LOOP_STATE_DIR/pending.json" "$TMP/e2e-pending-2"
  e2e_issue 6 'Change shared file'
  E2E_FILE=shared.txt E2E_CHANGE='shared from task' E2E_MASTER_FILE=shared.txt E2E_MASTER_TEXT='shared from master'
  reject process_issue "$E2E_ISSUE" false >"$OUT" 2>&1
  grep -q 'Base check after implementation: main moved to .* conflicts with HEAD in: shared.txt' "$LOOP_STATE_DIR/blocked-6.json" || fail 'conflict reason missing file list'
  if command git --git-dir="$R" rev-parse -q --verify "refs/heads/$E2E_BRANCH" >/dev/null || grep -q 'pr create' "$CALLS"; then fail 'conflict published'; fi
  [[ -f "$LOOP_STATE_DIR/pending.json" ]] && fail 'conflict left pending receipt'
  ok 'E2E: real conflict with a moved master blocks before gates/publication and names the files'
)
