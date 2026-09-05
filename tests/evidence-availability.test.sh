#!/usr/bin/env bash
# Offline N1/N2: real Git/checker/lifecycle, synthetic privilege/CLI/API transport.
# No network, no whole-store repair, no production policy bypass.
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
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
reject() { if "$@"; then fail "unexpected success: $*"; fi; }
agent_startup_canary() { return 0; }
retain_gate_log() { cp "$1" "$TMP/verify.log"; }
run_agent_command() { echo HANGAR_AGENT_STARTED; /usr/bin/bash --noprofile --norc -c "$1"; }
# Execute the actual persisted-volume entrypoint block, substituting only su's
# account/home setup (no such account here). The sanitizer is never mocked.
startup() (
  SESSION_USER=fixture
  su() {
    [[ "$*" == '- fixture -c source /home/fixture/.workspace_env && source /home/fixture/worker-loop.sh && sanitize_repository_git_config' ]] || return 99
    sanitize_repository_git_config
  }
  # shellcheck disable=SC2016 # Match literal production source.
  eval "$(sed -n '/^if \[\[ -d "\$WORKSPACE_DIR\/.git"/,/^fi/p' "$ROOT/worker/entrypoint.sh")"
)
# Local synthetic CLI proves delivery and binding, NOT review correctness.
LOOP_CRITIC=true LOOP_CRITIC_MODEL=fixture-model LOOP_MAX_REVIEW_BYTES=1048576
COPILOT_PAT=fixture CRITIC_INPUT_NONCE_OVERRIDE=fixture-nonce
CURRENT_ISSUE_CONTEXT='Change only the fixture file.' FINAL_PR_BODY='Synthetic fixture change.'
export FAKE_COPILOT_OUTPUT=$'VERDICT: APPROVE\nINPUT_NONCE: fixture-nonce\n- Synthetic transport only.'
run_agent_copilot() {
  local input
  input=$(find "$WORKSPACE_DIR" -maxdepth 1 -name '.critic-input.*.md')
  bash "$ROOT/tests/critic-complete-input.test.sh" --emit "$input"
}

# A normal clone from an owned bare receiver, no object hardlinks. Legacy trees
# are reachable ancestors, not unreachable stand-ins for N1.
for legacy in control zero-padded dotgit; do
  begin_task
  command git init -q -b main "$TMP/seed-$legacy"
  cd "$TMP/seed-$legacy"
  printf 'current\n' >app.txt
  mkdir .loop; printf 'Preserve the fixture.\n' >.loop/review-rubric.md
  command git add .; command git commit -qm initial
  initial=$(command git rev-parse HEAD)
  blob=$(command git rev-parse HEAD:app.txt)
  normal_tree=$(command git rev-parse 'HEAD^{tree}')
  if [[ "$legacy" != control ]]; then
    python3 - "$legacy" "$blob" <<'PY' >"$TMP/legacy-tree"
import sys
mode, name = (b'0100644', b'old.txt') if sys.argv[1]=='zero-padded' else (b'100644', b'.GIT')
sys.stdout.buffer.write(mode+b' '+name+b'\0'+bytes.fromhex(sys.argv[2]))
PY
    old_tree=$(command git hash-object --literally -t tree -w "$TMP/legacy-tree")
    old_commit=$(printf 'tree %s\nparent %s\nauthor Old <old@example.invalid> 1000000000 +0000\ncommitter Old <old@example.invalid> 1000000000 +0000\nencoding ISO-8859-1\n\nlegacy \351\n' "$old_tree" "$initial" | command git hash-object --literally -t commit -w --stdin)
    tip=$(printf 'ordinary current tree\n' | command git commit-tree "$normal_tree" -p "$old_commit")
    command git update-ref refs/heads/main "$tip"
  fi
  command git init -q --bare "$TMP/up-$legacy"
  command git push -q "$TMP/up-$legacy" main
  command git --git-dir="$TMP/up-$legacy" symbolic-ref HEAD refs/heads/main
  WORKSPACE_DIR="$TMP/clone-$legacy" CLEAN_REPO_URL="$TMP/up-$legacy"
  command git clone -q --no-hardlinks "$CLEAN_REPO_URL" "$WORKSPACE_DIR"
  cd "$WORKSPACE_DIR"
  command git fsck --no-reflogs --no-dangling >"$TMP/plain-fsck" 2>&1
  if [[ "$legacy" != control ]]; then
    reject command git fsck --strict --no-reflogs --no-dangling >"$TMP/strict-fsck" 2>&1
  fi
  startup
  sanitize_repository_git_config
  prepare_task_base "feature-$legacy"
  LOOP_VERIFY=true
  verify_clean_baseline
  printf 'work\n' >>app.txt; command git commit -qam work
  task_integrity
  run_verify_gate
  run_critic
  [[ "$REVIEWED_HEAD" == "$VERIFIED_HEAD" && "$VERIFIED_HEAD" == "$(git rev-parse HEAD)" ]] || fail binding
  fresh_base_unchanged
  # Exercise the real publish preconditions; stop at the authorization boundary
  # so this never mutates a remote API or fakes a publication verdict.
  (
    publication_authorized() { printf reached >"$TMP/authorized-$legacy"; PUBLICATION_BLOCK_REASON='fixture stop'; return 1; }
    cleanup_issue() { [[ "$3" == 'fixture stop' ]] || fail 'publication evidence rejected'; }
    gh() { fail 'unexpected API'; }
    reject publish_task 1 Fixture "$TASK_BRANCH" ''
  )
  [[ -f "$TMP/authorized-$legacy" ]] || fail 'publication admission not reached'
  prepare_task_base "revision-$legacy" false
  command git checkout -q "feature-$legacy"
  command git push -q origin "feature-$legacy"
  prepare_task_base "feature-$legacy" true
  pass "$legacy clone: startup, sanitizer, new/revision base, baseline, verification, critic, fresh-base and publication admission"
