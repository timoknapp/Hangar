# shellcheck shell=bash
# Decision stops (ADR 0001, block 4): an implementer that deliberately stops
# without changes is asking a question, not failing. The issue waits on
# squad:needs-decision with the rationale; squad is removed so external queue
# dispatchers can advance. A later reply from the issue author or a manual
# approver (never a bot) re-queues it. Approval labels are never touched.

DECISION_MARKER='<!-- hangar-needs-decision -->'

# Called with the claim held, after the rationale comment was attempted.
park_for_decision() {
  local issue="$1" reason="$2"
  log "Implementer stopped for a decision on #${issue}; waiting on squad:needs-decision"
  if [[ -n "$CURRENT_CLAIM_REF" ]] && ! claim_owned; then
    log_error "Claim ownership lost/unverifiable; do not alter another owner's issue state"
    return 1
  fi
  if ! gh issue edit "$issue" --repo "$REPO_SLUG" --remove-label squad:processing --remove-label squad:revision \
    --remove-label squad:done --remove-label squad:review-pending --remove-label squad \
    --add-label squad:needs-decision >/dev/null; then
    # Fall back to the old terminal state rather than leave the claim dangling.
    cleanup_issue "$issue" "${TASK_BRANCH:-unknown}" "$reason"
    return
  fi
  gh issue comment "$issue" --repo "$REPO_SLUG" --body "❓ Worker ${WORKER_ID}: ${reason}. The implementer's handoff above explains what is missing. Reply in this issue with the decision; a reply from the issue author or an approver re-queues it automatically. No completion claimed.

${DECISION_MARKER}
$(receipt_marker no-change decision)" >/dev/null 2>&1 || log_error "Could not record the decision request for #${issue}"
  release_issue_claim || return 1
  # shellcheck disable=SC2034 # worker-loop.sh state
  CURRENT_ISSUE="" CURRENT_ISSUE_CONTEXT=""
}

# Human answers to the latest decision request: replies after the newest marker
# by the issue author or a manual creator (approver), never a bot. Bounded,
# oldest first. Empty when there is no request or no answer. Fails closed.
decision_answers() {
  local issue="$1" author
  author=$(gh issue view "$issue" --repo "$REPO_SLUG" --json author --jq .author.login) || return 1
  gh api --paginate "repos/${REPO_SLUG}/issues/${issue}/comments?per_page=100" | jq -rs \
    --arg marker "$DECISION_MARKER" --arg author "$author" --argjson approvers "$LOOP_MANUAL_ISSUE_CREATORS" '
      add // [] | (map(.body // "" | contains($marker)) | rindex(true)) as $at |
      if $at == null then empty else
        .[$at + 1:] | map(select(.user.type == "User" and (.user.login | ascii_downcase) as $who |
          ($who == ($author | ascii_downcase) or ($approvers | map(ascii_downcase) | index($who)) != null))) |
        .[-10:] | map("[\(.user.login)] \(.body // "" | .[0:4000])") | join("\n\n---\n\n")
      end'
}

# Context block for prompts and review; empty when nothing was decided.
decision_context() {
  local answers
  answers=$(decision_answers "$1") || return 1
  [[ -n "$answers" ]] || return 0
  printf '## Decisions from the issue author or an approver (answers to an earlier stop)\n\n%s\n' "$answers"
}

# Labels that wait for a human answer (triage adds the last three).
ANSWERABLE_WAIT_LABELS=(squad:needs-decision squad:needs-info squad:needs-spec squad:too-large)

# Re-queue issues whose request got an answer from an authorized human.
# too-large additionally needs the configured override label (or a split).
requeue_answered_decisions() {
  local label issues number answers
  for label in "${ANSWERABLE_WAIT_LABELS[@]}"; do
    issues=$(gh issue list --repo "$REPO_SLUG" --state open --label "$label" \
      --json number,labels --limit 50) || continue
    while IFS= read -r number; do
      [[ "$number" =~ ^[1-9][0-9]*$ ]] || continue
      answers=$(decision_answers "$number") || continue
      [[ -n "$answers" ]] || continue
      gh issue edit "$number" --repo "$REPO_SLUG" --remove-label "$label" --add-label squad >/dev/null || continue
      log "Answer on #${number} (${label}); re-queued"
    done < <(jq -r --arg label "$label" --arg override "${LOOP_TRIAGE_OVERRIDE_LABEL:-scope:large-approved}" '.[] |
      [.labels[].name] as $n | select(($n | index("squad:processing")) == null) |
      select($label != "squad:too-large" or ($n | index($override)) != null) | .number' <<<"$issues")
  done
}
