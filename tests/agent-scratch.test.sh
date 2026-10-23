#!/usr/bin/env bash
# Agent scratch output never blocks or pollutes a correction commit, and an
# unrecordable correction is reported as such instead of as stale findings.
# Git and the critic ledger are real; the model session is a fixture.
# shellcheck disable=SC2034,SC2317
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
[[ "$(id -u)" != 0 ]] || { echo 'SKIP: unreadable-file fixture needs a non-root user'; exit 0; }
export GITHUB_OWNER=example GITHUB_REPO=repo REPO_BRANCH=main WORKSPACE_DIR="$TMP/repo" LOOP_STATE_DIR="$TMP/state"
# shellcheck source=/dev/null
source "$ROOT/worker/worker-loop.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "PASS: $*"; }

git init -q -b main "$WORKSPACE_DIR"
cd "$WORKSPACE_DIR"
git config user.name Fixture; git config user.email fixture@example.invalid
printf 'base\n' >app.txt && git add . && git commit -qm base
CLEAN_REPO_URL="$TMP/remote"
export GIT_AUTHOR_NAME=Fixture GIT_COMMITTER_NAME=Fixture
export GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_EMAIL=fixture@example.invalid

# The sanitizer registers the scratch directory as ignored, exactly once.
check_repository_evidence() { return 0; }
sanitize_repository_git_config || fail 'sanitizer failed'
sanitize_repository_git_config || fail 'sanitizer not idempotent'
[[ "$(grep -cxF "/${AGENT_SCRATCH_DIR}/" .git/info/exclude)" == 1 ]] || fail 'scratch not ignored exactly once'
mkdir -p "$AGENT_SCRATCH_DIR/runtime/profile" && printf 'log\n' >"$AGENT_SCRATCH_DIR/verify.log"
chmod 2700 "$AGENT_SCRATCH_DIR/runtime/profile"
[[ -z "$(git status --porcelain)" ]] || fail 'scratch output visible to git'
LOOP_IMPLEMENTER=squad implementer_capability_instructions | grep -q '.hangar-scratch/' || fail 'implementer not told where scratch goes'
ok 'scratch directory is ignored by Git, even with unreadable browser profiles inside'

# A correction whose result cannot be committed reports exactly that.
task_integrity() { return 0; }
prepare_pr_summary() { return 0; }
refresh_issue_evidence() { return 0; }
issue_evidence_context() { echo evidence; }
retain_gate_log() { :; }
run_agent_copilot() {
  printf 'fixed\n' >app.txt
  # As on the real worker: an unreadable cache file the publisher cannot index.
  mkdir -p .verification-7/runtime && printf 'cache\n' >.verification-7/runtime/cache && chmod 000 .verification-7/runtime/cache
}
begin_task; TASK_DEADLINE=0 CURRENT_ISSUE=7 LOOP_MAX_RETRIES=4 CURRENT_MANUAL_INTAKE=false COPILOT_PAT=fixture-model-credential
CRITIC_FINDINGS_LEDGER='[{"id":"F1","severity":"BLOCK","category":"scope","location":"x:1","evidence":"stale finding","status":"open"}]'
head_before=$(git rev-parse HEAD)
if take_correction 'Independent review requested changes.' >"$TMP/corr.log" 2>&1; then
  fail 'unrecordable correction reported success'
fi
correction_unrecorded || { cat "$TMP/corr.log" >&2; fail "unrecorded correction not classified: $CORRECTION_BLOCK"; }
[[ "$(git rev-parse HEAD)" == "$head_before" && "$(cat app.txt)" == fixed ]] || fail 'correction work not retained locally'
chmod 600 .verification-7/runtime/cache

# The review loop reports the unrecorded correction, never the stale findings.
run_verify_with_corrections() { return 0; }
summary_complete() { return 0; }
build_final_pr_body() { FINAL_PR_BODY=body; }
LOOP_CRITIC=true
run_critic_review() { CRITIC_FAILURE_KIND=review; return 1; }
run_agent_copilot() { printf 'again\n' >app.txt; chmod 000 .verification-7/runtime/cache; }
begin_task; TASK_DEADLINE=0 CURRENT_ISSUE=7
CRITIC_FINDINGS_LEDGER='[{"id":"F1","severity":"BLOCK","category":"scope","location":"x:1","evidence":"stale finding","status":"open"}]'
if run_quality_gates >/dev/null 2>&1; then fail 'gates passed'; fi
chmod 600 .verification-7/runtime/cache
[[ "$GATE_NOTE" == "Correction could not be committed"* && "$GATE_NOTE" != *'stale finding'* ]] || fail "misleading gate note: $GATE_NOTE"
[[ "$(receipt_class "$GATE_NOTE")" == infrastructure ]] || fail 'unrecorded correction class'
! retryable_failure "$GATE_NOTE" || fail 'unrecorded correction auto-retried over retained local work'
ok 'an unrecordable correction blocks with its own reason, keeps its work, and never shows stale findings'
