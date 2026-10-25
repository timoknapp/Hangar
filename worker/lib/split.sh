# shellcheck shell=bash disable=SC2034  # sets task globals owned by worker-loop.sh
# Split on request (follow-up to ADR 0001 block 4). Triage holds an oversized
# issue as squad:too-large with a validated split proposal. A human allowlisted
# in manualIssueCreators adds squad:split-approved; a free worker then creates
# one child issue per part from that stored proposal (no model call). The human
# label is the approval for exactly these parts, so children inherit the
# parent's required approval labels. Parts run strictly in order: only one
# child carries `squad` at a time; the parent closes after the last part.
# Repository-specific queues (backlog files, dispatchers) are not edited.

SPLIT_LABEL=squad:split-approved
SPLIT_PARENT_LABEL=squad:split
TRIAGE_DATA_PREFIX='<!-- hangar-triage-data '
SPLIT_MARKER_PREFIX='<!-- hangar-split '
SPLIT_PART_PREFIX='<!-- hangar-split-part '

# Machine-readable triage proposal, embedded in the publisher's own comment.
# Base64 keeps arbitrary text from terminating the HTML comment.
triage_data_marker() {
  printf '%s%s -->\n' "$TRIAGE_DATA_PREFIX" "$(jq -c '{outcome, split}' <<<"$1" | base64 -w0)"
}

# All comments of an issue (bounded), oldest first; fails closed.
split_comments() {
  gh api --paginate "repos/${REPO_SLUG}/issues/$1/comments?per_page=100" | jq -s 'add // [] | .[-300:]'
}

# Only comments written by this worker's GitHub App count as publisher data.
split_own() {
  jq --arg app "${GH_APP_ID:-}" '[.[] | select($app != "" and ((.performed_via_github_app.id // "") | tostring) == $app)]'
}

