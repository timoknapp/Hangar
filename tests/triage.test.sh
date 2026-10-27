#!/usr/bin/env bash
# Block 4b: opt-in read-only triage. The validator is strict, the publisher (not
# the model) enforces size limits, triage can only hold work back, never
# approve, and invalid output is an infrastructure failure, never "implement".
# Model and GitHub are fixtures; validator, policy and run_triage are real.
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
wrap() { printf 'TRIAGE_JSON_BEGIN\n%s\nTRIAGE_JSON_END\n' "$1"; }
GOOD='{"outcome":"implement","rationale":"Clear and small.","questions":[],"size":{"files":3,"lines":120},"split":[]}'

# --- validator: exactly one well-formed object, nothing else counts ---
validate_triage "$(wrap "$GOOD")" >/dev/null || fail 'valid triage rejected'
for bad in '' 'implement' '{}' '[]' 'null' \
  '{"outcome":"implement","rationale":"x","questions":[],"size":{"files":1,"lines":1}}' \
  '{"outcome":"implement","rationale":"x","questions":[],"size":{"files":1,"lines":1},"split":[],"approve":true}' \
  '{"outcome":"approve","rationale":"x","questions":[],"size":{"files":1,"lines":1},"split":[]}' \
  '{"outcome":"implement","rationale":"","questions":[],"size":{"files":1,"lines":1},"split":[]}' \
  '{"outcome":"needs-info","rationale":"x","questions":["a","b","c","d","e","f"],"size":{"files":1,"lines":1},"split":[]}' \
  '{"outcome":"needs-info","rationale":"x","questions":[],"size":{"files":1,"lines":1},"split":[]}' \
  '{"outcome":"too-large","rationale":"x","questions":[],"size":{"files":40,"lines":4000},"split":[{"title":"a","acceptance":"b"}]}' \
  '{"outcome":"implement","rationale":"x","questions":[],"size":{"files":1.5,"lines":1},"split":[]}' \
  '{"outcome":"implement","rationale":"x","questions":[],"size":{"files":-1,"lines":1},"split":[]}' \
  '{"outcome":"implement","rationale":"x","questions":[],"size":{"files":"3","lines":1},"split":[]}'; do
  if validate_triage "$(wrap "$bad")" >/dev/null 2>&1; then fail "accepted: ${bad:-<empty>}"; fi
done
if validate_triage "$GOOD" >/dev/null 2>&1; then fail 'unmarked JSON accepted'; fi
if validate_triage "$(wrap "$GOOD")$(wrap "$GOOD")" >/dev/null 2>&1; then fail 'two blocks accepted'; fi
validate_triage "$(printf 'Sure!\n%s\nLet me know.' "$(wrap "$GOOD")")" >/dev/null || fail 'prose outside the block must not matter'
if validate_triage "$(printf 'TRIAGE_JSON_BEGIN\nSure: %s\nTRIAGE_JSON_END' "$GOOD")" >/dev/null 2>&1; then fail 'prose inside the block accepted'; fi
ok 'validator: missing, empty, malformed, extra fields, >5 questions, unknown outcome and prose inside the block are rejected'

