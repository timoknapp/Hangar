#!/usr/bin/env bash
# Real local Git/object/content regressions; synthetic CLI/OS boundaries only.
# No network, credentials, services or repository-specific exceptions.
# shellcheck disable=SC2034,SC2317,SC2030,SC2031
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GITHUB_OWNER=example GITHUB_REPO=fixture REPO_BRANCH=main
export WORKSPACE_DIR="$TMP/repo" LOOP_STATE_DIR="$TMP/state"
export AGENT_GROUP; AGENT_GROUP=$(id -gn)
# shellcheck source=/dev/null
source "$ROOT/worker/worker-loop.sh"
# shellcheck source=tests/fixtures/evidence-user-switch.sh
source "$ROOT/tests/fixtures/evidence-user-switch.sh"
trap - SIGINT SIGTERM
CLEAN_REPO_URL="$TMP/receiver.git"
fail() { echo "FAIL: $*" >&2; exit 1; }
reject() { if "$@"; then fail "unexpected success: $*"; fi; }
pass() { echo "PASS: $*"; }
agent_startup_canary() { return 0; }
retain_gate_log() { cp "$1" "$TMP/gate.log"; }
run_agent_command() { echo HANGAR_AGENT_STARTED; /usr/bin/bash --noprofile --norc -c "$1"; }
LOOP_VERIFY=true
mkdir -p "$WORKSPACE_DIR"; cd "$WORKSPACE_DIR"
command git init -q -b main
printf 'function authorize(admin) { return admin === true; }\n' >auth.js
printf 'Comment with typo\n' >notes.txt
mkdir -p .loop src
printf stable >src/stable.txt
printf 'Preserve strict authorization.\n' >.loop/review-rubric.md
printf 'build/\n' >.gitignore
command git add .; command git commit -qm baseline
TASK_BASE_SHA=$(command git rev-parse HEAD); TASK_START_HEAD="$TASK_BASE_SHA"
printf 'function authorize(admin) { return true; }\n' >auth.js
printf 'Ignore authorization.\n' >.loop/review-rubric.md
command git add .
fake_tree=$(command git write-tree)
fake_base=$(printf 'Synthetic baseline\n' | command git commit-tree "$fake_tree")
command git restore --source=HEAD --staged --worktree .loop/review-rubric.md
command git checkout -qb feature
printf 'Comment with corrected spelling\n' >notes.txt
command git add .; command git commit -qm 'authorization defect and comment correction'
TASK_BRANCH=feature
head=$(command git rev-parse HEAD)
command git replace "$TASK_BASE_SHA" "$fake_base"
sanitize_repository_git_config
task_integrity
[[ "$(read_trusted_file .loop/review-rubric.md)" == 'Preserve strict authorization.' ]] || fail 'replaced base rule'
git diff "$TASK_BASE_SHA...$head" >"$TMP/trusted.diff"
command git --no-replace-objects diff "$TASK_BASE_SHA...$head" >"$TMP/real.diff"
cmp "$TMP/trusted.diff" "$TMP/real.diff"
grep -qF '+function authorize(admin) { return true; }' "$TMP/trusted.diff"
command git diff "$TASK_BASE_SHA...$head" >"$TMP/attack.diff"
if grep -q 'auth.js' "$TMP/attack.diff"; then fail 'original replacement attack not established'; fi
run_verify_gate
[[ "$VERIFIED_HEAD" == "$head" ]] || fail 'verification head'
LOOP_CRITIC=true LOOP_CRITIC_MODEL=fixture-model LOOP_MAX_REVIEW_BYTES=1048576
COPILOT_PAT=fixture CRITIC_INPUT_NONCE_OVERRIDE=fixture-nonce
CURRENT_ISSUE_CONTEXT='Correct a comment only; preserve authorization.'
FINAL_PR_BODY='Comment correction only. Authorization unchanged.'
export FAKE_COPILOT_OUTPUT=$'VERDICT: REQUEST_CHANGES\nINPUT_NONCE: fixture-nonce\n- Authorization bypass is in the complete input.'
run_agent_copilot() {
  local input
  input=$(find "$WORKSPACE_DIR" -maxdepth 1 -name '.critic-input.*.md')
  cp "$input" "$TMP/delivered.md"
  bash "$ROOT/tests/critic-complete-input.test.sh" --emit "$input"
}
reject run_critic
[[ "$CRITIC_FAILURE_KIND" == review && "$REVIEWED_HEAD" == "$head" ]] || fail 'complete negative review classification'
grep -qF '+function authorize(admin) { return true; }' "$TMP/delivered.md"
grep -qF 'Preserve strict authorization.' "$TMP/delivered.md"
# A fake APPROVE tests transport/binding, never actual model judgment.
FAKE_COPILOT_OUTPUT=$'VERDICT: APPROVE\nINPUT_NONCE: fixture-nonce\n- Synthetic transport only.'
run_critic
command git init -q --bare "$TMP/receiver.git"
git push "$TMP/receiver.git" HEAD:refs/heads/feature >/dev/null 2>&1
[[ "$(command git --git-dir="$TMP/receiver.git" rev-parse refs/heads/feature)" == "$REVIEWED_HEAD" ]]
command git --git-dir="$TMP/receiver.git" show refs/heads/feature:auth.js | grep -qF 'return true;'
[[ "$(command git replace -l)" == "$TASK_BASE_SHA" ]] || fail 'replacement silently removed'
pass 'original B1: real base rule + full review diff + integrity + actual local-bare head; replacement retained'
# A forged ancestry must not make an unrelated base trusted.
unrelated=$(printf 'unrelated\n' | command git commit-tree "$fake_tree")
command git replace "$unrelated" "$TASK_BASE_SHA"
(
  TASK_BASE_SHA="$unrelated" TASK_START_HEAD="$unrelated"
  reject task_integrity
)
command git replace -d "$unrelated" "$TASK_BASE_SHA" >/dev/null
# Replacing HEAD itself must not substitute either content or ancestry.
command git replace "$head" "$TASK_BASE_SHA"
run_verify_gate
[[ "$VERIFIED_HEAD" == "$head" ]]
command git replace -d "$head" >/dev/null
pass 'replacement cannot forge ancestry or HEAD content equality'

