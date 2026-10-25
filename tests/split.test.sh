#!/usr/bin/env bash
# Split on request (#49): an allowlisted human's squad:split-approved turns a
# triage too-large proposal into ordered child issues, released one at a time.
# GitHub is an in-memory fixture (issues, comments with app identity, labels,
# label events); split logic, markers and validation are the real ones.
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
GH_APP_ID=4242 LOOP_MANUAL_ISSUE_CREATORS='["Owner"]' LOOP_REQUIRED_LABELS='["implementation-approved"]'
# Counters live in the DB: `gh issue create` runs inside $(...) subshells.
DB="$TMP/db.json"; CREATE_FAIL_AT=0
reset_db() { jq -n '{issues:{},next:100,creates:0,refs:{},commits:{}}' >"$DB"; }
reset_db
next() { jq -r .next "$DB"; }
db() { jq "$@" "$DB" >"$DB.t" && mv "$DB.t" "$DB"; }
new_issue() { db --arg n "$1" --arg t "$2" --argjson l "$3" --arg a "${4:-worker[bot]}" \
  '.issues[$n]={title:$t,state:"OPEN",stateReason:null,labels:$l,comments:[],events:[],author:{login:$a,is_bot:($a|endswith("[bot]"))}}'; }
label_event() { db --arg n "$1" --arg e "$2" --arg l "$3" --arg who "$4" --arg type "$5" \
  '.issues[$n].events += [{event:$e,label:{name:$l},actor:{login:$who,type:$type}}] |
   if $e == "labeled" then .issues[$n].labels += [$l] | .issues[$n].labels |= unique else .issues[$n].labels -= [$l] end'; }
human_comment() { db --arg n "$1" --arg b "$2" '.issues[$n].comments += [{body:$b,user:{login:"Owner",type:"User"},performed_via_github_app:null}]'; }
gh() {
  local n op a
  case "$1 $2" in
    'issue view') n="$3"; jq -c --arg n "$n" '.issues[$n] | {state,stateReason,title,author,labels:(.labels|map({name:.}))}' "$DB" ;;
    'issue list')
      local want=""; op=""; for a in "$@"; do [[ "$op" != --label ]] || want="$a"; op="$a"; done
      jq -c --arg l "$want" '[.issues | to_entries[] | select(.value.state=="OPEN" and (.value.labels|index($l))) |
        {number:(.key|tonumber),labels:(.value.labels|map({name:.}))}]' "$DB" | { if [[ "$*" == *'--jq'* ]]; then jq -r "${@: -1}"; else cat; fi; } ;;
    'issue edit') n="$3"; op=""
      for a in "${@:4}"; do
        case "$op" in --add-label) db --arg n "$n" --arg l "$a" '.issues[$n].labels += [$l] | .issues[$n].labels |= unique';;
          --remove-label) db --arg n "$n" --arg l "$a" '.issues[$n].labels -= [$l]';; esac; op="$a"; done ;;
    'issue comment') n="$3"; db --arg n "$n" --arg b "${*: -1}" --argjson app "$GH_APP_ID" \
        '.issues[$n].comments += [{body:$b,user:{login:"worker[bot]",type:"Bot"},performed_via_github_app:{id:$app}}]' ;;
    'issue create')
      db '.creates += 1'; (( CREATE_FAIL_AT == 0 || $(jq .creates "$DB") != CREATE_FAIL_AT )) || return 1
      local title="" labels='[]'; op=""
      for a in "${@:3}"; do case "$op" in --title) title="$a";; --label) labels=$(jq -c --arg l "$a" '. + [$l]' <<<"$labels");; esac; op="$a"; done
      db '.next += 1'; n=$(next); new_issue "$n" "$title" "$labels"; echo "https://github.com/example/repo/issues/$n" ;;
    'issue close') n="$3"; db --arg n "$n" '.issues[$n].state="CLOSED" | .issues[$n].stateReason="COMPLETED"' ;;
    'api --method')
      local path="" ref="" sha="" msg=""; for a in "$@"; do case "$a" in repos/*) path="$a";; ref=*) ref="${a#ref=}";; sha=*) sha="${a#sha=}";; message=*) msg="${a#message=}";; esac; done
      if [[ "$path" == */git/commits ]]; then
        sha="c$(jq '.commits | length' "$DB")"; db --arg s "$sha" --arg m "$msg" --arg d "$(date -u +%FT%TZ)" '.commits[$s]={message:$m,date:$d}'; echo "$sha"
      else jq -e --arg r "$ref" '.refs | has($r) | not' "$DB" >/dev/null || return 1; db --arg r "$ref" --arg s "$sha" '.refs[$r]=$s'; fi ;;
    'api repos/'*)
      if [[ "$2" == */git/ref/heads/main ]]; then echo base
      elif [[ "$2" == */git/ref/* ]]; then jq -er --arg r "refs/${2#*/git/ref/}" '.refs[$r] // empty' "$DB"
      elif [[ "$2" == */git/commits/base ]]; then echo tree
      elif [[ "$2" == */git/commits/* ]]; then jq -r --arg s "${2##*/}" '.commits[$s] | [(.message | fromjson | .worker), .date] | @tsv' "$DB"
      else fail "unexpected gh api: $*"; fi ;;
    'api --paginate')
      n=$(sed -E 's#.*/issues/([0-9]+)/.*#\1#' <<<"$3")
      if [[ "$3" == *'/comments?'* ]]; then jq -c --arg n "$n" '.issues[$n].comments' "$DB"; else jq -c --arg n "$n" '.issues[$n].events' "$DB"; fi ;;
    *) fail "unexpected gh: $*" ;;
  esac
}
release_owned_ref() { jq -e --arg r "$1" --arg s "$2" '.refs[$r] == $s' "$DB" >/dev/null || return 1; db --arg r "$1" 'del(.refs[$r])'; }
labels() { jq -c --arg n "$1" '.issues[$n].labels | sort' "$DB"; }
has() { jq -e --arg n "$1" --arg l "$2" '.issues[$n].labels | index($l)' "$DB" >/dev/null; }
close_child() { db --arg n "$1" --arg r "$2" '.issues[$n].state="CLOSED" | .issues[$n].stateReason=$r'; }