# Transport: only the final main-agent message of a successful run counts.
# Regression: text mode wrapped a long rationale inside the JSON string.
LONG=$(jq -c '.rationale = ("word " * 80)' <<<"$GOOD")
ev="$TMP/events"
{ printf 'not json warning line\n'; jq -cn --arg c "$(wrap "$LONG")" '{type:"assistant.message",data:{content:"draft",toolRequests:[{name:"view"}]}},
    {type:"assistant.message",agentId:"sub-1",data:{content:"subagent"}},
    {type:"assistant.message",data:{content:$c,toolRequests:[]}}, {type:"result",exitCode:0}'; } >"$ev"
validate_triage "$(triage_final_text "$ev")" >/dev/null || fail 'long rationale lost in transport'
jq -c 'select(.type != "result")' "$ev" >"$ev.2" 2>/dev/null || true
[[ -z "$(triage_final_text "$ev.2")" ]] || fail 'answer accepted without a successful result event'
jq -cn '{type:"assistant.message",agentId:"sub-1",data:{content:"x",toolRequests:[]}}, {type:"result",exitCode:0}' >"$ev.3"
[[ -z "$(triage_final_text "$ev.3")" ]] || fail 'subagent message accepted as the answer'
ok 'transport: final main-agent message of a successful JSON event stream only; long lines survive'

# --- publisher policy: limits and override are enforced here, not by the model ---
ISSUE='{"number":7,"title":"T","body":"B","state":"OPEN","author":{"login":"Reporter","is_bot":false},"labels":[{"name":"squad"},{"name":"squad:processing"}]}'
BIG='{"outcome":"implement","rationale":"Fine.","questions":[],"size":{"files":30,"lines":200},"split":[]}'
[[ "$(triage_decide "$GOOD" "$ISSUE")" == implement ]] || fail 'small implement changed'
[[ "$(triage_decide "$BIG" "$ISSUE")" == too-large ]] || fail 'oversized implement not held'
[[ "$(LOOP_TRIAGE_MAX_FILES=50 triage_decide "$BIG" "$ISSUE")" == implement ]] || fail 'configured limit ignored'
OVR=$(jq -c '.labels += [{name:"scope:large-approved"}]' <<<"$ISSUE")
[[ "$(triage_decide "$BIG" "$OVR")" == implement ]] || fail 'override label ignored'
PARK='{"outcome":"park","rationale":"Duplicate of an open issue.","questions":[],"size":{"files":1,"lines":1},"split":[]}'
[[ "$(triage_decide "$PARK" "$OVR")" == park ]] || fail 'override must not turn other holds into implement'
c=$(triage_comment '{"outcome":"too-large","rationale":"Fixes #12 <!-- x -->","questions":[],"size":{"files":40,"lines":4000},"split":[{"title":"A","acceptance":"a"},{"title":"B","acceptance":"b"}]}' too-large)
[[ "$c" == *'Fixes issue #12'* && "$c" != *'<!--'* && "$c" == *'**A**: a'* && "$c" == *'scope:large-approved'* ]] || fail "comment not sanitized: $c"
ok 'publisher enforces size limits and the override; comment text cannot close issues or inject markers'

# --- run_triage: holds work back with labels, never approves; invalid = infrastructure ---
LABELS='["squad","implementation-approved","squad:processing"]'; CALLS="$TMP/calls"; : >"$CALLS"; MODEL_OUT=""; MODEL_RC=0
gh() {
  printf '%s\n' "$*" >>"$CALLS"
  case "$1 $2" in
    'issue edit') local op='' a; for a in "${@:3}"; do
        case "$op" in --add-label) LABELS=$(jq -c --arg v "$a" '. + [$v] | unique' <<<"$LABELS");;
          --remove-label) LABELS=$(jq -c --arg v "$a" 'map(select(. != $v))' <<<"$LABELS");; esac; op="$a"; done ;;
    'issue comment'|'issue view') [[ "$*" != *'.author.login'* ]] || echo Reporter ;;
    'api --paginate') echo '[]' ;;
    *) fail "unexpected gh: $*" ;;
  esac
}
# Copilot CLI JSON event stream: the final main-agent message carries the answer.
events() {
  jq -cn --arg c "$1" '{type:"user.message",data:{interactionId:"i"}}, {type:"assistant.message",data:{model:"m",content:$c,toolRequests:[]}},
    {type:"result",exitCode:0}'
}
run_agent_copilot() {
  printf '%s\n' "$*" >>"$TMP/model-args"
  [[ " $* " == *' --deny-tool=write '* && " $* " == *' --deny-tool=shell '* ]] || fail 'triage session not read-only'
  [[ " $* " == *' --output-format json '* ]] || fail 'triage must use the JSON event transport'
  [[ "$*" == *'size.files MUST count PRIMARY implementation files, not total files'* &&
     "$*" == *"pinned repository's companion-file exclusions"* &&
     "$*" == *'size.lines still includes all changed lines'* ]] || fail 'primary/total estimate contract is ambiguous'
  events "$MODEL_OUT"; return "$MODEL_RC"
}
claim_owned() { return 0; }
release_admission_claim() { printf 'release\n' >>"$CALLS"; }
cleanup_issue() { printf 'cleanup %s\n' "$3" >>"$CALLS"; }
retain_gate_log() { :; }
read_trusted_file() { return 1; }
has() { jq -e --arg v "$1" 'index($v) != null' <<<"$LABELS" >/dev/null; }
COPILOT_PAT=fixture COPILOT_MODEL="" TASK_BRANCH="" TASK_BASE_SHA=""

LOOP_TRIAGE=false; : >"$TMP/model-args"
run_triage 7 "$ISSUE" || fail 'triage off must implement'
[[ ! -s "$TMP/model-args" ]] || fail 'model called while triage is off'

LOOP_TRIAGE=true MODEL_OUT=$(wrap "$GOOD")
run_triage 7 "$ISSUE" || fail 'implement held back'
[[ "$(jq -c sort <<<"$LABELS")" == '["implementation-approved","squad","squad:processing"]' ]] || fail "implement changed labels: $LABELS"