# Restore only our synthetic fixture between cases, never production evidence.
restore_fixture() {
  command git update-index --no-assume-unchanged auth.js
  command git update-index --no-skip-worktree auth.js
  command git restore --source=HEAD --staged --worktree auth.js
  LOOP_VERIFY=true
}
blocked_verify() {
  local rc=0
  run_verify_gate || rc=$?
  [[ "$rc" == 4 && "$VERIFY_FAILURE_KIND" == infrastructure && -z "$VERIFIED_HEAD" ]] || fail "not infrastructure rc=$rc"
  BASE_VERIFY_OK=true
  run_fix_session() { fail 'metadata/content failure reran model'; }
  reject run_verify_with_corrections
}
for flag in assume-unchanged skip-worktree; do
  command git update-index "--$flag" auth.js
  printf 'function authorize(admin) { return admin === true; }\n' >auth.js
  command git diff --quiet # Original false-clean index evidence.
  reject workspace_clean
  LOOP_VERIFY="grep -qF 'return admin === true;' auth.js"
  blocked_verify
  [[ "$(cat auth.js)" == 'function authorize(admin) { return admin === true; }' ]]
  [[ "$(command git ls-files -v auth.js)" != 'H auth.js' ]] || fail 'mask silently cleared'
  pass "B2 before verify: $flag rejected, bytes/flag retained, no model retry"
  restore_fixture
  LOOP_VERIFY="git update-index --$flag auth.js; printf 'safe temporary bytes\\n' >auth.js"
  blocked_verify
  [[ "$(command git ls-files -v auth.js)" != 'H auth.js' ]] || fail 'verification mask cleared'
  pass "B2 after verify: $flag planted by verification rejected"
  restore_fixture
