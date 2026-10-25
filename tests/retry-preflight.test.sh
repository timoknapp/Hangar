#!/usr/bin/env bash
# Block 2a: transient-failure classification, once-per-issue automatic retry,
# due-retry release, and the pre-claim worker preflight. GitHub and the model
# launcher are fixtures; queue/claim code paths are the real ones.
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

# --- classification: retry only what a retry can change ---
while IFS='|' read -r reason want; do
  if retryable_failure "$reason"; then got=yes; else got=no; fi
  [[ "$got" == "$want" ]] || fail "retryable('$reason') = $got, want $want"
done <<'EOF'
Fresh clean base preparation failed; workspace retained|yes
Revision base preparation failed; explicit recovery required|yes
Could not refresh the authoritative base after implementation|yes
Implementation failed or timed out (exit 124)|yes
Critic process exited with code 1. invalid CLI event JSON|yes
Infrastructure/verification unavailable; no code correction attempted.|yes
Cannot read current-head PR checks (permission or API failure)|yes
Worker interrupted; explicit retry/recovery required|yes
Critic full-input delivery was not proven: incomplete input delivery (3500/6593 lines)|no
Review input still contains text the Copilot CLI masks (lines: 2896)|no
Complete review exceeds configured byte budget; split or obtain explicit human review.|no
Base check after implementation: base drift|no
Agent branch/HEAD ancestry drift; retained for explicit recovery|no
Operator policy blocked verification; no code correction attempted.|no
Independent review: open BLOCK findings remain after 4/4 corrections.|no
Verification failed; correction budget exhausted (2/2) or baseline unproven.|no
No changes produced; operator assessment required|no
Remote branch already exists; explicit revision required|no
Publication canceled: required label approved is absent|no
Something nobody anticipated|no
EOF
ok 'only transient infrastructure failures are retryable; deterministic ones never'

# --- cleanup_issue schedules exactly one retry, durable in GitHub ---
COMMENTS='[]' MODE=ok
gh() {
  case "$1 $2" in
    'issue edit') printf '%s\n' "$*" >>"$TMP/edits"; return 0 ;;
    'issue comment')
      [[ "$MODE" != comment-fail ]] || return 1
      COMMENTS=$(jq --arg b "$*" '. + [{body:$b}]' <<<"$COMMENTS"); return 0 ;;
    'api --paginate')
      [[ "$MODE" != history-fail ]] || return 1
      printf '%s\n' "$COMMENTS"; return 0 ;;
    'issue view') printf '%s\n' "$ISSUE_VIEW"; return 0 ;;
    'api repos/example/repo/git/matching-refs/heads/squad/9-')
      [[ "$MODE" != refs-fail ]] || return 1
      jq length <<<"$BRANCHES"; return 0 ;;
    *) fail "unexpected gh call: $*" ;;
  esac
}
release_issue_claim() { return 0; }
CURRENT_CLAIM_REF="" TASK_KIND=issue TASK_STARTED_AT=$(date +%s) TASK_CREDITS=0
cleanup_issue 9 squad/9-x "Fresh clean base preparation failed; workspace retained"
[[ -f "$LOOP_STATE_DIR/auto-retry-9.json" ]] || fail 'first transient failure did not schedule a retry'
jq -e '[.[] | select(.body | contains("<!-- hangar-auto-retry -->") and contains("\"autoRetry\":true"))] | length == 1' <<<"$COMMENTS" >/dev/null || fail 'retry marker/receipt missing'
rm "$LOOP_STATE_DIR/auto-retry-9.json"
cleanup_issue 9 squad/9-x "Implementation failed or timed out (exit 124)"
[[ ! -f "$LOOP_STATE_DIR/auto-retry-9.json" ]] || fail 'second transient failure retried again'
jq -e '.[-1].body | contains("\"autoRetry\":false") and contains("explicitly repair/recover")' <<<"$COMMENTS" >/dev/null || fail 'second failure must block for a human'
ok 'one automatic retry per issue; the marker in GitHub stops a second one'
COMMENTS='[]'
cleanup_issue 9 squad/9-x "Critic full-input delivery was not proven: incomplete"
[[ ! -f "$LOOP_STATE_DIR/auto-retry-9.json" ]] || fail 'deterministic failure scheduled a retry'
MODE=history-fail
cleanup_issue 9 squad/9-x "Fresh clean base preparation failed; workspace retained"
[[ ! -f "$LOOP_STATE_DIR/auto-retry-9.json" ]] || fail 'unreadable history must fail closed'
MODE=comment-fail; COMMENTS='[]'
cleanup_issue 9 squad/9-x "Fresh clean base preparation failed; workspace retained"
[[ ! -f "$LOOP_STATE_DIR/auto-retry-9.json" ]] || fail 'retry scheduled without its durable marker'
MODE=ok
ok 'no retry for deterministic failures, unreadable history or an unrecorded marker'