done

# Poison inside the real verification runner; no gc/prune/reset/clean is needed
# for this or a subsequent task. Preserve exact object bytes as evidence.
LOOP_VERIFY='printf "not a commit\n" | git hash-object --literally -t commit -w --stdin >/dev/null'
run_verify_gate
poison=$(printf 'not a commit\n' | command git hash-object --literally -t commit --stdin)
poison_path=".git/objects/${poison:0:2}/${poison:2}"
poison_hash=$(sha256sum "$poison_path")
reject command git fsck --strict --no-reflogs --no-dangling >"$TMP/poison-fsck" 2>&1
LOOP_VERIFY=true
begin_task
prepare_task_base after-garbage
verify_clean_baseline
printf 'next honest task\n' >>app.txt; command git commit -qam honest
run_verify_gate
run_critic
startup
[[ "$(sha256sum "$poison_path")" == "$poison_hash" ]] || fail 'garbage silently deleted/rewritten'
pass 'unreachable malformed object: planted during verification, preserved unchanged, later honest task and startup work without recovery'

# Genuine required object damage: invalid zlib AND valid but misaddressed bytes,
# covering commits, trees, blobs, base-only rules, ancestor commits, index-only
# blobs and caller-supplied roots that are not current HEAD.
base="$TASK_BASE_SHA"; head=$(git rev-parse HEAD)
base_tree=$(git rev-parse "$base^{tree}")
head_tree=$(git rev-parse 'HEAD^{tree}')
head_blob=$(git rev-parse HEAD:app.txt)
rule_blob=$(git rev-parse "$base:.loop/review-rubric.md")
ancestor=$(git rev-list --max-parents=0 HEAD)
# Current clone may pack objects; create independent loose copies for corruption
# testing without touching any pack or unrelated object.
for item in "commit:$head" "commit:$base" "commit:$ancestor" "tree:$head_tree" "tree:$base_tree" "blob:$head_blob" "blob:$rule_blob"; do
  type=${item%%:*}; oid=${item#*:}
  path=".git/objects/${oid:0:2}/${oid:2}"
  mkdir -p "$(dirname "$path")"
  git cat-file "$type" "$oid" >"$TMP/raw"
  python3 - "$type" "$TMP/raw" "$path" <<'PY'
import pathlib,sys,zlib
b=pathlib.Path(sys.argv[2]).read_bytes()
p=pathlib.Path(sys.argv[3]); p.chmod(0o644) if p.exists() else None
p.write_bytes(zlib.compress(sys.argv[1].encode()+b' '+str(len(b)).encode()+b'\0'+b))
PY
  cp "$path" "$TMP/object.good"
  for damage in zlib hash; do
    if [[ "$damage" == zlib ]]; then printf broken >"$path"
    else
      python3 - "$type" "$path" <<'PY'
import pathlib,sys,zlib
pathlib.Path(sys.argv[2]).write_bytes(zlib.compress(sys.argv[1].encode()+b' 4\0fake'))
PY
    fi
    bad_hash=$(sha256sum "$path")
    reject sanitize_repository_git_config >"$TMP/block" 2>&1
    reject startup >"$TMP/startup-block" 2>&1
    reject task_integrity >>"$TMP/block" 2>&1
    rc=0; run_verify_gate >>"$TMP/block" 2>&1 || rc=$?
    [[ "$rc" == 4 && -z "$VERIFIED_HEAD" && "$VERIFY_FAILURE_KIND" == infrastructure ]] || fail 'corruption accepted'
    grep -q 'Preserve the checkout; operator:' "$TMP/block" || fail 'not actionable'
    if grep -qE "$oid|$WORKSPACE_DIR|not a commit|fake|fatal:|error:" "$TMP/block"; then fail 'error leaks raw Git details'; fi
    [[ "$(sha256sum "$path")" == "$bad_hash" ]] || fail 'damaged evidence changed'
    cp "$TMP/object.good" "$path"
  done
  sanitize_repository_git_config
  pass "required $type object ($oid): invalid compression and forged hash address rejected, explicit fixture restoration readmits"
done
# A forged object not in HEAD is still checked when an independent caller binds it.
extra_blob=$(printf 'extra input\n' | command git hash-object -w --stdin)
extra_tree=$(printf '100644 blob %s\textra.txt\n' "$extra_blob" | command git mktree)
extra_commit=$(printf 'independent base\n' | command git commit-tree "$extra_tree")
extra_path=".git/objects/${extra_blob:0:2}/${extra_blob:2}"
cp "$extra_path" "$TMP/extra.good"; chmod u+w "$extra_path"; printf broken >"$extra_path"
sanitize_repository_git_config
reject check_repository_evidence index "$extra_commit"
(
  TASK_BASE_SHA="$extra_commit"; reject read_trusted_file extra.txt
)
(
  TASK_START_HEAD="$extra_commit"; reject sanitize_repository_git_config
)
(
  LOOP_CHECK_BACKEND=actions LOOP_CONDITIONAL_WORKFLOWS='[{"workflow":"CI","checks":["unit"],"paths":["**"]}]'
  reject resolve_check_policy "$extra_commit" "$head"
)
cp .git/index "$TMP/index.good"
command git update-index --add --cacheinfo "100644,$extra_blob,staged.txt"
reject sanitize_repository_git_config
cp "$TMP/index.good" .git/index
cp "$TMP/extra.good" "$extra_path"
check_repository_evidence index "$extra_commit"
pass 'explicit input/base/start/selector roots and staged-only blobs are hash bound, not just HEAD'

# Historical blobs/trees unused by evidence are deliberately NOT inspected.
# Remove neither bytes nor evidence: poison a historic-only blob in a fresh repo.
(
  WORKSPACE_DIR="$TMP/history-scope"; mkdir "$WORKSPACE_DIR"; cd "$WORKSPACE_DIR"
  TASK_BASE_SHA='' TASK_START_HEAD=''
  command git init -q -b main
  printf historic >old.txt; command git add .; command git commit -qm old
  old_blob=$(command git rev-parse HEAD:old.txt)
  command git rm -q old.txt
  printf current >current.txt; command git add .; command git commit -qm current
  old_path=".git/objects/${old_blob:0:2}/${old_blob:2}"
  chmod u+w "$old_path"; printf 'unused historical corrupt blob' >"$old_path"
  startup
  run_verify_gate
  reject check_repository_evidence index "$(git rev-parse HEAD^)"
)
pass 'unused historic blobs not read; selecting that historic snapshot makes its damage required'

# Current unsafe trees are rejected even if Git normalizes their ls-tree view.
for shape in zero dotgit traversal unsorted duplicate symlink gitlink wrong-type; do
  python3 - "$shape" "$head_blob" "$head" <<'PY' >"$TMP/bad-tree"
import sys
shape=sys.argv[1]; b=bytes.fromhex(sys.argv[2]); c=bytes.fromhex(sys.argv[3])
rows={'zero':[(b'0100644',b'file',b)],'dotgit':[(b'100644',b'.GIT',b)],
      'traversal':[(b'100644',b'../outside',b)],'unsorted':[(b'100644',b'z',b),(b'100644',b'a',b)],
      'duplicate':[(b'100644',b'a',b),(b'100644',b'a',b)],'symlink':[(b'120000',b'link',b)],
      'gitlink':[(b'160000',b'module',c)],'wrong-type':[(b'40000',b'dir',b)]}[shape]
sys.stdout.buffer.write(b''.join(m+b' '+n+b'\0'+o for m,n,o in rows))
PY
  bad_tree=$(command git hash-object --literally -t tree -w "$TMP/bad-tree")
  bad_commit=$(printf 'tree %s\nparent %s\nauthor X <x@example.invalid> 1000000000 +0000\ncommitter X <x@example.invalid> 1000000000 +0000\n\nunsafe snapshot\n' "$bad_tree" "$head" | command git hash-object --literally -t commit -w --stdin)
  command git update-ref HEAD "$bad_commit"
  reject sanitize_repository_git_config
  # Hiding the unsafe snapshot behind a safe tip must not launder newly
  # introduced history into a push. The task base determines old vs new.
  safe_tip=$(printf 'revert unsafe snapshot\n' | command git commit-tree "$head_tree" -p "$bad_commit")
  command git update-ref HEAD "$safe_tip"
  reject sanitize_repository_git_config
  command git update-ref HEAD "$head"
  sanitize_repository_git_config
  pass "current/newly introduced unsafe tree $shape rejected, including later revert; unrelated malformed tree retained"
done
# Hash-valid but structurally damaged commit is still not ancestry evidence.
malformed=$(printf 'tree %s\nparent %s\nauthor X <x@example.invalid> 1000000000 +0000\ncommitter X <x@example.invalid>1000000000 +0000\n\nbad header\n' "$head_tree" "$head" | command git hash-object --literally -t commit -w --stdin)
command git update-ref HEAD "$malformed"
reject sanitize_repository_git_config
command git update-ref HEAD "$head"
sanitize_repository_git_config
pass 'hash-valid malformed required commit header rejected; unrelated copy retained'
# Production protection is identical with/without the ambient override; only
# intentional vulnerable controls elsewhere need it unset.
command git replace "$head" "$base"
for override in unset set; do
  (
    if [[ "$override" == set ]]; then export GIT_NO_REPLACE_OBJECTS=1; else unset GIT_NO_REPLACE_OBJECTS; fi
    run_verify_gate
    [[ "$VERIFIED_HEAD" == "$head" ]] || fail 'ambient replacement dependence'
    [[ "$(read_trusted_file .loop/review-rubric.md)" == 'Preserve the fixture.' ]] || fail 'replaced trusted input'
  )
done
[[ "$(command git replace -l)" == "$head" ]] || fail 'replacement ref lost'
command git replace -d "$head" >/dev/null
pass 'explicit production replacement protection works with ambient flag unset and set'
# Packed raw objects (including >32 MiB blob) use bounded streaming, not the
# inventory buffer and not a loose-only hashing shortcut. No gc is performed.
python3 - <<'PY' >large.bin
import sys
sys.stdout.buffer.write(b'x'*(33*1024*1024))
PY
command git add large.bin; command git commit -qm 'streamed blob'
command git rev-list --objects HEAD | awk '{print $1}' | command git pack-objects .git/objects/pack/pack >"$TMP/pack-id"
# Prefer the packed copy by moving only this fixture's loose blob to an owned
# backup, not deleting it or repairing a real store.
large=$(command git rev-parse HEAD:large.bin)
mv ".git/objects/${large:0:2}/${large:2}" "$TMP/large.loose"
run_verify_gate
[[ -f "$TMP/large.loose" && -f "$poison_path" ]] || fail 'fixture evidence missing'
pass 'packed large required blob streams beyond inventory ceiling; unreachable garbage remains intact'
# A valid pack/index can lie about an object's name. Git cat-file happily
# returns that data: the worker must independently reject the hash mismatch.
(
  WORKSPACE_DIR="$TMP/forged-pack"; mkdir "$WORKSPACE_DIR"; cd "$WORKSPACE_DIR"
  TASK_BASE_SHA='' TASK_START_HEAD=''
  command git init -q -b main
  printf honest >pack-target.txt; command git add .; command git commit -qm packed
  oid=$(command git rev-parse HEAD:pack-target.txt)
  mv ".git/objects/${oid:0:2}/${oid:2}" "$TMP/packed-original"
  for payload in forged honest; do
    python3 - "$oid" "$payload" <<'PY_PACK'
from pathlib import Path
import hashlib, struct, sys, zlib
sha=lambda x:hashlib.sha1(x).digest()
oid=bytes.fromhex(sys.argv[1]); data=sys.argv[2].encode()
entry=bytes([0x30+len(data)])+zlib.compress(data)
body=b'PACK'+struct.pack('>II',2,1)+entry
pack_hash=sha(body); packed=body+pack_hash
# Version-2 index: one falsely named object, valid fanout/CRC/offset/checksums.
idx=b'\xfftOc'+struct.pack('>I',2)+b''.join(struct.pack('>I',int(i>=oid[0])) for i in range(256))
idx+=oid+struct.pack('>II',zlib.crc32(entry),12)+pack_hash
stem=Path('.git/objects/pack/pack-fixture')
stem.with_suffix('.pack').write_bytes(packed)
stem.with_suffix('.idx').write_bytes(idx+sha(idx))
PY_PACK
    [[ "$(command git cat-file blob "$oid")" == "$payload" ]] || fail 'forged pack attack not established'
    if [[ "$payload" == forged ]]; then reject run_verify_gate; else run_verify_gate; fi
  done
)
pass 'misaddressed packed blob with valid pack/index checksums rejected by raw hash; correct pack readmits'
(
  TASK_DEADLINE=$(( $(date +%s) - 1 ))
  reject check_repository_evidence index
)
pass 'expired task deadline fails closed'
echo 'Evidence availability matrix: PASS (local transport, no OS/image/model acceptance)'
