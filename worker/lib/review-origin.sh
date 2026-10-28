# shellcheck shell=bash disable=SC2034
# TASK_KEEP_DRAFT is consumed by the sourcing worker's publication lifecycle.
# Optional OPERATOR-owned provenance verifier, never a repository-selected hook.
# Supplies nonsecret evidence to the unprivileged instance verifier (fourth arg).
CURRENT_REVIEW_ORIGIN=null
refresh_review_origin() {
  CURRENT_REVIEW_ORIGIN=null
  [[ -n "$LOOP_PROFILE_DIR" && ( -e "$LOOP_PROFILE_DIR/review-origin.sh" || -L "$LOOP_PROFILE_DIR/review-origin.sh" ) ]] || return 0
  read_profile_file review-origin.sh >/dev/null || return 1
  local input output remaining contract
  input=$(jq -c --argjson number "$CURRENT_ISSUE" '. + {number:$number}' <<<"$1") || return 1
  remaining=$(task_seconds_remaining) || return 1
  contract=$(issue_contract_hash "$input") || return 1
  # Publisher owns network credentials; the installed hook is trusted operator
  # code. It may read GitHub provenance only; it receives no repository command.
  output=$(printf '%s\n' "$input" | timeout --kill-after=10 "$remaining" bash "$LOOP_PROFILE_DIR/review-origin.sh") || return 1
  (( ${#output} <= 16384 )) || return 1
  jq -e --argjson issue "$CURRENT_ISSUE" --arg contract "$contract" '
    . == null or (type == "object" and .kind == "scheduled-review" and .issue == $issue and
      .contractHash == $contract and .draftOnly == true and
      (.date | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and
      (.allowedPaths | type == "array" and length > 0 and length <= 32 and all(.[]; type == "string")))
  ' <<<"$output" >/dev/null || return 1
  CURRENT_REVIEW_ORIGIN=$(jq -c . <<<"$output") || return 1
  [[ "$CURRENT_REVIEW_ORIGIN" == null ]] || TASK_KEEP_DRAFT=true
}

baseline_block_reason() {
  case "${VERIFY_FAILURE_KIND:-}" in
    policy) printf '%s\n' 'Operator policy blocked baseline verification; no implementation attempted' ;;
    code) printf '%s\n' 'Baseline checks failed; no implementation attempted' ;;
    *) printf '%s\n' 'Baseline verification or launcher failed; no implementation attempted' ;;
  esac
}