# --- due retries re-enter the normal queue ---
: >"$TMP/edits"
LOOP_RETRY_DELAY_SECONDS=0 TASK_KIND=issue
write_auto_retry 9
ISSUE_VIEW='{"state":"OPEN","labels":[{"name":"squad"},{"name":"squad:failed"}]}' BRANCHES='[]'
process_due_retries
grep -q -- '--remove-label squad:failed' "$TMP/edits" || fail 'due retry not released'
! grep -q -- 'squad:revision' "$TMP/edits" || fail 'new work without a pushed branch must not become a revision'
[[ ! -f "$LOOP_STATE_DIR/auto-retry-9.json" ]] || fail 'released retry record kept'
: >"$TMP/edits"; write_auto_retry 9; BRANCHES='[{"ref":"refs/heads/squad/9-x"}]'
process_due_retries
grep -q -- '--add-label squad:revision' "$TMP/edits" || fail 'pushed branch must continue as revision'
: >"$TMP/edits"; write_auto_retry 9; MODE=refs-fail
process_due_retries
[[ ! -s "$TMP/edits" && -f "$LOOP_STATE_DIR/auto-retry-9.json" ]] || fail 'unknown branch state must wait, not guess'
MODE=ok; rm "$LOOP_STATE_DIR/auto-retry-9.json"
ok 'due retries rejoin the queue as new work or revision, never guessing'
for view in '{"state":"CLOSED","labels":[{"name":"squad"},{"name":"squad:failed"}]}' \
            '{"state":"OPEN","labels":[{"name":"squad:failed"}]}' \
            '{"state":"OPEN","labels":[{"name":"squad"}]}'; do
  : >"$TMP/edits"; write_auto_retry 9; ISSUE_VIEW="$view"
  process_due_retries
  [[ ! -s "$TMP/edits" && ! -f "$LOOP_STATE_DIR/auto-retry-9.json" ]] || fail "retry not cancelled for $view"
done
LOOP_RETRY_DELAY_SECONDS=600; write_auto_retry 9; ISSUE_VIEW='{"state":"OPEN","labels":[{"name":"squad"},{"name":"squad:failed"}]}'
: >"$TMP/edits"; process_due_retries
[[ ! -s "$TMP/edits" && -f "$LOOP_STATE_DIR/auto-retry-9.json" ]] || fail 'retry released before its delay'
rm "$LOOP_STATE_DIR/auto-retry-9.json"
printf '{"issue":"../x","notBefore":0}' >"$LOOP_STATE_DIR/auto-retry-bad.json"
: >"$TMP/edits"; process_due_retries
[[ ! -s "$TMP/edits" && -f "$LOOP_STATE_DIR/auto-retry-bad.invalid" ]] || fail 'malformed retry record acted on'
ok 'closing, unlabeling, a human retry, the delay and malformed records all stop the retry'

# --- preflight ---
PF_FREE=50000 PF_FETCH=0 PF_CLEAN=0 PF_MODEL=ok PF_VERSION='GitHub Copilot CLI 1.0.70.'
df() { printf 'Filesystem 1048576-blocks Used Available Capacity Mounted\n/dev/x 100000 1 %s 1%% /w\n' "$PF_FREE"; }
sanitize_repository_git_config() { return 0; }
workspace_clean() { return "$PF_CLEAN"; }
repair_shared_workspace_modes() { return 0; }
fetch_task_base() { return "$PF_FETCH"; }
copilot() { printf '%s\n' "$PF_VERSION"; }
run_agent_copilot() { echo x >>"$TMP/probes"; [[ "$PF_MODEL" == ok ]] && echo HANGAR_PREFLIGHT_OK || echo 'model not available'; }
probes() { wc -l <"$TMP/probes" 2>/dev/null || echo 0; }
printf '1.0.70\n' >"$TMP/cli-pin"; HANGAR_CLI_PIN_FILE="$TMP/cli-pin" AUTO_UPDATE_CLI=false COPILOT_MODEL=impl LOOP_CRITIC=true LOOP_CRITIC_MODEL=critic
worker_preflight || fail "healthy worker refused: $PREFLIGHT_REASON"
[[ "$(probes)" == 2 ]] || fail "implementer and critic model must both be probed ($(probes))"
worker_preflight || fail 'cached healthy probe refused'
[[ "$(probes)" == 2 ]] || fail 'model probe not cached'
ok 'healthy worker passes; both models probed once per TTL'
check_unhealthy() {
  local label="$1"
  if worker_preflight 2>/dev/null; then fail "$label accepted"; fi
  [[ -n "$PREFLIGHT_REASON" ]] || fail "$label without reason"
}
PF_FREE=10; check_unhealthy 'low disk'; PF_FREE=50000
PF_FREE=garbage; check_unhealthy 'unreadable disk'; PF_FREE=50000
PF_FETCH=1; check_unhealthy 'fetch failure (e.g. .git/objects ownership)'; PF_FETCH=0
PF_CLEAN=1; check_unhealthy 'dirty workspace'; PF_CLEAN=0
PF_VERSION='GitHub Copilot CLI 1.0.92.'; check_unhealthy 'CLI drift'
AUTO_UPDATE_CLI=true; worker_preflight || fail 'opted-in auto update must not be blocked by the pin'; AUTO_UPDATE_CLI=false
PF_VERSION=''; check_unhealthy 'unreadable CLI version'; PF_VERSION='GitHub Copilot CLI 1.0.70.'
: >"$TMP/cli-pin"; check_unhealthy 'empty pin file'; printf '1.0.70\n' >"$TMP/cli-pin"
HANGAR_CLI_PIN_FILE="$TMP/absent"; PF_VERSION='GitHub Copilot CLI 9.9.9.'; worker_preflight || fail 'image without pin file must not be blocked'
HANGAR_CLI_PIN_FILE="$TMP/cli-pin"; PF_VERSION='GitHub Copilot CLI 1.0.70.'
PREFLIGHT_MODELS_OK_UNTIL=0 PF_MODEL=gone; check_unhealthy 'unavailable model'
[[ "$PREFLIGHT_REASON" == *"impl"* ]] || fail 'reason must name the model'
PF_MODEL=ok; worker_preflight || fail 'recovered worker refused'
ok 'disk, fetch, dirty workspace, CLI drift and model outages block claiming; recovery resumes'
log_count=$( { PF_FETCH=1; worker_preflight; worker_preflight; worker_preflight; } 2>&1 | grep -c 'claiming nothing' || true)
[[ "$log_count" == 1 ]] || fail "unhealthy reason logged $log_count times"
ok 'an unchanged unhealthy reason is logged once'

