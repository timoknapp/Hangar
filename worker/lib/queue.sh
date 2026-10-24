# shellcheck shell=bash
# Queue selection: which open issue a free worker may claim next.
# Extracted verbatim from worker-loop.sh (behavior-neutral).

# Legacy non-loop:auto ordering is not proof of manual origin or exemption.
# Verified manual intake is selected separately, before revisions and generated work.
select_next_unclaimed_issue() {
  local issues_json="$1"
  printf '%s' "$issues_json" | jq -c --argjson required "$LOOP_REQUIRED_LABELS" '
    def label_names: ((.labels // []) | map(.name));
    def eligible:
      ((label_names | index("squad:processing")) == null)
      and ((label_names | index("squad:done")) == null)
      and ((label_names | index("squad:failed")) == null)
      and ((label_names | index("squad:review-pending")) == null)
      and ((label_names | index("squad:needs-decision")) == null)
      and (label_names as $names | all($required[]; . as $v | $names | index($v)));

    ([.[] | select(eligible and ((label_names | index("loop:auto")) == null))]
      | sort_by(.number) | first)
    //
    ([.[] | select(eligible and ((label_names | index("loop:auto")) != null))]
      | sort_by(.number) | first)
    // empty
  '
}

# ---------------------------------------------------------------------------
# Find legacy unclaimed work (must have "squad" label). Non-loop:auto ordering
# here never grants the verified manual exemption.
# ---------------------------------------------------------------------------
find_unclaimed_issue() {
  local issues
  # Legacy queue window; verified manual priority uses the complete API below.
  issues=$(gh issue list \
    --repo "$REPO_SLUG" \
    --label "squad" \
    --state open \
    --json number,title,body,labels,state,author \
    --limit 100 2>/dev/null) || {
    log_error "Failed to fetch issues"
    return 1
  }

  select_next_unclaimed_issue "$issues"
}

# Complete queue for opt-in priority; REST supplies explicit User/Bot identity.
# Pull requests share the issues endpoint and must never enter the issue queue.
find_manual_issue() {
  [[ "$(jq length <<<"$LOOP_MANUAL_ISSUE_CREATORS")" -gt 0 ]] || return 0
  local pages issues candidates claims
  pages=$(gh api --paginate "repos/${REPO_SLUG}/issues?state=open&labels=squad&per_page=100" | jq -s '.') || return 1
  jq -e 'type == "array" and length > 0 and all(.[]; type == "array" and all(.[];
    type == "object" and (.number | type == "number" and . > 0 and . == floor) and
    (.state == "open" or .state == "closed") and
    (.labels | type == "array" and all(.[]; .name | type == "string"))))' <<<"$pages" >/dev/null || return 1
  issues=$(jq '[.[][] | select(.pull_request == null) |
    . + {state:(.state | ascii_upcase),author:{login:.user.login,is_bot:(.user.type != "User")}}]' <<<"$pages") || return 1
  candidates=$(jq -c --argjson creators "$LOOP_MANUAL_ISSUE_CREATORS" --argjson required "$LOOP_REQUIRED_LABELS" "${MANUAL_ISSUE_FILTER}"'
    [.[] | select(manual_issue) | [.labels[].name] as $names |
      select(($names | index("squad:processing")) == null) |
      select(($names | index("squad:revision")) != null or
        all(["squad:done","squad:failed","squad:review-pending","squad:needs-decision"][]; . as $v | $names | index($v) | not))] |
    sort_by(.number)
  ' <<<"$issues") || return 1
  [[ "$(jq length <<<"$candidates")" -gt 0 ]] || return 0
  # A claim can precede its processing label or survive a worker restart. Skip it
  # without stealing/releasing it so another free worker can take the next issue.
  claims=$(gh api --paginate "repos/${REPO_SLUG}/git/matching-refs/heads/squad-claims/issue-" | jq -s '.') || return 1
  jq -e 'type == "array" and length > 0 and all(.[]; type == "array" and
    all(.[]; .ref | type == "string"))' <<<"$claims" >/dev/null || return 1
  jq -c --argjson claims "$claims" '
    ($claims | add | map(.ref)) as $refs |
    [.[] | select(("refs/heads/squad-claims/issue-" + (.number|tostring)) as $ref |
      $refs | index($ref) | not)] | first // empty
  ' <<<"$candidates"
}

find_next_issue() {
  local issue
  issue=$(find_manual_issue) || return 1
  if [[ -z "$issue" ]]; then issue=$(find_revision_issue) || return 1; fi
  if [[ -z "$issue" ]]; then issue=$(find_unclaimed_issue) || return 1; fi
  printf '%s\n' "$issue"
}

# ---------------------------------------------------------------------------
# Find the oldest issue needing revision (has "squad:revision" label)
# ---------------------------------------------------------------------------
find_revision_issue() {
  local issues
  issues=$(gh issue list \
    --repo "$REPO_SLUG" \
    --label "squad:revision" \
    --state open \
    --json number,title,body,labels,state,author \
    --limit 20 2>/dev/null) || {
    log_error "Failed to fetch revision issues"
    return 1
  }

  # Filter out issues currently being processed
  # Pick the oldest (lowest issue number)
  echo "$issues" | jq -r --argjson required "$LOOP_REQUIRED_LABELS" '
    [ .[] | select(
        .labels | map(.name) | index("squad:processing") | not
      )
    ] | map(select([.labels[].name] as $names | all(($required + ["squad"])[]; . as $v | $names | index($v)))) | sort_by(.number) | first // empty
  '
}
