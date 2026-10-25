#!/usr/bin/env bash
# Block 6: opt-in learning loop. Signals and the model are fixtures; Git, the
# path guard, the proposal validator and the publisher-side write are real.
# shellcheck disable=SC2016,SC2034,SC2317
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export GITHUB_OWNER=example GITHUB_REPO=repo REPO_BRANCH=main WORKSPACE_DIR="$TMP/repo" LOOP_STATE_DIR="$TMP/state"
# shellcheck source=/dev/null
source "$ROOT/worker/worker-loop.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "PASS: $*"; }
wrap() { printf 'LEARNING_JSON_BEGIN\n%s\nLEARNING_JSON_END\n' "$1"; }

# --- policy: off by default, strict values ---
[[ "$LOOP_LEARNING" == false ]] || fail 'learning must be off by default'
validate_learning_policy || fail 'default policy rejected'
for bad in 'LOOP_LEARNING=yes' 'LOOP_LEARNING_DAYS=0' 'LOOP_LEARNING_MIN_REPEATS=1'; do
  (eval "$bad"; ! validate_learning_policy 2>/dev/null) || fail "accepted: $bad"
done
ok 'learning is off by default; invalid settings fail closed; a single repeat is never enough'

# --- repeats: one-off signals produce nothing ---
one='{"kind":"pr-changed","ref":"#1","note":"x"}
{"kind":"pr-changed","ref":"#1","note":"y"}
{"kind":"pr-closed","ref":"#2","note":"z"}'
[[ "$(learning_repeats <<<"$one")" == '[]' ]] || fail 'one-off signals (same ref twice) counted as a repeat'
two="$one"$'\n''{"kind":"pr-changed","ref":"#3","note":"w"}'
[[ "$(learning_repeats <<<"$two" | jq -c '[.[] | {kind, refs}]')" == '[{"kind":"pr-changed","refs":["#1","#3"]}]' ]] || fail 'repeat across two refs not found'
ok 'only a kind seen on at least two different refs is a repeated signal'

# --- signal collection from GitHub (fixture): human corrections only ---
NOW=$(date -u +%FT%TZ); OLD=$(date -u -d '-30 days' +%FT%TZ)
gh() {
  case "$1 $2" in
    'pr list') jq -cn --arg now "$NOW" --arg old "$OLD" '[
      {number:1,state:"MERGED",mergedAt:$now,closedAt:$now,headRefName:"squad/1-a",
       commits:[{authors:[{login:"worker[bot]"}]},{authors:[{login:"Owner"}]}],comments:[]},
      {number:2,state:"CLOSED",mergedAt:null,closedAt:$now,headRefName:"squad/2-b",commits:[],comments:[]},
      {number:3,state:"MERGED",mergedAt:$now,closedAt:$now,headRefName:"squad/3-c",commits:[{authors:[{login:"worker[bot]"}]}],
       comments:[{author:{login:"worker[bot]"},createdAt:$old,body:"ready"},{author:{login:"Owner"},createdAt:$now,body:"F2 was wrong"}]},
      {number:4,state:"CLOSED",mergedAt:null,closedAt:$old,headRefName:"squad/4-d",commits:[],comments:[]},
      {number:5,state:"CLOSED",mergedAt:null,closedAt:$now,headRefName:"squad/learning-20261001",commits:[],comments:[]},
      {number:6,state:"CLOSED",mergedAt:null,closedAt:$now,headRefName:"feature/x",commits:[],comments:[]}]' ;;
    'api --paginate') jq -cn --arg now "$NOW" '[
      {created_at:$now,event:"labeled",label:{name:"scope:large-approved"},actor:{type:"User"},issue:{number:7}},
      {created_at:$now,event:"labeled",label:{name:"squad:spec"},actor:{type:"Bot"},issue:{number:8}},
      {created_at:$now,event:"labeled",label:{name:"bug"},actor:{type:"User"},issue:{number:9}}]' ;;
    *) fail "unexpected gh $*" ;;
  esac
}
sig=$(collect_learning_signals | jq -sc 'map("\(.kind) \(.ref)") | sort')
[[ "$sig" == '["critic-reply #3","pr-changed #1","pr-closed #2","triage-override #7"]' ]] || fail "signals: $sig"
unset -f gh
ok 'signals: human commits, unmerged closes, human replies and human triage overrides; bots, old items, other branches and learning PRs ignored'

# --- validator: only the two rubric files, bounded, exact shape ---
good='{"files":{".loop/review-rubric.md":"# Rubric\n- new rule"},"summary":"pr-changed on #1,#3"}'
validate_learning "$(wrap "$good")" >/dev/null || fail 'valid proposal rejected'
for bad in '{"files":{"worker/worker-loop.sh":"x"},"summary":"s"}' '{"files":{"../.loop/triage.md":"x"},"summary":"s"}' \
  '{"files":{},"summary":"s"}' '{"files":{".loop/triage.md":""},"summary":"s"}' '{"files":{".loop/triage.md":"x"}}' \
  '{"files":{".loop/triage.md":"x"},"summary":"s","extra":1}' '{"files":{"AGENTS.md":"x",".loop/triage.md":"y"},"summary":"s"}'; do
  if validate_learning "$(wrap "$bad")" >/dev/null 2>&1; then fail "accepted proposal: $bad"; fi
