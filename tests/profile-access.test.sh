#!/usr/bin/env bash
# Synthetic path-permission and launcher-wiring regressions; no network/models.
# shellcheck disable=SC2034,SC2317,SC2329,SC2218
# command node executes the real binary before a later launcher-only node mock.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export GITHUB_OWNER=example GITHUB_REPO=fixture
source "$ROOT/worker/worker-loop.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
reject() { if "$@"; then fail 'unexpected acceptance'; fi; }
LOOP_PROFILE_DIR=''
configure_profile_access
test "${#COPILOT_PROFILE_ACCESS_ARGS[@]}" = 0
# Exercise exact embedded filesystem validator with synthetic stat metadata.
command node - "$ROOT/worker/worker-loop.sh" <<'NODE'
const fs=require('fs'),vm=require('vm'),path=require('path'),assert=require('assert/strict');
const source=fs.readFileSync(process.argv[2],'utf8');
const script=source.split("<<'PROFILE_ACCESS'\n")[1].split('\nPROFILE_ACCESS')[0];
assert(script);
function tree(){return {'/':{dir:true},'/etc':{dir:true},'/etc/profile':{dir:true},'/etc/profile/implementer.md':{file:true,size:10},'/etc/profile/verify.sh':{file:true,size:10}};}
function check(nodes,root='/etc/profile',limit=1000){
 let denied=false,reads=0;
 const mock={lstatSync(p){const n=nodes[p];if(!n)throw Error('ENOENT');return {uid:n.uid??0,mode:n.mode??(n.dir?0o755:0o444),size:n.size??0,isDirectory:()=>!!n.dir,isFile:()=>!!n.file};},readdirSync(p){return Object.keys(nodes).filter(x=>x!==p&&path.dirname(x)===p).map(x=>path.basename(x));},readFileSync(){reads++;throw Error('must not read profile contents for validation');}};
 vm.runInNewContext(script,{require:n=>n==='fs'?mock:require(n),process:{argv:['node','-',root,String(limit)],exit(){denied=true;}},console:{error(){}}});
 assert.equal(reads,0);return !denied;
}
assert(check(tree()));
for(const mutate of [t=>{t['/etc'].uid=123;},t=>{t['/etc'].mode=0o777;},t=>{t['/etc/profile'].dir=false;},t=>{t['/etc/profile'].mode=0o700;},t=>{t['/etc/profile/link']={};},t=>{t['/etc/profile/socket']={};},t=>{t['/etc/profile/verify.sh'].uid=1000;},t=>{t['/etc/profile/verify.sh'].mode=0o666;},t=>{t['/etc/profile/verify.sh'].mode=0o600;},t=>{delete t['/etc/profile/implementer.md'];},t=>{t['/etc/profile/huge']={file:true,size:1001};},t=>{for(let i=0;i<257;i++)t['/etc/profile/f'+i]={file:true};}]){const t=tree();mutate(t);assert(!check(t));}
for(const root of ['/','relative','/etc/profile/../profile','/etc/profile/'])assert(!check(tree(),root));
assert(!check(tree(),'/etc/profile',0));
console.log('PASS: exact profile validator rejects untrusted ancestry, symlinks/special files, writes, unreadability, missing contracts and budget overflow');
NODE
# CLI scope: only the exact profile path; tools/URL denials are preserved.
LOOP_PROFILE_DIR='/etc/profile fixture'
findmnt() { printf '%s\n' "${MOUNT_OPTIONS:-ro,relatime}"; }
node() { command cat >/dev/null; return 0; }
configure_profile_access
[[ "${COPILOT_PROFILE_ACCESS_ARGS[*]}" == '--add-dir /etc/profile fixture' ]] || fail 'exact path grant missing'
MOUNT_OPTIONS=rw,relatime
reject configure_profile_access
test "${#COPILOT_PROFILE_ACCESS_ARGS[@]}" = 0
MOUNT_OPTIONS=ro,relatime
terminate_agent_processes() { :; }
task_seconds_remaining() { echo 20; }
timeout() { shift 2; "$@"; }
sudo() { shift; command cat >/dev/null; printf '%s\n' "$@" >"$TMP/args"; }
run_agent_copilot synthetic-inference-token -p fixture --deny-tool=shell --deny-tool=write
[[ "$(sed -n '3p' "$TMP/args")" == '--add-dir' && "$(sed -n '4p' "$TMP/args")" == "$LOOP_PROFILE_DIR" ]] || fail 'launcher path grant missing'
grep -qx -- '--deny-tool=shell' "$TMP/args"
grep -qx -- '--deny-tool=write' "$TMP/args"
if grep -Eq -- '^--(allow-all|allow-all-paths|yolo)$' "$TMP/args"; then fail 'blanket access added'; fi
MOUNT_OPTIONS=rw
cp "$TMP/args" "$TMP/before"
reject run_agent_copilot synthetic-inference-token -p rejected
cmp "$TMP/args" "$TMP/before"
echo 'PASS: exact path grant through real run_agent_copilot wiring, no blanket permissions, invalid profile fails before launcher'
