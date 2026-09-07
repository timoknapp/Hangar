#!/usr/bin/env bash
# Harmless hostile-metadata regressions. No network, tokens or system mutations.
# shellcheck disable=SC2034,SC2317
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GITHUB_OWNER=example GITHUB_REPO=fixture REPO_BRANCH=main
export WORKSPACE_DIR="$TMP/repo" LOOP_STATE_DIR="$TMP/state"
# shellcheck source=/dev/null
source "$ROOT/worker/worker-loop.sh"
# shellcheck source=tests/fixtures/evidence-user-switch.sh
source "$ROOT/tests/fixtures/evidence-user-switch.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
reject() { if "$@"; then fail "unexpected success: $*"; fi; }
command git init -q "$WORKSPACE_DIR"
cd "$WORKSPACE_DIR"
command git config user.name Fixture
command git config user.email fixture@example.invalid
printf 'fixture\n' >file.txt
command git add . && command git commit -qm fixture
cat >"$TMP/payload" <<EOF
#!/bin/sh
printf executed >"$TMP/publisher-payload"
printf '1\\0'
EOF
chmod 700 "$TMP/payload"
cp -a .git "$TMP/pristine"
cp -a .git "$TMP/alternate"
command git --git-dir="$TMP/alternate" config core.fsmonitor "$TMP/payload"
printf '%s\n' "$TMP/alternate" >.git/commondir
reject sanitize_repository_git_config
[[ ! -e "$TMP/publisher-payload" ]] || fail 'common-dir payload executed'
rm .git/commondir
# Config indirection and invalid destination are not silently rewritten/followed.
mv .git/config "$TMP/original-config"
ln -s "$TMP/original-config" .git/config
reject sanitize_repository_git_config
rm .git/config
mkdir .git/config
reject sanitize_repository_git_config
rmdir .git/config
cp "$TMP/original-config" .git/config
# Each config-construction and final replacement failure must propagate.
# Bash `command` is overridden only within a subshell, never production.
(
  command() { if [[ "$1 $2" == 'git config' ]]; then return 9; fi; builtin command "$@"; }
  reject sanitize_repository_git_config
)
(
  mv() { return 9; }
  reject sanitize_repository_git_config
)
sanitize_repository_git_config
[[ "$(command git config core.fsmonitor)" == false ]] || fail 'fsmonitor not disabled'
# The true production gate must return immediately after a hostile .git swap.
agent_startup_canary() { return 0; }
resolve_verify_cmd() { echo fixture; }
retain_gate_log() { cp "$1" "$TMP/gate.log"; }
run_agent_command() {
  command git config core.fsmonitor "$TMP/payload"
  mv .git "$TMP/swapped"
  ln -s "$TMP/swapped" .git
  echo HANGAR_AGENT_STARTED
}
TASK_BASE_SHA=$(command git rev-parse HEAD)
LOOP_VERIFY=fixture
rc=0
run_verify_gate || rc=$?
[[ "$rc" == 4 && "$VERIFY_FAILURE_KIND" == infrastructure ]] || fail 'metadata error misclassified'
[[ ! -e "$TMP/publisher-payload" ]] || fail 'publisher ran Git after rejecting metadata'
grep -q 'no publisher Git' "$TMP/gate.log" || fail 'safe failure log missing'
echo 'Hostile Git metadata: PASS (symlink, commondir, config shape, construction/move errors, post-verify stop)'
