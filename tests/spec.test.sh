#!/usr/bin/env bash
# Block 5: spec work type. Git is real (path guard, merged spec at the pinned
# base); GitHub is a fixture. A spec task may only change its spec directory,
# never closes its issue, and later implementations read the merged spec.
# shellcheck disable=SC2016,SC2034,SC2317
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export GITHUB_OWNER=example GITHUB_REPO=repo REPO_BRANCH=main WORKSPACE_DIR="$TMP/repo" LOOP_STATE_DIR="$TMP/state"
# shellcheck source=/dev/null
source "$ROOT/worker/worker-loop.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "PASS: $*"; }

git init -q -b main "$WORKSPACE_DIR"; cd "$WORKSPACE_DIR"
git config user.name Fixture; git config user.email fixture@example.invalid
printf 'app\n' >app.txt && git add . && git commit -qm base
TASK_BASE_SHA=$(git rev-parse HEAD)
check_repository_evidence() { return 0; }

# --- policy ---
validate_spec_policy || fail 'default spec dir rejected'
[[ "$(spec_dir 42)" == specs/issue-42 ]] || fail "default spec dir: $(spec_dir 42)"
(LOOP_SPEC_DIR='openspec/changes/issue-{n}'; validate_spec_policy && [[ "$(spec_dir 7)" == openspec/changes/issue-7 ]]) || fail 'custom spec dir'
for bad in 'specs' '/abs/{n}' '../x/{n}' 'a//{n}' '.git/{n}' 'sp ace/{n}'; do
  (LOOP_SPEC_DIR="$bad"; ! validate_spec_policy 2>/dev/null) || fail "accepted spec dir: $bad"
done
ok 'spec directory policy: {n} required; absolute, parent, empty-segment, .git and odd characters rejected'

# --- deterministic path guard ---
git checkout -qb spec
mkdir -p specs/issue-7 && printf '# Spec\n' >specs/issue-7/spec.md && git add . && git commit -qm spec
spec_paths_ok 7 || fail 'spec-only change rejected'
printf 'x\n' >app.txt && git commit -qam code
if spec_paths_ok 7; then fail 'code change accepted in a spec task'; fi
[[ "$SPEC_GUARD_PATH" == app.txt ]] || fail "guard path: $SPEC_GUARD_PATH"
git reset -q --hard HEAD~1
mkdir -p specs/issue-70 && printf 'y\n' >specs/issue-70/spec.md && git add . && git commit -qm other
if spec_paths_ok 7; then fail 'sibling issue directory accepted (prefix match)'; fi
git reset -q --hard HEAD~1
git mv specs/issue-7/spec.md moved.md && git commit -qm rename
if spec_paths_ok 7; then fail 'rename out of the spec dir accepted'; fi
git reset -q --hard HEAD~1
ok 'path guard: only the issue spec directory; code, sibling issue directories and renames out are blocked'

# --- quality gate integration: guard blocks before review, as policy ---
TASK_SPEC=true CURRENT_ISSUE=7 LOOP_CRITIC=true
task_integrity() { return 0; }
run_verify_with_corrections() { return 0; }
summary_complete() { return 0; }
build_final_pr_body() { FINAL_PR_BODY=x; }
run_critic_review() { fail 'critic ran despite a path violation'; }
printf 'x\n' >app.txt && git commit -qam code
if run_quality_gates >/dev/null 2>&1; then fail 'gates passed with code in a spec task'; fi
[[ "$GATE_NOTE" == 'Spec scope: app.txt is outside specs/issue-7/'* ]] || fail "gate note: $GATE_NOTE"
git reset -q --hard HEAD~1
[[ "$(receipt_class "$GATE_NOTE")" == policy ]] || fail 'spec scope violation is not a policy block'
! retryable_failure "$GATE_NOTE" || fail 'spec scope violation retried'
ok 'a spec task with code changes blocks before review with the offending path'

# --- prompt, rubric, PR reference ---
a=$(spec_assignment 7)
[[ "$a" == *'Change files ONLY under `specs/issue-7/`'* && "$a" == *'open questions'* ]] || fail 'spec assignment'
[[ "$(spec_rubric)" == *'SPEC, not an implementation'* ]] || fail 'spec rubric'
grep -q 'TASK_SPEC.*spec_rubric' "$ROOT/worker/lib/critic.sh" || fail 'critic does not add the spec rubric for spec tasks'
generate_change_summary() { :; }
body=$(TASK_SPEC=true build_pr_body 7 'Design X' 'Please spec it.' '' 2>/dev/null) || true
[[ "$body" == *'Refs #7 (spec; merging approves implementation).'* && "$body" != *'Closes #7'* ]] || fail 'spec PR closes its issue'
body=$(TASK_SPEC=false build_pr_body 7 'Do X' 'Please do it.' '' 2>/dev/null) || true
[[ "$body" == *'Closes #7.'* ]] || fail 'implementation PR no longer closes its issue'
src=$(declare -f publish_task)
[[ "$src" == *'kind=spec'* && "$src" == *'${kind}: #${issue}'* ]] || fail 'spec PR title prefix'
ok 'spec tasks get the spec assignment and rubric, a spec: title, and Refs instead of Closes'

# --- implementation reads the merged spec from the pinned base only ---
git checkout -q main
TASK_SPEC=false
[[ -z "$(merged_spec_context 7)" ]] || fail 'unmerged spec branch leaked into the implementation'
git merge -q --no-ff spec -m 'merge spec'
TASK_BASE_SHA=$(git rev-parse HEAD)
read_trusted_file() { git show "${TASK_BASE_SHA}:$1"; }
ctx=$(merged_spec_context 7)
[[ "$ctx" == *'Merged spec for this issue'* && "$ctx" == *'# Spec'* ]] || fail "merged spec not provided: $ctx"
printf 'dirty\n' >>specs/issue-7/spec.md
[[ "$(merged_spec_context 7)" != *dirty* ]] || fail 'working-tree edit used instead of the pinned base'
git checkout -q -- specs
ok 'implementations read the merged spec from the pinned base; unmerged branches and worktree edits never count'

# --- triage needs-spec + squad:spec re-queues; triage is skipped for spec tasks ---
gh() { case "$1 $2" in
  'issue list') [[ "$*" == *'--label squad:needs-spec --label squad:spec'* ]] && echo 9 ;;
  'issue edit') printf '%s\n' "$*" >>"$TMP/edits" ;;
  *) fail "unexpected gh $*" ;; esac; }
requeue_spec_requests
grep -q 'issue edit 9 .*--remove-label squad:needs-spec --add-label squad' "$TMP/edits" || fail 'needs-spec + squad:spec not re-queued'
[[ "$(declare -f process_issue)" == *'[[ "$TASK_SPEC" == true ]] || run_triage'* ]] || fail 'triage not skipped for spec tasks'
ok 'needs-spec issues marked squad:spec re-queue as spec tasks, which skip triage'
