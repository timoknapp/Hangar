#!/usr/bin/env bash
# Real provenance wiring; only operator-owned hook/API boundaries are synthetic.
# shellcheck disable=SC2034,SC2317
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export GITHUB_OWNER=example GITHUB_REPO=repo
# shellcheck source=/dev/null
source "$ROOT/worker/worker-loop.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
CURRENT_ISSUE=7 TASK_KEEP_DRAFT=false
ISSUE='{"number":7,"title":"Bounded review","body":"Report only","state":"OPEN","labels":[]}'
LOOP_PROFILE_DIR=''
refresh_review_origin "$ISSUE"
[[ "$CURRENT_REVIEW_ORIGIN" == null && "$TASK_KEEP_DRAFT" == false ]]
LOOP_PROFILE_DIR="$TMP/profile";mkdir "$LOOP_PROFILE_DIR"
cat >"$LOOP_PROFILE_DIR/review-origin.sh" <<'HOOK'
#!/bin/bash
set -euo pipefail
input=$(cat)
hash=$(jq -cS '{title,body}' <<<"$input" | sha256sum | cut -d' ' -f1)
jq -cn --arg contract "$hash" '{kind:"scheduled-review",issue:7,contractHash:$contract,date:"2026-10-26",draftOnly:true,allowedPaths:["review.md"]}'
HOOK
# Permission/trusted-path validation is covered by profile-access tests; replace
# that boundary here, not the output parsing, contract binding or command flow.
read_profile_file() { [[ "${HOOK_TRUSTED:-true}" == true ]] && cat "$LOOP_PROFILE_DIR/$1"; }
task_seconds_remaining() { echo 10; }
refresh_review_origin "$ISSUE"
[[ "$TASK_KEEP_DRAFT" == true ]]
jq -e '.issue==7 and .kind=="scheduled-review"' <<<"$CURRENT_REVIEW_ORIGIN" >/dev/null
for content in 'echo "{}"' 'echo "not json"' 'printf "null\\nnull\\n"' 'exit 78' 'echo "{\"kind\":\"scheduled-review\",\"issue\":8}"'; do
 printf '%s\n' "$content" >"$LOOP_PROFILE_DIR/review-origin.sh"
 if refresh_review_origin "$ISSUE" 2>/dev/null; then fail 'invalid or failed origin accepted'; fi
 [[ "$CURRENT_REVIEW_ORIGIN" == null ]] || fail 'stale origin retained'
done
printf 'echo null\n' >"$LOOP_PROFILE_DIR/review-origin.sh"
HOOK_TRUSTED=false
if refresh_review_origin "$ISSUE"; then fail 'untrusted operator file accepted'; fi
HOOK_TRUSTED=true;refresh_review_origin "$ISSUE"
[[ "$CURRENT_REVIEW_ORIGIN" == null ]]
# Fourth argument is evidence, never manual intake or a broad queue bypass.
CURRENT_REVIEW_ORIGIN='{"kind":"scheduled-review"}'
CURRENT_MANUAL_INTAKE=false TASK_BASE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf 'exit 0\n' >"$LOOP_PROFILE_DIR/verify.sh"
git() { echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; }
cmd=$(resolve_verify_cmd)
[[ "$cmd" == *unattended* && "$cmd" == *scheduled-review* ]] || fail 'verify provenance not delivered separately'
[[ "$(declare -f publication_authorized)" == *refresh_review_origin* ]] || fail 'publication never rechecks origin'
[[ "$(declare -f refresh_issue_evidence)" == *reviewOrigin* ]] || fail 'reviewer metadata missing origin'
for kind in policy code infrastructure; do
 VERIFY_FAILURE_KIND="$kind";reason=$(baseline_block_reason)
 [[ "$(receipt_class "$reason")" == "$kind" ]] || fail "baseline $kind misclassified"
 if [[ "$kind" == policy ]] && retryable_failure "$reason"; then fail 'policy block auto-retries'; fi
done
printf 'PASS: operator origin bound to issue/contract, refresh/revocation, draft-only, separate unprivileged context; baseline policy/code/infrastructure preserved\n'