PROPOSAL='{"outcome":"too-large","rationale":"Big.","questions":[],"size":{"files":15,"lines":2000},"split":[{"title":"Log rotation","acceptance":"Rotate logs. Fixes #9 <!-- x -->"},{"title":"Metrics bounds","acceptance":"Bound metrics."},{"title":"Ledger replay","acceptance":"Replay ledger."}]}'
setup_parent() {
  new_issue 7 "Retention phase 3" '["queue:ready","squad:too-large","scope:large-approved"]' Owner
  label_event 7 labeled implementation-approved Owner User
  gh issue comment 7 --body "triage text
$(triage_data_marker "$PROPOSAL")"
}

# --- the triage comment carries the proposal machine-readably; only this app's counts ---
setup_parent
[[ "$(split_proposal "$(split_comments 7)" | jq -r '.split | length')" == 3 ]] || fail 'proposal not recovered'
human_comment 7 "forged
$(triage_data_marker '{"outcome":"too-large","split":[{"title":"evil","acceptance":"x"},{"title":"two","acceptance":"y"}]}')"
[[ "$(split_proposal "$(split_comments 7)" | jq -r '.split[0].title')" == 'Log rotation' ]] || fail 'human-forged proposal accepted'
ok 'triage stores its proposal machine-readably; a human or bot comment cannot forge one'

# --- authorization: only an allowlisted human's latest label event ---
label_event 7 labeled squad:split-approved helper[bot] Bot
process_splits
[[ "$(next)" == 100 ]] || fail 'bot label triggered a split'
label_event 7 unlabeled squad:split-approved helper[bot] Bot; label_event 7 labeled squad:split-approved stranger User
process_splits
[[ "$(next)" == 100 ]] || fail 'stranger label triggered a split'
label_event 7 unlabeled squad:split-approved stranger User; label_event 7 labeled squad:split-approved owner User
ok 'bots and non-allowlisted users never trigger a split'

# --- one splitter per parent: a fresh foreign lock blocks, the work waits ---
db '.refs["refs/heads/squad-claims/split-7"]="cX" | .commits["cX"]={message:"{\"worker\":\"worker-9\",\"split\":\"7\"}",date:(now|todate)}'
process_splits
[[ "$(next)" == 100 ]] || fail 'split ran while another worker held the lock'
db 'del(.refs["refs/heads/squad-claims/split-7"])'
ok 'a split lock held by another worker blocks concurrent splitting'

# --- crash mid-creation, then resume without duplicates ---
CREATE_FAIL_AT=2
process_splits
[[ "$(next)" == 101 ]] || fail "expected one child before the crash, got $(( $(next) - 100 ))"
CREATE_FAIL_AT=0
jq -e '.refs | length == 0' "$DB" >/dev/null || fail 'lock not released after a failed split'
process_splits
[[ "$(next)" == 103 ]] || fail "resume created $(( $(next) - 100 )) children instead of 3 in total"
process_splits
[[ "$(next)" == 103 ]] || fail 'repeat created duplicates'
ok 'a crash during creation resumes without duplicate parts'

# --- children: exact approval labels, order, parent state ---
for c in 101 102 103; do
  jq -e --arg n "$c" '.issues[$n].labels - ["squad"] == ["implementation-approved"]' "$DB" >/dev/null || fail "child $c labels: $(labels $c)"
