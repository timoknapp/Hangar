#!/usr/bin/env bash
# Block 4a: a deliberate implementer stop waits on squad:needs-decision (not
# squad:failed), frees the queue for dispatchers, and only an answer from the
# issue author or an approver re-queues it. GitHub is a fixture.
# shellcheck disable=SC2016,SC2034,SC2317
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export GITHUB_OWNER=example GITHUB_REPO=repo REPO_BRANCH=main WORKSPACE_DIR="$TMP/repo" LOOP_STATE_DIR="$TMP/state"
# shellcheck source=/dev/null
source "$ROOT/worker/worker-loop.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "PASS: $*"; }
mkdir -p "$WORKSPACE_DIR"
CALLS="$TMP/calls"; : >"$CALLS"
LOOP_MANUAL_ISSUE_CREATORS='["Approver"]'
LABELS='["squad","implementation-approved","squad:processing"]'
COMMENTS='[]'
EDIT_FAILS=false COMMENTS_FAIL=false
gh() {
  printf '%s\n' "$*" >>"$CALLS"
  case "$1 $2" in
    'issue edit')
      [[ "$EDIT_FAILS" != true ]] || return 1
      local op='' a
      for a in "${@:3}"; do
        case "$op" in
          --add-label) LABELS=$(jq -c --arg v "$a" '. + [$v] | unique' <<<"$LABELS") ;;
          --remove-label) LABELS=$(jq -c --arg v "$a" 'map(select(. != $v))' <<<"$LABELS") ;;
        esac
        op="$a"
      done ;;
    'issue comment') COMMENTS=$(jq -c --arg b "${*: -1}" '. + [{user:{login:"worker[bot]",type:"Bot"},body:$b}]' <<<"$COMMENTS") ;;
    'issue view') [[ "$*" == *'--jq .author.login'* ]] && echo Reporter ;;
    'issue list') jq -n --argjson l "$LABELS" '[{number:7,labels:($l|map({name:.}))}]' ;;
    'api --paginate') [[ "$COMMENTS_FAIL" != true ]] || return 1; printf '%s\n' "$COMMENTS" ;;
    *) fail "unexpected gh: $*" ;;
  esac
}
claim_owned() { return 0; }
release_issue_claim() { printf 'release\n' >>"$CALLS"; CURRENT_CLAIM_REF=""; }
say() { COMMENTS=$(jq -c --arg u "$1" --arg t "$2" --arg b "$3" '. + [{user:{login:$u,type:$t},body:$b}]' <<<"$COMMENTS"); }
has() { jq -e --arg v "$1" 'index($v) != null' <<<"$LABELS" >/dev/null; }

# --- a deliberate stop parks the issue for a decision ---
CURRENT_ISSUE=7 CURRENT_CLAIM_REF=refs/heads/squad-claims/issue-7 TASK_KIND=issue TASK_STAGE=implement TASK_STARTED_AT=$(date +%s) TASK_CREDITS=40
PR_EXECUTIVE_SUMMARY=$'## Problem\nBlocked: which export format should win, CSV or JSON?'
finalize_no_commit_issue 7 false 0
has squad:needs-decision || fail 'not waiting on needs-decision'
if has squad:failed || has squad || has squad:processing; then fail "wrong labels: $LABELS"; fi
has implementation-approved || fail 'approval label touched'
grep -q '^release$' "$CALLS" || fail 'claim not released'
[[ -z "$CURRENT_ISSUE" ]] || fail 'issue still owned'
jq -e 'map(.body) | any(contains("CSV or JSON")) and any(contains("<!-- hangar-needs-decision -->")) and
  any(contains("\"outcome\":\"no-change\",\"class\":\"decision\""))' <<<"$COMMENTS" >/dev/null || fail 'rationale, marker or receipt missing'
[[ -z "$(select_next_unclaimed_issue "[{\"number\":7,\"labels\":$(jq -c 'map({name:.}) + [{name:"squad"}]' <<<"$LABELS")}]")" ]] ||
  fail 'needs-decision issue still selectable'
ok 'a deliberate stop waits on squad:needs-decision with rationale and receipt, frees squad, keeps approval'

# --- only an authorized human answer re-queues ---
say someone-else User 'I think CSV.'
say helper[bot] Bot 'Bot says: re-queue please.'
requeue_answered_decisions
if has squad || ! has squad:needs-decision; then fail 'bot or stranger re-queued'; fi
say Reporter User 'CSV, keep JSON for the API.'
requeue_answered_decisions
if ! has squad || has squad:needs-decision; then fail "author answer did not re-queue: $LABELS"; fi
ctx=$(decision_context 7)
[[ "$ctx" == *'[Reporter] CSV, keep JSON for the API.'* && "$ctx" != *'someone-else'* && "$ctx" != *'Bot says'* ]] ||
  fail "decision context wrong: $ctx"
ok 'only the issue author or an approver re-queues, and only their answers reach the next prompt'

# --- an approver answers; answers before the latest request never count ---
LABELS='["squad","implementation-approved","squad:processing"]'; CURRENT_CLAIM_REF=refs/heads/squad-claims/issue-7
park_for_decision 7 'The implementer stopped without changes and needs a decision'
requeue_answered_decisions
has squad:needs-decision || fail 'answer to an older request re-queued a new one'
say APPROVER User 'Go with option B.'
requeue_answered_decisions
has squad || fail 'approver (case-insensitive) answer did not re-queue'
[[ "$(decision_context 7)" == *'option B'* && "$(decision_context 7)" != *'CSV'* ]] || fail 'stale answers leaked into context'
ok 'approvers count case-insensitively; answers to an earlier request never re-queue a newer one'

# --- unreadable history or failed label write fail closed ---
LABELS='["squad:needs-decision"]' COMMENTS_FAIL=true
requeue_answered_decisions
[[ "$LABELS" == '["squad:needs-decision"]' ]] || fail 'unreadable comments re-queued'
COMMENTS_FAIL=false
LABELS='["squad","implementation-approved","squad:processing"]'; CURRENT_CLAIM_REF=refs/heads/squad-claims/issue-7; EDIT_FAILS=true
cleanup_issue() { printf 'cleanup %s\n' "$3" >>"$CALLS"; }
park_for_decision 7 'The implementer stopped without changes and needs a decision'
grep -q '^cleanup The implementer stopped' "$CALLS" || fail 'failed label write left the claim dangling'
[[ "$(receipt_class 'The implementer stopped without changes and needs a decision')" == decision ]] || fail 'class'
ok 'unreadable comment history never re-queues; a failed label write falls back to the terminal block'