# --- Playwright browsers follow the repository lockfile, not the image build ---
(
  unset -f fetch_task_base
  REPO="$TMP/pw"; git init -q -b main "$REPO"; cd "$REPO"
  git config user.name Fixture; git config user.email fixture@example.invalid
  mkdir -p web api
  jq -n '{packages:{"node_modules/playwright-core":{version:"1.64.1"}}}' >web/package-lock.json
  jq -n '{packages:{}}' >api/package-lock.json
  jq -n '{packages:{"node_modules/playwright-core":{version:"1.64.1; rm -rf /"}}}' >evil-package-lock.json
  git add . && git commit -qm base; BASE_PW=$(git rev-parse HEAD)
  AGENT_HOME="$TMP/agent-home"; mkdir -p "$AGENT_HOME/.cache/ms-playwright"
  sudo() { shift 3; "$@"; }
  run_agent_command() { printf '%s\n' "$1" >>"$TMP/installs"; [[ "${PW_FAIL:-}" != 1 ]] || return 1; bash -c "${1#*&& }"; }
  : >"$TMP/installs"
  preflight_browsers "$BASE_PW" || fail "browser preflight failed: $PREFLIGHT_REASON"
  [[ "$(wc -l <"$TMP/installs")" == 1 && "$(cat "$TMP/installs")" == *'playwright-core@1.64.1 -- playwright-core install chromium'* ]] ||
    fail "expected one install of the lockfile version: $(cat "$TMP/installs")"
  preflight_browsers "$BASE_PW" || fail 'second preflight failed'
  [[ "$(wc -l <"$TMP/installs")" == 1 ]] || fail 'installed again despite marker'
  jq -n '{packages:{"node_modules/playwright-core":{version:"1.65.0"}}}' >web/package-lock.json
  git commit -qam bump; PW_FAIL=1
  if preflight_browsers "$(git rev-parse HEAD)"; then fail 'failed install accepted'; fi
  [[ "$PREFLIGHT_REASON" == *'Playwright 1.65.0'* ]] || fail "reason: $PREFLIGHT_REASON"
  jq -n '{packages:{}}' >web/package-lock.json; git commit -qam none; : >"$TMP/installs"
  preflight_browsers "$(git rev-parse HEAD)" || fail 'repository without Playwright blocked'
  [[ ! -s "$TMP/installs" ]] || fail 'installed without a lockfile version'
)
ok 'Playwright browsers match the lockfile version, install once, reject malformed versions and block on install failure'

main_src=$(declare -f main)
pre=$(grep -n 'worker_preflight' <<<"$main_src" | head -1 | cut -d: -f1)
proc=$(grep -n 'process_issue "\$issue_json"' <<<"$main_src" | head -1 | cut -d: -f1)
rev=$(grep -n 'process_revision "\$issue_json"' <<<"$main_src" | head -1 | cut -d: -f1)
[[ -n "$pre" && "$pre" -lt "$proc" && "$pre" -lt "$rev" ]] || fail 'preflight must run before any claim'
grep -q 'process_due_retries' <<<"$main_src" || fail 'due retries are never released'
ok 'main loop releases due retries and runs preflight before every claim'
