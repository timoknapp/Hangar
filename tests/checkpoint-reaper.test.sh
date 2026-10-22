#!/usr/bin/env bash
# Block 2b: checkpoint resume after committed implementation, and the reaper
# for orphaned own claims and stale checkpoints. Real local Git; GitHub and
# gates are fixtures.
# shellcheck disable=SC1091,SC2016,SC2034,SC2317
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export GITHUB_OWNER=example GITHUB_REPO=repo REPO_BRANCH=main
export WORKSPACE_DIR="$TMP/repo" LOOP_STATE_DIR="$TMP/state"
AGENT_GROUP=$(id -gn); export AGENT_GROUP
# shellcheck source=/dev/null
source "$ROOT/worker/worker-loop.sh"
# shellcheck source=tests/fixtures/evidence-user-switch.sh
source "$ROOT/tests/fixtures/evidence-user-switch.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "PASS: $*"; }
git init --bare -q "$TMP/remote"; git init -q "$WORKSPACE_DIR"; cd "$WORKSPACE_DIR"
printf 'base\n' > app.txt; git add . && git commit -qm base && git branch -M main
git remote add origin "$TMP/remote"; CLEAN_REPO_URL="$TMP/remote"; git push -q origin main
init_loop_state
WORKER_ID=worker-7 ISSUE_CONTRACT_HASH=contract-a TASK_CREDITS=700

make_attempt() {
  begin_task; prepare_task_base squad/9-x
  printf 'work\n' > feature.txt; git add feature.txt && git commit -qm work
  PR_EXECUTIVE_SUMMARY="## Problem
p"
  write_checkpoint 9 squad/9-x
  WORK_HEAD=$(git rev-parse HEAD) BASE="$TASK_BASE_SHA"
  git checkout -q --detach "$BASE"
}
fresh_state() { begin_task; PR_EXECUTIVE_SUMMARY="" TASK_CREDITS=0; }

make_attempt
[[ "$(stat -c %a "$(checkpoint_file 9)")" == 600 ]] || fail 'checkpoint must be private'
fresh_state
load_checkpoint 9 || fail 'valid checkpoint not resumed'
[[ "$(git rev-parse HEAD)" == "$WORK_HEAD" && "$TASK_BRANCH" == squad/9-x && "$TASK_BASE_SHA" == "$BASE" ]] || fail 'resume state wrong'
[[ "$PR_EXECUTIVE_SUMMARY" == *"## Problem"* && "$TASK_CREDITS" == 700 ]] || fail 'summary/credits not restored'
ok 'committed implementation resumes at its exact HEAD with base, summary and credits'

expect_fresh() {
  local label="$1"
  fresh_state
  if load_checkpoint 9 2>/dev/null; then fail "$label resumed"; fi
  [[ ! -f "$(checkpoint_file 9)" ]] || fail "$label kept a stale checkpoint"
}
git checkout -q --detach "$BASE"
make_attempt; ISSUE_CONTRACT_HASH=contract-b; expect_fresh 'changed issue contract'; ISSUE_CONTRACT_HASH=contract-a
make_attempt; WORKER_ID=worker-8; expect_fresh 'other worker'; WORKER_ID=worker-7
make_attempt; git branch -f squad/9-x "$BASE"; expect_fresh 'moved branch'
make_attempt; git branch -D -q squad/9-x; expect_fresh 'deleted branch'
make_attempt; jq '.head="zz"' "$(checkpoint_file 9)" > "$TMP/x" && mv "$TMP/x" "$(checkpoint_file 9)"; expect_fresh 'malformed checkpoint'
make_attempt; jq '.v=2' "$(checkpoint_file 9)" > "$TMP/x" && mv "$TMP/x" "$(checkpoint_file 9)"; expect_fresh 'unknown schema'
ok 'contract change, other worker, moved/deleted branch, malformed or unknown checkpoints start fresh'

make_attempt; printf 'dirt\n' > stray.txt
fresh_state
if load_checkpoint 9 2>/dev/null; then fail 'resumed over a dirty workspace'; fi
[[ -f stray.txt && -f "$(checkpoint_file 9)" ]] || fail 'dirty workspace must not lose files or the checkpoint'
rm stray.txt
ok 'dirty workspace blocks resume without discarding anything'

