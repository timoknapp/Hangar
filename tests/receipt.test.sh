#!/usr/bin/env bash
# Attempt receipts: publisher-derived marker, credit accounting and failure
# classes, plus the GitHub-only metrics tool against synthetic fixtures.
# shellcheck disable=SC2034,SC2317
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export GITHUB_OWNER=example GITHUB_REPO=repo REPO_BRANCH=main WORKSPACE_DIR="$TMP/repo" LOOP_STATE_DIR="$TMP/state"
# shellcheck source=/dev/null
source "$ROOT/worker/worker-loop.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "PASS: $*"; }
marker_json() { sed -nE 's/^<!-- hangar-receipt (.*) -->$/\1/p' <<<"$1"; }

WORKER_ID=worker-7
receipt_begin issue
[[ "$TASK_STAGE" == admission && "$TASK_CREDITS" == 0 && "$TASK_STARTED_AT" -gt 0 ]] || fail 'begin state'
printf 'noise\nAI Credits 714 (21m 41s)\n' >"$TMP/a.log"
printf 'AI Credits 89 (2m 1s)\n' >"$TMP/b.log"
receipt_add_credits "$TMP/a.log"; receipt_add_credits "$TMP/b.log"
[[ "$TASK_CREDITS" == 803 ]] || fail "credit sum: $TASK_CREDITS"
ok 'credits summed across implementer and correction sessions'
printf 'crashed before summary\n' >"$TMP/c.log"
receipt_add_credits "$TMP/c.log"; receipt_add_credits "$TMP/a.log"
[[ "$TASK_CREDITS" == unknown ]] || fail 'missing credit line must make the total unknown'
receipt_add_credits "$TMP/missing.log"
[[ "$TASK_CREDITS" == unknown ]] || fail 'unknown must stay unknown'
ok 'missing or unreadable credit line yields unknown, never a low count'

TASK_STAGE=review TASK_CREDITS=803
json=$(marker_json "$(receipt_marker failed infrastructure)")
jq -e '.v==1 and .worker=="worker-7" and .kind=="issue" and .stage=="review" and .outcome=="failed" and
  .class=="infrastructure" and (.seconds|type=="number") and .implementerCredits==803' <<<"$json" >/dev/null || fail "marker: $json"
TASK_STARTED_AT=0 TASK_CREDITS=unknown
json=$(marker_json "$(receipt_marker ready)")
jq -e '.class==null and .seconds=="unknown" and .implementerCredits=="unknown"' <<<"$json" >/dev/null || fail "unknown marker: $json"
ok 'marker carries only publisher fields; unknown is explicit'
WORKER_ID='w --> <script>'
[[ -z "$(receipt_marker ready)" ]] || fail 'comment-terminating worker id must suppress the marker'
WORKER_ID=worker-7
ok 'marker cannot terminate the HTML comment'

while IFS='|' read -r reason expected; do
  [[ "$(receipt_class "$reason")" == "$expected" ]] || fail "class of '$reason' is $(receipt_class "$reason"), expected $expected"
done <<'EOF'
No changes produced; operator assessment required|decision
Revision produced no changes; explicit retry required|decision
Independent review: open BLOCK findings remain after 4/4 corrections.|review
Verification failed; correction budget exhausted (2/2) or baseline unproven.|code
Required remote check failed on the current head; automatic CI revision budget exhausted|code
Operator policy blocked verification; no code correction attempted.|policy
Publication canceled: required label approved is absent|policy
Remote branch already exists; explicit revision required|policy
Fresh clean base preparation failed; workspace retained|infrastructure
Critic process exited with code 1. invalid CLI event JSON|infrastructure
Critic full-input delivery was not proven: incomplete input delivery (3500/6593 lines)|infrastructure
Could not refresh the authoritative base after implementation|infrastructure
Infrastructure/verification unavailable; no code correction attempted.|infrastructure
Implementation failed or timed out (exit 124)|infrastructure
Review input still contains text the Copilot CLI masks (lines: 2896)|infrastructure
Complete review exceeds configured byte budget; split or obtain explicit human review.|infrastructure
Worker interrupted; explicit retry/recovery required|infrastructure
Something nobody anticipated|unclassified
EOF
ok 'known block reasons map to exactly one class; unknown stays unclassified'

# cleanup_issue posts the marker on every blocked path.
gh() {
  case "$1 $2" in
    'issue edit') return 0 ;;
    'issue comment') printf '%s\n' "$*" >>"$TMP/comments"; return 0 ;;
    *) fail "unexpected gh call: $*" ;;
  esac
}
release_issue_claim() { return 0; }
CURRENT_CLAIM_REF="" TASK_STAGE=implement TASK_CREDITS=12 TASK_STARTED_AT=$(date +%s)
cleanup_issue 41 squad/41-x "No changes produced; operator assessment required"
grep -q '"outcome":"no-change","class":"decision"' "$TMP/comments" || fail 'no-change receipt missing'
cleanup_issue 42 squad/42-x "Fresh clean base preparation failed; workspace retained"
grep -q '"stage":"implement","outcome":"failed","class":"infrastructure"' "$TMP/comments" || fail 'failed receipt missing'
ok 'blocked paths publish exactly the classified receipt'

python3 "$ROOT/tests/factory-metrics.test.py"