# The latest split proposal from this publisher, revalidated; empty if none.
split_proposal() {
  local comments="$1" raw json
  raw=$(split_own <<<"$comments" | jq -r --arg p "$TRIAGE_DATA_PREFIX" '
    [.[] | .body // "" | split("\n")[] | select(startswith($p)) | ltrimstr($p) | rtrimstr(" -->")] | last // empty') || return 1
  [[ -n "$raw" ]] || return 0
  json=$(base64 -d <<<"$raw" 2>/dev/null) || return 1
  jq -ce 'select(.outcome == "too-large" and (.split | type == "array" and length >= 2 and length <= 8) and
    all(.split[]; (keys | sort) == ["acceptance","title"] and (.title | type == "string" and length > 0 and length <= 200) and
      (.acceptance | type == "string" and length > 0 and length <= 1000)))' <<<"$json"
}

# Child numbers already recorded on the parent (index -> number), from own markers.
split_recorded() {
  split_own <<<"$1" | jq -c --arg p "$SPLIT_MARKER_PREFIX" '
    [.[] | .body // "" | split("\n")[] | select(startswith($p)) | ltrimstr($p) | rtrimstr(" -->") |
      (try fromjson catch null) | select(type == "object" and (.index | type == "number") and (.issue | type == "number"))] |
    map({key: (.index | tostring), value: .issue}) | from_entries'
}

# The last split-approved label event must be by an allowlisted human.
split_authorized() {
  local issue="$1" events
  [[ "$(jq length <<<"$LOOP_MANUAL_ISSUE_CREATORS")" -gt 0 ]] || return 1
  events=$(gh api --paginate "repos/${REPO_SLUG}/issues/${issue}/events?per_page=100" | jq -s 'add // []') || return 1
  jq -e --arg label "$SPLIT_LABEL" --argjson creators "$LOOP_MANUAL_ISSUE_CREATORS" '
    [.[] | select((.event == "labeled" or .event == "unlabeled") and .label.name == $label)] | last as $e |
    $e != null and $e.event == "labeled" and $e.actor.type == "User" and
    ($creators | map(ascii_downcase) | index($e.actor.login | ascii_downcase)) != null' <<<"$events" >/dev/null
}

split_child_body() {
  local parent="$1" index="$2" total="$3" part="$4"
  jq -r --arg parent "$parent" --arg index "$index" --arg total "$total" '
    def esc: gsub("<"; "&lt;");
    "Part \($index)/\($total) of #\($parent).\n\n## Acceptance criteria\n\n\(.acceptance | esc)\n\n" +
    "Split from #\($parent) on request; the parts run in order. Scope is limited to this part."' <<<"$part"
}

# One splitter per parent across workers: an atomic ref create is the lock.
# The holder (or a lock older than SPLIT_LOCK_STALE seconds, e.g. a crashed
# worker) proceeds; markers on the parent make the work itself idempotent.
SPLIT_LOCK_STALE="${SPLIT_LOCK_STALE:-1800}"
SPLIT_LOCK_REF="" SPLIT_LOCK_OID=""
split_lock() {
  local issue="$1" ref="refs/heads/squad-claims/split-$1" base tree oid owner when
  SPLIT_LOCK_REF="" SPLIT_LOCK_OID=""
  base=$(gh api "repos/${REPO_SLUG}/git/ref/heads/${DEFAULT_BRANCH}" --jq '.object.sha') || return 1
  tree=$(gh api "repos/${REPO_SLUG}/git/commits/${base}" --jq '.tree.sha') || return 1
  oid=$(gh api --method POST "repos/${REPO_SLUG}/git/commits" -f tree="$tree" -f "parents[]=$base" \
    -f message="$(jq -cn --arg w "$WORKER_ID" --arg i "$issue" '{worker:$w,split:$i}')" --jq .sha) || return 1
  if ! gh api --method POST "repos/${REPO_SLUG}/git/refs" -f ref="$ref" -f sha="$oid" >/dev/null 2>&1; then
    owner=$(gh api "repos/${REPO_SLUG}/git/ref/${ref#refs/}" --jq '.object.sha') || return 1
    when=$(gh api "repos/${REPO_SLUG}/git/commits/${owner}" --jq '[(.message | fromjson? | .worker // ""), .committer.date] | @tsv') || return 1
    if [[ "${when%%$'\t'*}" != "$WORKER_ID" ]] &&
       (( $(date +%s) - $(date -d "${when#*$'\t'}" +%s 2>/dev/null || echo 0) < SPLIT_LOCK_STALE )); then
      return 1
    fi
    # Own (resume after a crash) or stale: take it over with a lease on the seen value.
    release_owned_ref "$ref" "$owner" || return 1
    gh api --method POST "repos/${REPO_SLUG}/git/refs" -f ref="$ref" -f sha="$oid" >/dev/null 2>&1 || return 1
  fi
  SPLIT_LOCK_REF="$ref" SPLIT_LOCK_OID="$oid"
}
split_unlock() {
  [[ -n "$SPLIT_LOCK_REF" ]] || return 0
  release_owned_ref "$SPLIT_LOCK_REF" "$SPLIT_LOCK_OID" || log_error "Split lock ${SPLIT_LOCK_REF} not released; it expires"
  SPLIT_LOCK_REF="" SPLIT_LOCK_OID=""
}

# Create missing children (idempotent), then record the parent state.
perform_split() {
  local issue="$1"
  split_lock "$issue" || return 0   # another worker is splitting it
  local rc=0
  split_locked "$issue" || rc=$?
  split_unlock
  return "$rc"
}

split_locked() {
  local issue="$1" issue_json comments proposal recorded total i part title body child label created=0
  local -a args=()
  # Re-read under the lock: a sibling may already have finished this split.
  issue_json=$(gh issue view "$issue" --repo "$REPO_SLUG" --json state,title,labels) || return 1
  jq -e --arg l "$SPLIT_LABEL" '.state == "OPEN" and ([.labels[].name] | index($l))' <<<"$issue_json" >/dev/null || return 0
  split_authorized "$issue" || { log "Split of #${issue} not authorized; ignoring ${SPLIT_LABEL}"; return 0; }
  comments=$(split_comments "$issue") || return 1
  proposal=$(split_proposal "$comments") || return 1
  if [[ -z "$proposal" ]]; then
    log_error "Split of #${issue} requested but no valid triage proposal from this publisher"; return 0
  fi
  recorded=$(split_recorded "$comments") || return 1
  total=$(jq '.split | length' <<<"$proposal")
  # Children inherit exactly the parent's approval labels; never queue/status labels.
  if ! jq -e --argjson required "$LOOP_REQUIRED_LABELS" '[.labels[].name] as $n | all($required[]; . as $r | $n | index($r))' \
      <<<"$issue_json" >/dev/null; then
    log_error "Split of #${issue}: parent lacks required approval labels"; return 0
  fi
  while IFS= read -r label; do [[ -n "$label" ]] && args+=(--label "$label"); done < <(jq -r '.[]' <<<"$LOOP_REQUIRED_LABELS")
  for (( i = 1; i <= total; i++ )); do
    jq -e --arg i "$i" 'has($i)' <<<"$recorded" >/dev/null && continue
    part=$(jq -c --argjson i "$i" '.split[$i - 1]' <<<"$proposal")
    title=$(jq -r --arg t "$(jq -r .title <<<"$issue_json")" --argjson i "$i" --argjson n "$total" '"\(.title) (part \($i)/\($n) of: \($t))" | .[0:250]' <<<"$part")
    body=$(split_child_body "$issue" "$i" "$total" "$part")
    child=$(gh issue create --repo "$REPO_SLUG" --title "$title" --body "$body" "${args[@]}") || return 1
    child="${child##*/}"
    [[ "$child" =~ ^[1-9][0-9]*$ ]] || return 1
    # Record before anything else so a crash never duplicates this part.
    gh issue comment "$issue" --repo "$REPO_SLUG" --body "${SPLIT_MARKER_PREFIX}$(jq -cn --argjson index "$i" --argjson issue "$child" '{index:$index,issue:$issue}') -->" >/dev/null || return 1
    gh issue comment "$child" --repo "$REPO_SLUG" --body "${SPLIT_PART_PREFIX}$(jq -cn --argjson parent "$issue" --argjson index "$i" --argjson total "$total" '{parent:$parent,index:$index,total:$total}') -->" >/dev/null || return 1
    recorded=$(jq -c --arg i "$i" --argjson c "$child" '. + {($i): $c}' <<<"$recorded")
    created=$((created + 1))
  done
  gh issue edit "$issue" --repo "$REPO_SLUG" --remove-label squad:too-large --remove-label "$SPLIT_LABEL" \
    --remove-label squad --add-label "$SPLIT_PARENT_LABEL" >/dev/null || return 1
  local list
  list=$(jq -r '[to_entries | sort_by(.key | tonumber)[] | "- #\(.value)"] | join("\n")' <<<"$recorded")
  [[ "$created" -eq 0 ]] || gh issue comment "$issue" --repo "$REPO_SLUG" --body "✂️ Worker ${WORKER_ID}: split into ${total} parts on request. They run in order; this issue closes after the last one.

${list}

$(receipt_marker no-change decision)" >/dev/null || log_error "Could not record the split summary for #${issue}"
  log "Split #${issue} into ${total} parts (${created} created now)"
  advance_split "$issue"
}

# Release the next part once the previous one closed as completed; close the
# parent after the last one. A part closed as not planned stops the chain.
advance_split() {
  local issue="$1" comments recorded total i child state reason
  comments=$(split_comments "$issue") || return 1
  recorded=$(split_recorded "$comments") || return 1
  total=$(jq 'length' <<<"$recorded")
  (( total >= 2 )) || return 0
  for (( i = 1; i <= total; i++ )); do
    child=$(jq -r --arg i "$i" '.[$i] // empty' <<<"$recorded")
    [[ "$child" =~ ^[1-9][0-9]*$ ]] || return 0
    state=$(gh issue view "$child" --repo "$REPO_SLUG" --json state,stateReason,labels) || return 1
    reason=$(jq -r '.stateReason // ""' <<<"$state")
    if jq -e '.state == "OPEN"' <<<"$state" >/dev/null; then
      jq -e '[.labels[].name] | index("squad")' <<<"$state" >/dev/null && return 0
      gh issue edit "$child" --repo "$REPO_SLUG" --add-label squad >/dev/null || return 1
      log "Split #${issue}: released part ${i}/${total} (#${child})"
      return 0
    fi
    if [[ "$reason" != COMPLETED ]]; then
      local parent_labels
      parent_labels=$(gh issue view "$issue" --repo "$REPO_SLUG" --json labels) || return 1
      jq -e '[.labels[].name] | index("squad:split-stopped")' <<<"$parent_labels" >/dev/null && return 0
      gh issue edit "$issue" --repo "$REPO_SLUG" --add-label squad:split-stopped >/dev/null || return 1
      gh issue comment "$issue" --repo "$REPO_SLUG" --body "⏸️ Worker ${WORKER_ID}: part ${i}/${total} (#${child}) was closed as not planned; the remaining parts stay unqueued. Reopen it, or add \`squad\` to a later part to continue." >/dev/null || true
      return 0
    fi
  done
  gh issue close "$issue" --repo "$REPO_SLUG" --reason completed --comment "✅ Worker ${WORKER_ID}: all ${total} parts are done." >/dev/null || return 1
  log "Split #${issue}: all ${total} parts done; parent closed"
}

# A child of an approved split is manual intake like its parent, so the parts
# do not wait behind unattended WIP or the daily attempt budget. Required:
# this publisher's part marker on the child, the matching record on the parent,
# and a parent that is open, created by an allowlisted human and still carries
# every required approval label with human provenance. Fails closed.
split_child_manual() {
  local child="$1" comments parent pjson
  [[ "$child" =~ ^[1-9][0-9]*$ && "$(jq length <<<"$LOOP_MANUAL_ISSUE_CREATORS")" -gt 0 ]] || return 1
  comments=$(split_comments "$child") || return 1
  parent=$(split_own <<<"$comments" | jq -r --arg p "$SPLIT_PART_PREFIX" '
    [.[] | .body // "" | split("\n")[] | select(startswith($p)) | ltrimstr($p) | rtrimstr(" -->") |
      (try fromjson catch null) | select(type == "object") | .parent | select(type == "number")] | first // empty') || return 1
  [[ "$parent" =~ ^[1-9][0-9]*$ ]] || return 1
  split_recorded "$(split_comments "$parent")" | jq -e --argjson c "$child" 'to_entries | any(.value == $c)' >/dev/null || return 1
  pjson=$(gh issue view "$parent" --repo "$REPO_SLUG" --json state,author,labels) || return 1
  jq -e --argjson creators "$LOOP_MANUAL_ISSUE_CREATORS" --argjson required "$LOOP_REQUIRED_LABELS" '
    .state == "OPEN" and .author.is_bot == false and
    ((.author.login // "") | ascii_downcase) as $a | ($creators | map(ascii_downcase) | index($a)) != null and
    ($required | length > 0) and ([.labels[].name] as $n | all($required[]; . as $r | $n | index($r)))' <<<"$pjson" >/dev/null || return 1
  manual_approval_authorized "$parent"
}

# Main-loop hook: new split requests, then progress of running splits.
process_splits() {
  local number
  while IFS= read -r number; do
    [[ "$number" =~ ^[1-9][0-9]*$ ]] && { perform_split "$number" || log_error "Split of #${number} incomplete; resuming next cycle"; }
  done < <(gh issue list --repo "$REPO_SLUG" --state open --label "$SPLIT_LABEL" --json number --limit 20 --jq '.[].number' 2>/dev/null)
  while IFS= read -r number; do
    [[ "$number" =~ ^[1-9][0-9]*$ ]] && { advance_split "$number" || log_error "Split #${number} could not advance; resuming next cycle"; }
  done < <(gh issue list --repo "$REPO_SLUG" --state open --label "$SPLIT_PARENT_LABEL" --json number,labels --limit 20 \
    --jq '.[] | select([.labels[].name] | index("squad:split-stopped") | not) | .number' 2>/dev/null)
}