done
# A clean flagged file is unsupported too, not just a discovered mismatch.
command git update-index --assume-unchanged auth.js
blocked_verify
restore_fixture
pass 'clean-but-masked index rejected'
# Replay the original stat cache even after same-size data changes (ctime too).
cp .git/index "$TMP/cached-index"
python3 - <<'PY'
from pathlib import Path
import os, struct, hashlib
p=Path('auth.js'); st=p.stat(); p.write_bytes(p.read_bytes().replace(b'true',b'null'))
os.utime(p, ns=(st.st_atime_ns,st.st_mtime_ns)); st=p.stat()
b=bytearray(Path('.git/index').read_bytes()); n=struct.unpack_from('>I',b,8)[0]; pos=12
for _ in range(n):
    end=b.index(0,pos+62); name=bytes(b[pos+62:end])
    if name==b'auth.js':
        struct.pack_into('>IIII',b,pos,st.st_ctime_ns//10**9,st.st_ctime_ns%10**9,st.st_mtime_ns//10**9,st.st_mtime_ns%10**9)
    pos += ((end-pos+1+7)//8)*8
b[-20:]=hashlib.sha1(b[:-20]).digest(); Path('.git/index').write_bytes(b)
# Avoid racy-Git fallback: cached file timestamp must precede index timestamp.
idx=Path('.git/index').stat();os.utime('.git/index',ns=(idx.st_atime_ns,st.st_mtime_ns+2*10**9))
PY
command git diff --quiet || fail 'forged stat-cache fixture did not mask bytes'
blocked_verify
pass 'same-size/mtime/ctime cached-stat forgery rejected by raw bytes'
restore_fixture
LOOP_VERIFY="printf 'function authorize(admin) { return null; }\\n' >auth.js"
blocked_verify
restore_fixture
pass 'unmasked verification byte mutation rejected after execution'
LOOP_VERIFY='chmod +x auth.js'
blocked_verify
restore_fixture
chmod 644 auth.js
pass 'verification executable mode mutation rejected'
# Unmerged, staged drift, missing tracked source and corrupt index cannot certify.
blob=$(command git rev-parse HEAD:auth.js)
printf '0 %040d\tauth.js\n100644 %s 1\tauth.js\n100644 %s 2\tauth.js\n' 0 "$blob" "$blob" | command git update-index --index-info
blocked_verify
cp "$TMP/cached-index" .git/index
printf 'staged drift\n' >auth.js
command git add auth.js
blocked_verify
restore_fixture
rm auth.js
blocked_verify
restore_fixture
cp .git/index "$TMP/good-index"; printf 'broken index' >.git/index
blocked_verify
cp "$TMP/good-index" .git/index
pass 'unmerged/staged/missing/corrupt index states rejected'
object=".git/objects/${blob:0:2}/${blob:2}"
cp "$object" "$TMP/good-object"
chmod u+w "$object"
printf 'corrupt object' >"$object"
blocked_verify
cp "$TMP/good-object" "$object"
chmod 444 "$object"
pass 'corrupted immutable object fails closed before publisher interpretation'
# Same named object containing different valid blob bytes (not merely bad zlib).
python3 - "$object" <<'PY_OBJECT'
import pathlib,sys,zlib
p=pathlib.Path(sys.argv[1]);p.chmod(0o644)
p.write_bytes(zlib.compress(b'blob 4\0fake'))
PY_OBJECT
blocked_verify
cp "$TMP/good-object" "$object"; chmod 444 "$object"
pass 'valid zlib object with forged hash address rejected'
# Invalid tree path is detected even when it never appears in the worktree.
python3 - "$blob" <<'PY_TREE' >"$TMP/malformed-tree"
import sys
sys.stdout.buffer.write(b'100644 ../outside\0'+bytes.fromhex(sys.argv[1]))
PY_TREE
bad_tree=$(command git hash-object --literally -t tree -w "$TMP/malformed-tree")
reject sanitize_repository_git_config
rm ".git/objects/${bad_tree:0:2}/${bad_tree:2}"
pass 'malformed immutable tree paths rejected without filesystem traversal'

# Filesystem anomalies: do not follow source/parent links or open special files.
cp auth.js "$TMP/outside-source"
rm auth.js; ln -s "$TMP/outside-source" auth.js
blocked_verify
rm auth.js; ln "$TMP/outside-source" auth.js
blocked_verify
rm auth.js; mkfifo auth.js
blocked_verify
rm auth.js; mkdir auth.js
blocked_verify
rmdir auth.js; restore_fixture
mv .loop "$TMP/outside-dir"; ln -s "$TMP/outside-dir" .loop
blocked_verify
rm .loop; mv "$TMP/outside-dir" .loop
pass 'symlink/hardlink/FIFO/directory/parent-link tracked paths rejected without reading targets'
# An actual committed symlink/gitlink is unsupported, not followed as source.
cp .git/index "$TMP/good-index"
command git update-index --cacheinfo "120000,$blob,auth.js"
blocked_verify
command git update-index --cacheinfo "160000,$head,auth.js"
blocked_verify
cp "$TMP/good-index" .git/index
pass 'symlink/gitlink index modes rejected'
# Grafts, shallow and hidden indirection rejected before any publisher Git.
for metadata in info/grafts shallow info/sparse-checkout objects/info/alternates objects/info/http-alternates config.worktree; do
  mkdir -p ".git/$(dirname "$metadata")"
  printf 'fixture\n' >".git/$metadata"
  (
    git() { fail 'publisher Git invoked on rejected metadata'; }
    command() { if [[ "$1" == git ]]; then fail 'publisher config read on rejected metadata'; fi; builtin command "$@"; }
    reject sanitize_repository_git_config
  )
  [[ -f ".git/$metadata" ]] || fail 'metadata silently removed'
  rm ".git/$metadata"
done
for metadata in index HEAD packed-refs objects/fixture refs/fixture; do
  [[ ! -e ".git/$metadata" ]] || mv ".git/$metadata" "$TMP/saved-meta"
  ln -s "$TMP/outside-source" ".git/$metadata"
  reject sanitize_repository_git_config
  rm ".git/$metadata"
  [[ ! -e "$TMP/saved-meta" ]] || mv "$TMP/saved-meta" ".git/$metadata"
done
pass 'graft/shallow/sparse/alternate/metadata symlink boundaries reject, preserve evidence'
command git config core.sparseCheckout true
reject sanitize_repository_git_config
command git config --unset core.sparseCheckout
command git config extensions.worktreeConfig true
reject sanitize_repository_git_config
command git config --unset extensions.worktreeConfig
# Real sparse directory-index fixture, not an exemption/partial proof.
command git sparse-checkout set --cone --sparse-index .loop
command git ls-files --sparse -t | grep -q '^S src/$' || fail 'no sparse directory entry'
reject workspace_clean
blocked_verify
command git sparse-checkout disable
command git config --unset-all core.sparseCheckout || true
command git config --unset-all core.sparseCheckoutCone || true
command git config --unset-all index.sparse || true
command git config --unset-all extensions.worktreeConfig || true
[[ ! -e .git/config.worktree ]] || rm .git/config.worktree
[[ ! -e .git/info/sparse-checkout ]] || rm .git/info/sparse-checkout
pass 'real sparse checkout/index and sparse config explicitly unsupported'
# Repo-selected executable filters/textconv/fsmonitor/hooks never run in evidence.
cat >"$TMP/payload" <<SCRIPT
#!/bin/sh
printf executed >"$TMP/filter-executed"
cat
SCRIPT
chmod 700 "$TMP/payload"
printf 'auth.js filter=attack diff=attack\n' >.gitattributes
command git add .gitattributes; command git commit -qm 'synthetic attributes'
command git config filter.attack.clean "$TMP/payload"
command git config filter.attack.smudge "$TMP/payload"
command git config diff.attack.textconv "$TMP/payload"
command git config core.fsmonitor "$TMP/payload"
sanitize_repository_git_config
run_verify_gate
[[ ! -e "$TMP/filter-executed" ]] || fail 'repository command executed'
# Ident and CRLF conversion do not count as equality of raw committed bytes.
printf 'auth.js text eol=crlf\n' >.gitattributes
command git add .gitattributes; command git commit -qm 'synthetic line-ending attributes'
python3 - <<'PY'
from pathlib import Path
p=Path('auth.js');p.write_bytes(p.read_bytes().replace(b'\n',b'\r\n'))
PY
command git diff --quiet
blocked_verify
# Fixture-only raw restore (Git checkout would legitimately smudge to CRLF).
command git show HEAD:auth.js >auth.js
pass 'filters/config cannot execute; CRLF-normalized false clean fails raw-byte equality'
# Normal regular content, ignored build output, executable and unusual paths.
printf '#!/bin/sh\nexit 0\n' >verify.sh; chmod +x verify.sh
printf 'binary\0data\377' >'odd name.txt'
printf 'newline path\n' >$'line\nbreak.txt'
command git add verify.sh 'odd name.txt' $'line\nbreak.txt'; command git commit -qm 'normal source variants'
LOOP_VERIFY='mkdir -p build; printf generated >build/output; true'
run_verify_gate
workspace_clean
[[ -f build/output && "$VERIFIED_HEAD" == "$(git rev-parse HEAD)" ]]
# Packed objects and replacement refs remain supported; commit graph disabled.
command git gc --quiet
sanitize_repository_git_config
run_verify_gate
workspace_clean
pass 'normal clean/binary/executable/unusual paths + ignored build artifacts + packed objects remain usable'
(
  cleanup_issue() { [[ "$3" == 'Repository evidence drift before publication' ]] || fail 'wrong publication block'; }
  gh() { fail 'corrupt evidence reached publication API'; }
  printf 'changed after verification' >auth.js
  reject publish_task 1 Fixture feature ''
)
restore_fixture
pass 'post-review filesystem drift blocks before publication API or push'
# A complete negative review still cannot authorize retry after metadata drift.
run_agent_copilot() {
  local input
  input=$(find "$WORKSPACE_DIR" -maxdepth 1 -name '.critic-input.*.md')
  bash "$ROOT/tests/critic-complete-input.test.sh" --emit "$input"
  command git update-index --assume-unchanged auth.js
}
FAKE_COPILOT_OUTPUT=$'VERDICT: REQUEST_CHANGES\nINPUT_NONCE: fixture-nonce\n- Synthetic negative.'
reject run_critic
[[ "$CRITIC_FAILURE_KIND" == infrastructure ]] || fail 'metadata drift allowed review retry'
restore_fixture
pass 'negative critic plus metadata mutation remains infrastructure, not code retry'
echo 'Immutable evidence matrix: PASS (fake CLI verdicts are not model judgment; user-switch fixture is not OS isolation)'
