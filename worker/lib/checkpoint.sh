# shellcheck shell=bash disable=SC2034  # sets task globals owned by worker-loop.sh
# Checkpoint resume and reaper (block 2, part 2).
#
# Checkpoint: after implementation produced committed work, the publisher
# records the local branch, its exact HEAD, the pinned base and the issue
# contract. When the following gates fail for a transient infrastructure
# reason, the automatic retry resumes from that commit instead of running the
# implementer again. Any mismatch (contract, branch, HEAD, base, worker) falls
# back to a fresh attempt, never to a guessed resume.
#
# Reaper: releases this worker's own leftovers after a crash and stops
# admission bookkeeping for issues a human closed or unlabeled. It never
# deletes branches or work and never touches claims of other workers.

CHECKPOINT_SCHEMA=1

checkpoint_file() { printf '%s/checkpoint-%s.json\n' "$LOOP_STATE_DIR" "$1"; }

write_checkpoint() {
  local issue="$1" branch="$2" head tmp
  init_loop_state || return 1
  head=$(git rev-parse --verify HEAD) || return 1
  [[ "$TASK_BASE_SHA" =~ ^[0-9a-f]{40}$ && "$TASK_START_HEAD" =~ ^[0-9a-f]{40}$ ]] || return 1
  tmp=$(mktemp "${LOOP_STATE_DIR}/checkpoint.XXXXXX") || return 1
  jq -n --argjson v "$CHECKPOINT_SCHEMA" --arg issue "$issue" --arg branch "$branch" --arg head "$head" \
    --arg base "$TASK_BASE_SHA" --arg start "$TASK_START_HEAD" --arg contract "$ISSUE_CONTRACT_HASH" \
    --arg worker "$WORKER_ID" --arg summary "$PR_EXECUTIVE_SUMMARY" --arg credits "$TASK_CREDITS" \
    '{v:$v,issue:$issue,branch:$branch,head:$head,base:$base,start:$start,contract:$contract,
      worker:$worker,summary:$summary,credits:$credits}' >"$tmp" &&
    chmod 600 "$tmp" && mv "$tmp" "$(checkpoint_file "$issue")"
}

clear_checkpoint() { rm -f "$(checkpoint_file "$1")"; }

# Restores task state from a checkpoint when every binding still holds.
# Prints nothing; returns 0 only for a verified resume.
load_checkpoint() {
  local issue="$1" file cp head branch
  file=$(checkpoint_file "$issue")
  [[ -f "$file" && ! -L "$file" ]] || return 1
  cp=$(cat "$file") || return 1
  if ! jq -e --argjson v "$CHECKPOINT_SCHEMA" --arg issue "$issue" --arg contract "$ISSUE_CONTRACT_HASH" --arg worker "$WORKER_ID" '
      .v == $v and .issue == $issue and .contract == $contract and .worker == $worker and
      (.head | test("^[0-9a-f]{40}$")) and (.base | test("^[0-9a-f]{40}$")) and (.start | test("^[0-9a-f]{40}$")) and
      (.branch | type == "string" and startswith("squad/")) and (.summary | type == "string")' <<<"$cp" >/dev/null; then
    log "Checkpoint for #${issue} does not match the current contract/worker; starting fresh"
    clear_checkpoint "$issue"; return 1
  fi
  branch=$(jq -r .branch <<<"$cp"); head=$(jq -r .head <<<"$cp")
  workspace_clean || return 1
  git show-ref --verify --quiet "refs/heads/${branch}" || { log "Checkpoint branch for #${issue} is gone; starting fresh"; clear_checkpoint "$issue"; return 1; }
  [[ "$(git rev-parse --verify "refs/heads/${branch}^{commit}")" == "$head" ]] || {
    log "Checkpoint branch for #${issue} moved; starting fresh"; clear_checkpoint "$issue"; return 1; }
  git merge-base --is-ancestor "$(jq -r .base <<<"$cp")" "$head" || { clear_checkpoint "$issue"; return 1; }
  git checkout --no-overwrite-ignore "$branch" || return 1
  TASK_BRANCH="$branch" TASK_BASE_SHA=$(jq -r .base <<<"$cp") TASK_START_HEAD=$(jq -r .start <<<"$cp")
  PR_EXECUTIVE_SUMMARY=$(jq -r .summary <<<"$cp")
  TASK_CREDITS=$(jq -r '.credits // "unknown"' <<<"$cp")
  task_integrity || { clear_checkpoint "$issue"; return 1; }
  log "Resuming #${issue} from checkpoint ${head:0:12} (implementation kept; gates rerun)"
}

# --- reaper -----------------------------------------------------------------
LOOP_REAP_INTERVAL="${LOOP_REAP_INTERVAL:-3600}"
REAPER_LAST_RUN=0

# Runs only on an idle worker. A claim whose atomic claim commit names this
# worker cannot be live work (this worker holds nothing), so it is an orphan
# of a crash: block it as interrupted, which lets the automatic retry (and a
# checkpoint resume) take over. Claims of other workers are never touched.
reap_orphans() {
  (( $(date +%s) - REAPER_LAST_RUN >= LOOP_REAP_INTERVAL )) || return 0
  worker_available || return 0
  REAPER_LAST_RUN=$(date +%s)
  local refs ref oid issue owner f state
  refs=$(gh api --paginate "repos/${REPO_SLUG}/git/matching-refs/heads/squad-claims/issue-" |
    jq -sc '[add // [] | .[] | {ref, oid: .object.sha}]') || return 0
  while IFS=$'\t' read -r ref oid; do
    [[ "$oid" =~ ^[0-9a-f]{40}$ ]] || continue
    [[ "$ref" =~ ^refs/heads/squad-claims/issue-([1-9][0-9]*)$ ]] || continue
    issue="${BASH_REMATCH[1]}"
    owner=$(gh api "repos/${REPO_SLUG}/git/commits/${oid}" --jq '.message | fromjson? | .worker // empty') || continue
    [[ "$owner" == "$WORKER_ID" ]] || continue
    log_error "Reaper: orphaned claim on #${issue} from an earlier run of this worker"
    CURRENT_ISSUE="$issue" CURRENT_CLAIM_REF="$ref" CURRENT_CLAIM_OID="$oid" TASK_STAGE=admission
    cleanup_issue "$issue" "$(jq -r '.branch // "unknown"' "$(checkpoint_file "$issue")" 2>/dev/null || echo unknown)" \
      "Worker interrupted; explicit retry/recovery required" || true
    CURRENT_ISSUE="" CURRENT_ISSUE_CONTEXT="" CURRENT_CLAIM_REF="" CURRENT_CLAIM_OID=""
  done < <(jq -r '.[] | [.ref, .oid] | @tsv' <<<"$refs")
  for f in "${LOOP_STATE_DIR}"/checkpoint-*.json; do
    [[ -f "$f" ]] || continue
    issue=$(jq -r '.issue // empty' "$f" 2>/dev/null) || issue=""
    [[ "$issue" =~ ^[1-9][0-9]*$ ]] || { rm -f "$f"; continue; }
    state=$(gh issue view "$issue" --repo "$REPO_SLUG" --json state,labels \
      --jq 'if .state != "OPEN" then "closed" elif ([.labels[].name] | index("squad")) == null then "unlabeled" else "open" end') || continue
    # Branches and commits stay; only the private resume record goes.
    [[ "$state" == open ]] || { rm -f "$f"; log "Reaper: #${issue} is ${state}; dropped its checkpoint (work retained)"; }
  done
}
