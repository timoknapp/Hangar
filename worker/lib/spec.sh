# shellcheck shell=bash disable=SC2034  # sets task globals owned by worker-loop.sh
# Spec work type (ADR 0001, block 5). An approved issue labeled squad:spec runs
# the normal pipeline with a spec assignment instead of code: the diff must stay
# inside the issue's spec directory (deterministic path guard, policy class),
# the critic adds a spec rubric, and the PR references the issue without
# closing it. Merging the spec PR is the approval; later implementation runs
# read the merged spec from the pinned base (unmerged branches never count).

LOOP_SPEC_DIR="${LOOP_SPEC_DIR:-specs/issue-{n\}}"
SPEC_LABEL=squad:spec
TASK_SPEC=false

validate_spec_policy() {
  [[ "$LOOP_SPEC_DIR" == *'{n}'* && "$LOOP_SPEC_DIR" =~ ^[A-Za-z0-9._{}/-]{3,120}$ &&
     "$LOOP_SPEC_DIR" != /* && "$LOOP_SPEC_DIR" != *'..'* && "$LOOP_SPEC_DIR" != *'//'* &&
     "$LOOP_SPEC_DIR" != .git* ]] || { log_error "Invalid spec directory policy"; return 1; }
}

spec_dir() { printf '%s\n' "${LOOP_SPEC_DIR//\{n\}/$1}"; }

# Every changed path (including renames' old side) must be inside the spec dir.
spec_paths_ok() {
  local issue="$1" dir out path
  dir="$(spec_dir "$issue")/"
  out=$(git diff --no-renames --name-only "${TASK_BASE_SHA}...HEAD") || return 1
  [[ -n "$out" ]] || return 0
  while IFS= read -r path; do
    [[ "$path" == "$dir"* ]] || { SPEC_GUARD_PATH="$path"; return 1; }
  done <<<"$out"
}

spec_assignment() {
  local dir
  dir=$(spec_dir "$1")
  cat <<EOF
## Spec assignment (no code)

This is a SPEC task: write or update a specification, not an implementation.
- Change files ONLY under \`${dir}/\`. Any other changed path blocks publication.
- Follow the repository's own spec conventions where they exist; otherwise write \`${dir}/spec.md\` with:
  - Product: behaviour, acceptance criteria (testable), non-goals, open questions.
  - Technical: approach, affected areas, validation plan, risks.
- Keep unresolved questions visible as open questions; do not invent decisions.
- The spec pull request is reviewed and merged by a human; merging it is the approval for implementation.
EOF
}

spec_rubric() {
  printf '%s\n' 'This change is a SPEC, not an implementation. Block if: acceptance criteria are missing or not testable; product and technical parts contradict each other or the issue; decisions are invented where the issue leaves them open (they must stay open questions); non-goals or risks are missing for a broad change; or files outside the spec directory changed. Do not demand code or tests for the spec itself.'
}

# A merged spec for this issue at the pinned base, bounded; empty if none.
merged_spec_context() {
  local issue="$1" dir files f content out="" n=0
  dir=$(spec_dir "$issue")
  files=$(git ls-tree -r --name-only "$TASK_BASE_SHA" -- "$dir" 2>/dev/null) || return 0
  [[ -n "$files" ]] || return 0
  while IFS= read -r f; do
    (( n++ < 20 )) || break
    content=$(read_trusted_file "$f") || continue
    out+=$'\n'"### ${f}"$'\n\n'"${content}"$'\n'
    (( ${#out} < 60000 )) || break
  done <<<"$files"
  [[ -n "$out" ]] || return 0
  printf '## Merged spec for this issue (from the pinned base; binding scope and acceptance)\n%s' "${out:0:60000}"
}

# needs-spec issues a human marked for a spec run go back into the queue.
requeue_spec_requests() {
  local number
  while IFS= read -r number; do
    [[ "$number" =~ ^[1-9][0-9]*$ ]] || continue
    gh issue edit "$number" --repo "$REPO_SLUG" --remove-label squad:needs-spec --add-label squad >/dev/null || continue
    log "Spec requested for #${number}; re-queued as a spec task"
  done < <(gh issue list --repo "$REPO_SLUG" --state open --label squad:needs-spec --label "$SPEC_LABEL" \
    --json number --limit 20 --jq '.[].number' 2>/dev/null)
}