MODEL_OUT=$(wrap '{"outcome":"needs-info","rationale":"Unclear target.","questions":["Which export format?"],"size":{"files":2,"lines":50},"split":[]}')
CURRENT_ISSUE=7; if run_triage 7 "$ISSUE"; then fail 'needs-info implemented'; fi
if ! has squad:needs-info || ! has implementation-approved; then fail "needs-info labels: $LABELS"; fi
if has squad || has squad:processing; then fail "queue labels kept: $LABELS"; fi
for want in 'Which export format' 'hangar-needs-decision' '"outcome":"no-change","class":"decision"'; do
  grep -qF "$want" "$CALLS" || fail "missing in triage comment: $want"
done
grep -q '^release$' "$CALLS" || fail 'claim not released'
[[ -z "$CURRENT_ISSUE" ]] || fail 'issue still owned'
if grep -Eq -- '--add-label (implementation-approved|squad:done|squad:revision)' "$CALLS"; then fail 'triage granted approval or completion'; fi

for case in 'not json' "$(wrap '{"outcome":"approve"}')"; do
  LABELS='["squad","implementation-approved","squad:processing"]'; : >"$CALLS"; MODEL_OUT="$case"
  if run_triage 7 "$ISSUE"; then fail "invalid output implemented: $case"; fi
  grep -q '^cleanup Triage output invalid' "$CALLS" || fail 'invalid output not an infrastructure block'
done
[[ "$(receipt_class 'Triage output invalid; no implementation attempted')" == infrastructure ]] || fail 'invalid output class'
: >"$CALLS"; MODEL_OUT=$(wrap "$GOOD") MODEL_RC=3
if run_triage 7 "$ISSUE"; then fail 'crashed triage implemented'; fi
grep -q '^cleanup Triage failed or timed out (exit 3)' "$CALLS" || fail 'crash not blocked'
MODEL_RC=0
ok 'run_triage: opt-in, read-only, holds work with labels and released claim, never approves; invalid or crashed output blocks'

# --- self-generated work is always triaged, with strict eligibility ---
LOOP_TRIAGE=false; : >"$TMP/model-args"; LABELS='["squad","loop:auto","squad:processing"]'
AUTO=$(jq -c '.labels=[{name:"squad"},{name:"loop:auto"},{name:"squad:processing"}] | .author={login:"bot",is_bot:true}' <<<"$ISSUE")
MODEL_OUT=$(wrap "$PARK")
if run_triage 7 "$AUTO"; then fail 'parked auto issue implemented'; fi
grep -q 'generated by the autonomous loop' "$TMP/model-args" || fail 'eligibility gates missing for loop:auto'
has squad:park || fail 'auto issue not parked'
# A deployment counting every squad issue against the unattended budget does not
# make human-approved work "self-generated".
: >"$TMP/model-args"; LABELS='["squad","squad:processing"]'
(LOOP_UNATTENDED_LABELS='["squad"]'; run_triage 7 "$ISSUE") || fail 'unattended budget label triggered triage'
[[ ! -s "$TMP/model-args" ]] || fail 'model called for human-approved work with triage off'
ok 'loop:auto issues are always triaged with the strict eligibility gates'

# --- answers re-queue holds; too-large only with the override label ---
LABELS='["squad:too-large"]'
gh() {
  case "$1 $2" in
    'issue list') if [[ "$*" == *"--label $(jq -r '.[0]' <<<"$LABELS")"* ]]; then jq -n --argjson l "$LABELS" '[{number:7,labels:($l|map({name:.}))}]'; else echo '[]'; fi ;;
    'issue view') echo Reporter ;;
    'api --paginate') printf '[{"user":{"login":"x","type":"Bot"},"body":"%s"},{"user":{"login":"Reporter","type":"User"},"body":"Split is fine, do it in one."}]\n' "$DECISION_MARKER" ;;
    'issue edit') LABELS='["requeued"]' ;;
  esac
}
requeue_answered_decisions
[[ "$LABELS" == '["squad:too-large"]' ]] || fail 'too-large re-queued without override'
LABELS='["squad:too-large","scope:large-approved"]'; requeue_answered_decisions
[[ "$LABELS" == '["requeued"]' ]] || fail 'too-large with override and answer not re-queued'
LABELS='["squad:needs-info"]'; requeue_answered_decisions
[[ "$LABELS" == '["requeued"]' ]] || fail 'answered needs-info not re-queued'
[[ -z "$(select_next_unclaimed_issue '[{"number":7,"labels":[{"name":"squad"},{"name":"squad:park"}]}]')" ]] || fail 'parked issue selectable'
ok 'answers re-queue needs-info/needs-spec; too-large needs the override; held issues are never selected'

LOOP_TRIAGE=maybe; if validate_triage_policy 2>/dev/null; then fail 'invalid policy accepted'; fi
LOOP_TRIAGE=true LOOP_TRIAGE_OVERRIDE_LABEL=squad:done; if validate_triage_policy 2>/dev/null; then fail 'squad override accepted'; fi
ok 'invalid triage policy fails closed at startup'
