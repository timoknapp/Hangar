# shellcheck shell=bash
# Attempt receipts: one hidden, machine-readable marker in the final issue
# comment of every attempt. Values are publisher-derived only (never agent
# text), so the marker cannot carry secrets, paths or tool output.
# Consumed by tools/factory-metrics.py; GitHub stays the only state store.

TASK_STAGE="${TASK_STAGE:-admission}"
TASK_KIND="${TASK_KIND:-issue}"
TASK_STARTED_AT="${TASK_STARTED_AT:-0}"
TASK_CREDITS="${TASK_CREDITS:-0}"
TASK_RETRY="${TASK_RETRY:-false}"

receipt_begin() {
  TASK_KIND="$1" TASK_STAGE=admission TASK_STARTED_AT=$(date +%s) TASK_CREDITS=0
}

# Implementer/correction sessions print "AI Credits <n> (...)" on exit. One
# session without that line makes the attempt total unknown, never a low count.
receipt_add_credits() {
  local credits
  [[ "$TASK_CREDITS" =~ ^[0-9]+$ ]] || return 0
  credits=$(sed -nE 's/^AI Credits ([0-9]+)( .*)?$/\1/p' "$1" 2>/dev/null | tail -1)
  if [[ "$credits" =~ ^[0-9]+$ ]]; then TASK_CREDITS=$((TASK_CREDITS + credits)); else TASK_CREDITS=unknown; fi
}

# Failure classes for block reasons. Unknown text stays "unclassified" so the
# metric shows the gap instead of guessing a class.
receipt_class() {
  case "$1" in
    "No changes produced"*|"Revision produced no changes"*|"The implementer stopped without changes"*) echo decision ;;
    "Independent review: open BLOCK findings"*) echo review ;;
    "Verification failed; correction budget exhausted"*) echo code ;;
    "Operator policy blocked"*|"Publication canceled"*|"Issue contract changed"*|\
    "Remote branch already exists"*|"Revision branch was never published"*|"Spec scope:"*|"No explicit required-check policy"*|\
    "Pinned remote-check policy changed"*|"approval or bounded issue contract"*|\
    "required label"*|"issue state is"*|"manual creator"*|"WIP ownership"*|\
    "Ready mutation failed/denied"*|"PR returned to draft"*|"PR head or body changed"*)
      echo policy ;;
    "Required remote check failed"*|"PR conflicts with"*) echo code ;;
    "Triage"*|*"failed"*|*"unavailable"*|*"timed out"*|*"Critic"*|*"masks"*|*"byte budget"*|*"drift"*|*"Token refresh"*|\
    *"interrupted"*|*"could not"*|*"Could not"*|*"Cannot"*|*"uncertain"*|*"deadline exceeded"*)
      echo infrastructure ;;
    *) echo unclassified ;;
  esac
}

# Prints the marker line for outcome ready|draft|ci-revision|failed|no-change.
receipt_marker() {
  local outcome="$1" class="${2:-}" seconds=unknown json
  if [[ "$TASK_STARTED_AT" =~ ^[1-9][0-9]*$ ]]; then seconds=$(( $(date +%s) - TASK_STARTED_AT )); fi
  json=$(jq -cn --arg worker "$WORKER_ID" --arg kind "$TASK_KIND" --arg stage "$TASK_STAGE" \
    --arg outcome "$outcome" --arg class "$class" --arg seconds "$seconds" --arg credits "$TASK_CREDITS" \
    --argjson retry "$([[ "$TASK_RETRY" == true ]] && echo true || echo false)" \
    '{v:1,worker:$worker,kind:$kind,stage:$stage,outcome:$outcome,class:(if $class == "" then null else $class end),autoRetry:$retry,
      seconds:($seconds|tonumber? // "unknown"),implementerCredits:($credits|tonumber? // "unknown")}') || return 0
  [[ "$json" != *"--"* ]] || return 0
  printf '<!-- hangar-receipt %s -->\n' "$json"
}
