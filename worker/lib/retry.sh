# shellcheck shell=bash
# One delayed automatic retry per issue for transient infrastructure failures.
# Deterministic failures (size/masking delivery proofs, drift, policy, code,
# review, decisions) never retry. The once-per-issue guard is durable in
# GitHub: the blocked comment carries a hangar-auto-retry marker and a second
# failure finds it. Unreadable history means no retry (fail closed).

LOOP_RETRY_DELAY_SECONDS="${LOOP_RETRY_DELAY_SECONDS:-600}"
AUTO_RETRY_MARKER='<!-- hangar-auto-retry -->'

retryable_failure() {
  case "$1" in
    *"delivery was not proven"*|*"masks"*|*"byte budget"*|*"drift"*|*"Remote branch already exists"*) return 1 ;;
    "Fresh clean base preparation failed"*|"Revision base preparation failed"*|\
    "Could not refresh the authoritative base"*|"Remote branch lookup failed"*|\
    "Implementation failed or timed out"*|"Revision failed or timed out"*|\
    "Baseline verification or launcher failed"*|"Revision baseline verification failed"*|\
    "Verified issue metadata unavailable"*|"Token refresh failed"*|\
    "Infrastructure/verification unavailable"*|"Critic process exited"*|\
    "Critic returned empty output"*|"Critic could not"*|"Cannot read current-head PR checks"*|\
    "PR lookup unavailable"*|"Push failed or remote branch changed"*|\
    "Worker interrupted"*|"Admission could not finish"*) return 0 ;;
    *) return 1 ;;
  esac
}

auto_retry_available() {
  local issue="$1" used
  used=$(gh api --paginate "repos/${REPO_SLUG}/issues/${issue}/comments?per_page=100" |
    jq -s --arg m "$AUTO_RETRY_MARKER" '[add // [] | .[] | select((.body // "") | contains($m))] | length') || return 1
  [[ "$used" == 0 ]]
}

# Written only after the marker comment was posted successfully.
write_auto_retry() {
  local issue="$1" tmp
  init_loop_state || return 1
  tmp=$(mktemp "${LOOP_STATE_DIR}/auto-retry.XXXXXX") || return 1
  jq -n --arg issue "$issue" --arg kind "$TASK_KIND" --argjson notBefore "$(( $(date +%s) + LOOP_RETRY_DELAY_SECONDS ))" \
    '{issue:$issue,kind:$kind,notBefore:$notBefore}' >"$tmp" && chmod 600 "$tmp" &&
    mv "$tmp" "${LOOP_STATE_DIR}/auto-retry-${issue}.json"
}

# Releases due retries back into the normal queue; any worker may claim them.
# A human retry, closing the issue or removing squad cancels the pending retry.
process_due_retries() {
  local f issue kind not_before json refs
  for f in "${LOOP_STATE_DIR}"/auto-retry-*.json; do
    [[ -f "$f" ]] || continue
    issue=$(jq -r '.issue // empty' "$f" 2>/dev/null) || issue=""
    kind=$(jq -r '.kind // "issue"' "$f" 2>/dev/null) || kind=issue
    not_before=$(jq -r '.notBefore // empty' "$f" 2>/dev/null) || not_before=""
    if [[ ! "$issue" =~ ^[1-9][0-9]*$ || ! "$not_before" =~ ^[0-9]+$ ]]; then
      log_error "Invalid auto-retry record ${f##*/}; retry dropped"; mv "$f" "${f%.json}.invalid"; continue
    fi
    (( $(date +%s) >= not_before )) || continue
    json=$(gh issue view "$issue" --repo "$REPO_SLUG" --json state,labels) || continue
    if ! jq -e '.state == "OPEN" and ([.labels[].name] | index("squad:failed") != null and index("squad") != null)' <<<"$json" >/dev/null; then
      log "Auto-retry for #${issue} no longer applies (closed, unlabeled or already retried)"; rm -f "$f"; continue
    fi
    local -a edit=(--remove-label squad:failed)
    if [[ "$kind" != revision ]]; then
      # A pushed branch means only a revision can continue the work.
      refs=$(gh api "repos/${REPO_SLUG}/git/matching-refs/heads/squad/${issue}-" --jq length) || continue
      [[ "$refs" =~ ^[0-9]+$ ]] || continue
      (( refs == 0 )) || kind=revision
    fi
    [[ "$kind" != revision ]] || edit+=(--add-label squad:revision)
    gh issue edit "$issue" --repo "$REPO_SLUG" "${edit[@]}" >/dev/null || continue
    rm -f "$f"
    log "Automatic retry released #${issue} (${kind})"
  done
}