done
if validate_learning "$good" >/dev/null 2>&1; then fail 'unmarked proposal accepted'; fi
ok 'proposal validator accepts only .loop/review-rubric.md and .loop/triage.md with bounded content'

# --- path guard on real Git ---
git init -q -b main "$WORKSPACE_DIR"; cd "$WORKSPACE_DIR"
git config user.name Fixture; git config user.email fixture@example.invalid
printf 'app\n' >app.txt && git add . && git commit -qm base; BASE=$(git rev-parse HEAD)
mkdir -p .loop && printf 'r\n' >.loop/review-rubric.md && git add . && git commit -qm rubric
learning_paths_ok "$BASE" || fail 'rubric-only change rejected'
printf 'x\n' >app.txt && git commit -qam code
if learning_paths_ok "$BASE"; then fail 'code change accepted by the learning guard'; fi
[[ "$LEARNING_GUARD_PATH" == app.txt ]] || fail "guard path: $LEARNING_GUARD_PATH"
git reset -q --hard "$BASE"
if learning_paths_ok "$BASE"; then fail 'empty change accepted'; fi
ok 'path guard: only the two rubric files; any other path or no change blocks before push'

# --- end to end: proposal written by the publisher, pushed as a draft PR ---
git init -q --bare "$TMP/remote"; git remote add origin "$TMP/remote"; git push -q origin main
CLEAN_REPO_URL="$TMP/remote" LOOP_LEARNING=true COPILOT_PAT=x COPILOT_MODEL="" TASK_DEADLINE=0
init_loop_state
sanitize_repository_git_config() { return 0; }
check_repository_evidence() { return 0; }
repair_shared_workspace_modes() { return 0; }
read_trusted_file() { git show "${TASK_BASE_SHA}:$1" 2>/dev/null; }
retain_gate_log() { :; }
collect_learning_signals() { printf '%s\n' '{"kind":"pr-changed","ref":"#1","note":"a"}' '{"kind":"pr-changed","ref":"#3","note":"b"}'; }
MODEL_OUT=$(wrap "$good")
run_agent_copilot() {
  [[ " $* " == *' --deny-tool=write '* && " $* " == *' --deny-tool=shell '* ]] || fail 'learning session not read-only'
  jq -cn --arg c "$MODEL_OUT" '{type:"assistant.message",data:{content:$c,toolRequests:[]}}, {type:"result",exitCode:0}'
}
gh() { printf '%s\n' "$*" >>"$TMP/gh"; case "$1 $2" in 'pr list') echo 0 ;; 'pr create') return 0 ;; *) fail "unexpected gh $*" ;; esac; }
run_learning >"$TMP/run.log" 2>&1 || { cat "$TMP/run.log"; fail "learning run failed"; }
branch=$(git --git-dir="$TMP/remote" for-each-ref --format='%(refname:short)' 'refs/heads/squad/learning-*')
[[ -n "$branch" ]] || { grep -v UNDICI "$TMP/run.log" | tail -n 12; fail 'no proposal branch pushed'; }
[[ "$(git --git-dir="$TMP/remote" diff --name-only main "$branch")" == .loop/review-rubric.md ]] || fail 'proposal changed more than the rubric'
grep -q -- 'pr create .*--draft' "$TMP/gh" || fail 'proposal not opened as draft'
run_learning >/dev/null 2>&1; [[ "$(grep -c 'pr create' "$TMP/gh")" == 1 ]] || fail 'second proposal within the same week'
ok 'end to end: the publisher writes only the proposed rubric file, pushes it, opens a draft PR, once per week'

# --- invalid model output pushes nothing ---
rm -f "$LOOP_STATE_DIR/learning-last"; : >"$TMP/gh"
MODEL_OUT=$(wrap '{"files":{"worker/worker-loop.sh":"evil"},"summary":"s"}')
git --git-dir="$TMP/remote" update-ref -d "refs/heads/$branch"
run_learning >/dev/null 2>&1 || true
[[ -z "$(git --git-dir="$TMP/remote" for-each-ref 'refs/heads/squad/learning-*')" ]] || fail 'invalid proposal pushed'
! grep -q 'pr create' "$TMP/gh" || fail 'PR created for an invalid proposal'
[[ "$(git status --porcelain)" == '' ]] || fail 'workspace left dirty'
rm -f "$LOOP_STATE_DIR/learning-last"
collect_learning_signals() { printf '%s\n' '{"kind":"pr-closed","ref":"#9","note":"once"}'; }
run_learning >/dev/null 2>&1 || true
! grep -q 'pr create' "$TMP/gh" || fail 'one-off signal produced a PR'
ok 'invalid proposals and one-off signals push nothing and leave the workspace clean'