# The resumed run goes through exactly the fresh gates and publisher.
src=$(declare -f process_issue)
grep -q 'load_checkpoint "$issue_num"' <<<"$src" || fail 'process_issue never resumes'
resume=$(sed -n '/load_checkpoint "$issue_num"/,/^        return;$/p' <<<"$src")
[[ $(wc -l <<<"$resume") -lt 12 ]] || fail 'resume block not isolated'
grep -q 'verify_clean_baseline' <<<"$resume" || fail 'resume skips the baseline proof'
grep -q 'finish_issue' <<<"$resume" || fail 'resume skips the shared gates'
! grep -q 'run_agent_copilot\|implementer' <<<"$resume" || fail 'resume must not rerun the implementer'
grep -q 'write_checkpoint' <<<"$src" || fail 'no checkpoint written after implementation'
grep -q 'clear_checkpoint' <<<"$(declare -f save_pending_publication)" || fail 'published work must drop its checkpoint'
ok 'resume reruns baseline proof and the shared gates/publisher, never the implementer'

# --- reaper ---
CLAIMS='[]' VIEW='{"state":"OPEN","labels":[{"name":"squad"}]}'
gh() {
  case "$*" in
    'api --paginate repos/example/repo/git/matching-refs/heads/squad-claims/issue-') printf '%s\n' "$CLAIMS" ;;
    'api repos/example/repo/git/commits/'*) local oid=${2##*/}; jq -r --arg o "$oid" '.[] | select(.object.sha==$o) | .owner' <<<"$CLAIMS" ;;
    'issue view'*) jq -r 'if .state != "OPEN" then "closed" elif ([.labels[].name] | index("squad")) == null then "unlabeled" else "open" end' <<<"$VIEW" ;;
    *) fail "unexpected gh call: $*" ;;
  esac
}
REAPED=""
cleanup_issue() { REAPED+="$1:$2:$3|"; [[ "$CURRENT_CLAIM_REF" == refs/heads/squad-claims/issue-* ]] || fail 'reaper did not bind the claim'; }
own=1111111111111111111111111111111111111111 other=2222222222222222222222222222222222222222
CLAIMS=$(jq -n --arg a "$own" --arg b "$other" '[{ref:"refs/heads/squad-claims/issue-9",object:{sha:$a},owner:"worker-7"},
  {ref:"refs/heads/squad-claims/issue-5",object:{sha:$b},owner:"worker-3"}]')
REAPER_LAST_RUN=0 CURRENT_ISSUE="" CURRENT_CLAIM_REF=""
reap_orphans
[[ "$REAPED" == "9:squad/9-x:Worker interrupted; explicit retry/recovery required|" ]] || fail "reaped: $REAPED"
[[ -z "$CURRENT_ISSUE" && -z "$CURRENT_CLAIM_REF" ]] || fail 'reaper left task state behind'
ok "own orphaned claim is blocked as interrupted (retryable); other workers' claims untouched"

REAPED=""; reap_orphans
[[ -z "$REAPED" ]] || fail 'reaper ran again before its interval'
REAPER_LAST_RUN=0 CURRENT_ISSUE=42; reap_orphans
[[ -z "$REAPED" ]] || fail 'reaper acted while the worker holds work'
CURRENT_ISSUE=""
ok 'reaper runs only on an idle worker and at most once per interval'

for v in '{"state":"CLOSED","labels":[{"name":"squad"}]}' '{"state":"OPEN","labels":[]}'; do
  make_attempt; CLAIMS='[]' VIEW="$v" REAPER_LAST_RUN=0; reap_orphans
  [[ ! -f "$(checkpoint_file 9)" ]] || fail "checkpoint kept for $v"
  git show-ref --verify --quiet refs/heads/squad/9-x || fail 'reaper deleted work'
done
make_attempt; VIEW='{"state":"OPEN","labels":[{"name":"squad"}]}' REAPER_LAST_RUN=0; reap_orphans
[[ -f "$(checkpoint_file 9)" ]] || fail 'checkpoint of an open issue dropped'
ok 'checkpoints of closed/unlabeled issues are dropped; branches always kept'

grep -q 'reap_orphans' <<<"$(declare -f main)" || fail 'main never reaps'
ok 'main loop runs the reaper'
