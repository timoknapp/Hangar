#!/usr/bin/env bash
# Block 3a: large reviews are split into parts, each a fresh critic session
# with its own full-delivery proof; every part must approve. Real local Git and
# the real critic (run_critic) with the shared CLI-event fake from
# critic-complete-input.test.sh.
# shellcheck disable=SC1091,SC2016,SC2034,SC2317
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
python3 - <<'PY'
from pathlib import Path
for name in ('a.txt', 'b.txt', 'c.txt'):
    Path(name).write_text(''.join(f'{name} line {i}\n' for i in range(700)))
Path('d.png').write_bytes(bytes(range(256)) * 64)
PY
git add . && git commit -qm 'three text files and one binary'
LOOP_CRITIC=true LOOP_CRITIC_MODEL=fixture-model LOOP_MAX_REVIEW_BYTES=1048576 LOOP_COPILOT_SECRET_FILTER_MODULE=off
COPILOT_PAT=fixture CRITIC_INPUT_NONCE_OVERRIDE=fixture-nonce CRITIC_FINDINGS_LEDGER='[]'
CURRENT_ISSUE_CONTEXT='Add three files.' FINAL_PR_BODY='Adds files.'
APPROVE=$'VERDICT: APPROVE\nINPUT_NONCE: fixture-nonce\nFINDINGS_JSON_BEGIN\n[]\nFINDINGS_JSON_END'
REJECT=$'VERDICT: REQUEST_CHANGES\nINPUT_NONCE: fixture-nonce\nFINDINGS_JSON_BEGIN\n[{"id":"F1","severity":"BLOCK","category":"correctness","location":"b.txt:1","evidence":"wrong content in b","status":"open"}]\nFINDINGS_JSON_END'
: >"$TMP/sessions"
run_agent_copilot() {
  local input; input=$(find "$WORKSPACE_DIR" -maxdepth 1 -name '.critic-input.*.md')
  local files; files=$(grep -o '^diff --git a/[^ ]*' "$input" | sed 's|diff --git a/||' | paste -sd, -)
  echo "$files" >>"$TMP/sessions"
  local out="$APPROVE" mode=full
  [[ "$files" != *"${REJECT_FILE:-none}"* ]] || out="$REJECT"
  [[ "$files" != *"${GAP_FILE:-none}"* ]] || mode=hole
  CRITIC_TEST_MODE=$mode FAKE_COPILOT_OUTPUT="$out" bash "$ROOT/tests/critic-complete-input.test.sh" --emit "$input"
}

# --- partitioning ---
LOOP_CRITIC_SPLIT_LINES=100000
[[ "$(critic_parts | jq -c .)" == '[["a.txt","b.txt","c.txt","d.png"]]' ]] || fail "small change split: $(critic_parts)"
LOOP_CRITIC_SPLIT_LINES=1000
parts=$(critic_parts)
[[ "$(jq -c . <<<"$parts")" == '[["a.txt"],["b.txt"],["c.txt","d.png"]]' ]] || fail "parts: $parts"
[[ "$(jq '[.[][]] | length' <<<"$parts")" == 4 && "$(jq '[.[][]] | unique | length' <<<"$parts")" == 4 ]] || fail 'every file exactly once'
ok 'files are grouped whole and in order; every changed file lands in exactly one part'

# --- below threshold: one ordinary review ---
LOOP_CRITIC_SPLIT_LINES=100000; : >"$TMP/sessions"
run_critic_review || fail "single review rejected: $CRITIC_FEEDBACK"
[[ "$(wc -l <"$TMP/sessions")" == 1 && "$(cat "$TMP/sessions")" == 'a.txt,b.txt,c.txt,d.png' ]] || fail 'small change not reviewed in one session'
single_hash="$REVIEW_DIFF_HASH"
ok 'a change below the threshold is reviewed exactly as before (one session, whole diff)'

# --- above threshold: every part reviewed and approved ---
LOOP_CRITIC_SPLIT_LINES=1000; : >"$TMP/sessions"
run_critic_review || fail "split review rejected: $CRITIC_FEEDBACK"
[[ "$(cat "$TMP/sessions")" == $'a.txt\nb.txt\nc.txt,d.png' ]] || fail "sessions: $(cat "$TMP/sessions")"
[[ "$REVIEW_DIFF_HASH" =~ ^[0-9a-f]{64}$ && "$REVIEW_DIFF_HASH" != "$single_hash" ]] || fail 'split review must bind its own part hashes'
[[ -z "${CRITIC_PART_PATHS[*]}" && -z "$CRITIC_PART_NOTE" ]] || fail 'part scope leaked out of the review'
ok 'above the threshold each part gets its own session and all must approve'

# --- one part rejects: whole review rejects, later parts still see the ledger ---
: >"$TMP/sessions"; REJECT_FILE=b.txt
if run_critic_review; then fail 'part with REQUEST_CHANGES approved the whole review'; fi
[[ "$CRITIC_FAILURE_KIND" == review && "$CRITIC_FEEDBACK" == "Review part 2/3:"* ]] || fail "rejection not attributed: $CRITIC_FAILURE_KIND $CRITIC_FEEDBACK"
[[ "$(wc -l <"$TMP/sessions")" == 2 ]] || fail 'review continued after a rejected part'
jq -e 'any(.[]; .id == "F1" and .status == "open")' <<<"$CRITIC_FINDINGS_LEDGER" >/dev/null || fail 'finding not kept for correction'
REJECT_FILE=none CRITIC_FINDINGS_LEDGER='[]'
ok 'a rejecting part blocks the review, names its part and keeps the finding for correction'

# --- one part with incomplete delivery: never approved ---
: >"$TMP/sessions"; GAP_FILE=c.txt LOOP_CRITIC_ATTEMPTS=1
if run_critic_review; then fail 'part with a delivery hole approved'; fi
[[ "$CRITIC_FAILURE_KIND" == incomplete && "$CRITIC_FEEDBACK" == "Review part 3/3: Critic full-input delivery was not proven"* ]] || fail "hole: $CRITIC_FEEDBACK"
GAP_FILE=none
ok 'every part needs its own complete delivery proof; a gap in any part blocks'

# --- a single oversized file still fails closed ---
LOOP_MAX_REVIEW_BYTES=5000
run_agent_copilot() { fail 'oversized part called the model'; }
if run_critic_review; then fail 'oversized part accepted'; fi
[[ "$CRITIC_FAILURE_KIND" == incomplete && "$CRITIC_FEEDBACK" == *"byte budget"* ]] || fail "oversize: $CRITIC_FEEDBACK"
ok 'a part that alone exceeds the byte budget still blocks without a model call'

grep -q 'run_critic_review' <<<"$(declare -f run_quality_gates)" || fail 'quality gates bypass the split review'
! grep -q 'run_critic_attempts' <<<"$(declare -f run_quality_gates)" || fail 'quality gates call the unsplit critic directly'
ok 'quality gates always go through the split-aware review'