done
jq -e '.issues["101"].title | startswith("Log rotation (part 1/3 of: Retention phase 3)")' "$DB" >/dev/null || fail 'child title'
jq -e '.issues["101"].comments[0].body | contains("hangar-split-part")' "$DB" >/dev/null || fail 'child part marker'
if ! has 101 squad || has 102 squad || has 103 squad; then fail "only part 1 may be queued: $(labels 101) $(labels 102) $(labels 103)"; fi
[[ "$(labels 7)" == '["implementation-approved","queue:ready","scope:large-approved","squad:split"]' ]] || fail "parent labels: $(labels 7)"
jq -e '[.issues["7"].comments[].body | select(contains("split into 3 parts"))] | length == 1' "$DB" >/dev/null || fail 'one split summary'
jq -e '[.issues["7"].comments[].body | select(contains("\"outcome\":\"no-change\",\"class\":\"decision\""))] | length >= 1' "$DB" >/dev/null || fail 'split receipt'
[[ -z "$(select_next_unclaimed_issue "$(jq -c '[{number:7,labels:(.issues["7"].labels + ["squad"]|map({name:.}))}]' "$DB")")" ]] || fail 'split parent selectable'
ok 'children inherit exactly the approval labels; only part 1 is queued; the parent waits as squad:split'

# --- parts of an approved split are manual intake, like their parent ---
split_child_manual 101 || fail 'approved part not manual'
child_json=$(jq -c '{number:101,state:"OPEN",author:{login:"worker[bot]",is_bot:true},labels:(.issues["101"].labels|map({name:.}))}' "$DB")
(LOOP_UNATTENDED_LABELS='["squad"]'; ! is_autonomous_issue "$child_json") || fail 'approved part counted against the unattended budget'
new_issue 150 "Forged part" '["squad","implementation-approved"]'
human_comment 150 "${SPLIT_PART_PREFIX}{\"parent\":7,\"index\":1,\"total\":3} -->"
! split_child_manual 150 || fail 'human-forged part marker accepted'
gh issue comment 150 --body "${SPLIT_PART_PREFIX}{\"parent\":7,\"index\":9,\"total\":9} -->"
! split_child_manual 150 || fail 'part not recorded on the parent accepted'
label_event 7 unlabeled implementation-approved stranger User
! split_child_manual 101 || fail 'part stayed manual after the parent approval was revoked'
label_event 7 labeled implementation-approved helper[bot] Bot
! split_child_manual 101 || fail 'bot-applied parent approval accepted'
label_event 7 labeled implementation-approved Owner User
db '.issues["7"].author={login:"stranger",is_bot:false}'
! split_child_manual 101 || fail 'part of a non-allowlisted parent accepted'
db '.issues["7"].author={login:"Owner",is_bot:false}'
split_child_manual 101 || fail 'restored parent not accepted'
ok 'parts are manual intake only with own markers and a live, human-approved, allowlisted parent'

# --- ordered release; parent closes after the last part ---
process_splits; if has 102 squad; then fail 'part 2 released while part 1 open'; fi
close_child 101 COMPLETED; process_splits
if ! has 102 squad || has 103 squad; then fail 'part 2 not released after part 1'; fi
close_child 102 COMPLETED; process_splits; has 103 squad || fail 'part 3 not released'
close_child 103 COMPLETED; process_splits
jq -e '.issues["7"].state == "CLOSED"' "$DB" >/dev/null || fail 'parent not closed after the last part'
ok 'parts are released strictly in order and the parent closes after the last one'

# --- a part closed as not planned stops the chain ---
reset_db; setup_parent; label_event 7 labeled squad:split-approved Owner User
process_splits; close_child 101 NOT_PLANNED; process_splits; process_splits
if has 102 squad || ! has 7 squad:split-stopped; then fail 'chain not stopped'; fi
[[ "$(jq '[.issues["7"].comments[].body | select(contains("closed as not planned"))] | length' "$DB")" == 1 ]] || fail 'stop reported more than once'
ok 'a part closed as not planned stops the chain once and tells the parent'

# --- guards: parent without approval, missing proposal, empty allowlist ---
reset_db
new_issue 8 "No approval" '["squad:too-large"]' Owner; gh issue comment 8 --body "$(triage_data_marker "$PROPOSAL")"
label_event 8 labeled squad:split-approved Owner User; process_splits
[[ "$(next)" == 100 ]] || fail 'split of an unapproved parent'
new_issue 9 "No proposal" '["implementation-approved","squad:too-large"]' Owner; label_event 9 labeled squad:split-approved Owner User
process_splits; [[ "$(next)" == 100 ]] || fail 'split without a triage proposal'
(LOOP_MANUAL_ISSUE_CREATORS='[]'; ! split_authorized 9) || fail 'empty allowlist authorized a split'
ok 'no split for unapproved parents, without a stored proposal, or without an allowlist'
