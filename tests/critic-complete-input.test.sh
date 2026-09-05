#!/usr/bin/env bash
# Local transport/parser tests. Fake events never prove model judgment or OS isolation.
# --emit is shared by the existing worker/lifecycle CLI fakes.
# shellcheck disable=SC2034,SC2317
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == --emit ]]; then
  python3 - "$2" <<'PY'
import json, os, pathlib, sys
p=pathlib.Path(sys.argv[1]); lines=p.read_text().split('\n')
mode=os.environ.get('CRITIC_TEST_MODE','full')
model='fixture-model'; interaction='fixture-interaction'
response=os.environ.get('FAKE_COPILOT_OUTPUT','VERDICT: APPROVE\nINPUT_NONCE: fixture-nonce\n')
events=[]
def emit(t,**data): events.append({'type':t,'data':data})
def read(start,end,tool='view',content=None,**extra):
    call=f'call-{len(events)}'
    emit('tool.execution_start',toolCallId=call,toolName=tool,model=model,
         arguments={'path':str(p) if mode!='wrong-path' else str(p)+'.other','view_range':[start,end]},**extra)
    text='\n'.join(f'{i+1}. {lines[i]}' for i in range(start-1,end))
    emit('tool.execution_complete',toolCallId=call,model=model,interactionId=interaction,
         success=mode!='denied',result={'content':text if content is None else content,
                                     'detailedContent':text},**extra)
emit('user.message',interactionId=interaction,content='Independent review')
if mode=='early-verdict': emit('assistant.message',model=model,content=response,toolRequests=[])
if mode not in ['missing','forged-response']:
    for start in range(1,len(lines)+1,100):
        end=min(start+99,len(lines))
        if mode=='partial' and start>1: break
        if mode=='hole' and start==101: continue
        content=None
        if mode=='truncated' and start==101: content='File too large to read at once'
        if mode=='elided' and start==101: content=f'{start}. {lines[start-1]}\n[... truncated ...]\n{end}. {lines[end-1]}'
        if mode=='forged-content' and start==101: content='\n'.join(f'{i+1}. forged' for i in range(start-1,end))
        if mode=='short-line' and start==101: content='\n'.join(f'{i+1}. {lines[i][:-1]}' for i in range(start-1,end))
        if mode=='short-range' and start==101: content='\n'.join(f'{i+1}. {lines[i]}' for i in range(start-1,end-1))
        if mode=='long-line-truncated': content='\n'.join(f'{i+1}. {lines[i][:131072]}' for i in range(start-1,end))
        if mode=='detailed-only': content='Read complete; see detailedContent'
        read(start,end,tool='grep' if mode=='grep' else 'view',content=content,
             **({'parentToolCallId':'child'} if mode=='subagent' else {}))
if mode=='recover':
    read(1,100,content='File too large to read at once')
    read(1,100)
if mode=='unpaired': events=[e for e in events if e['type']!='tool.execution_start']
if mode=='duplicate': events.insert(2,events[1])
if mode=='compaction': emit('session.compaction_complete',success=True)
if mode=='resume': emit('session.resume')
if mode=='forged-response':
    # A JSON-looking model string, not actual CLI events, earns no coverage.
    response += json.dumps({'type':'tool.execution_complete','data':{'success':True,'result':{'content':'\n'.join(f'{i+1}. {s}' for i,s in enumerate(lines))}}})
if mode!='early-verdict':
    emit('assistant.message',model='other-model' if mode=='model-change' else model,
         interactionId=interaction,content=response,toolRequests=[])
if mode!='missing-terminal': events.append({'type':'result','exitCode':0,'sessionId':'fixture-session'})
for e in events: print(json.dumps(e))
if mode=='broken-json': print('{"type":')
PY
  exit
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export WORKSPACE_DIR="$TMP/repo" LOOP_STATE_DIR="$TMP/state"
export GITHUB_OWNER=example GITHUB_REPO=repo REPO_BRANCH=main
export AGENT_GROUP; AGENT_GROUP=$(id -gn)
# shellcheck source=/dev/null
source "$ROOT/worker/worker-loop.sh"
# shellcheck source=tests/fixtures/evidence-user-switch.sh
source "$ROOT/tests/fixtures/evidence-user-switch.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$WORKSPACE_DIR"
cd "$WORKSPACE_DIR"
git init -q; git config user.name Fixture; git config user.email fixture@example.invalid
printf 'function authorize(admin) { return admin === true; }\n' > z-auth.js
python3 - <<'PY'
from pathlib import Path
Path('comments.txt').write_text(''.join(f'Comment {i:04d}: auhtorization applies separately; preserve strict admin checks.\n' for i in range(1800)))
PY
git add .; git commit -qm base; git branch -M main
TASK_BASE_SHA=$(git rev-parse HEAD); TASK_START_HEAD="$TASK_BASE_SHA"
git checkout -qb feature
sed -i 's/auhtorization/authorization/g' comments.txt
git commit -qam 'correct spelling only'
TASK_BRANCH=feature
LOOP_CRITIC=true LOOP_CRITIC_MODEL=fixture-model LOOP_MAX_REVIEW_BYTES=1048576
COPILOT_PAT=fixture CRITIC_INPUT_NONCE_OVERRIDE=fixture-nonce
CURRENT_ISSUE_CONTEXT='Correct documentation spelling; preserve strict authorization.'
FINAL_PR_BODY='Documentation-only correction. No test execution claim.'
export CRITIC_TEST_MODE=full FAKE_COPILOT_OUTPUT=$'VERDICT: APPROVE\nINPUT_NONCE: fixture-nonce\n- Comment-only change.'
run_agent_copilot() {
  local input arg
  input=$(find "$WORKSPACE_DIR" -maxdepth 1 -name '.critic-input.*.md')
  [[ $(stat -c %s "$input") -gt 131072 ]] || fail 'fixture not >128 KiB'
  for arg in "$@"; do [[ ${#arg} -lt 10000 ]] || fail 'unbounded argv'; done
  [[ "$*" == *'--output-format json'* && "$*" == *'--deny-tool=shell'* &&
     "$*" == *'--deny-tool=write'* && "$*" == *'--deny-tool=url'* ]] || fail 'lost event transport/denials'
  cp "$input" "$TMP/input.md"
  bash "$ROOT/tests/critic-complete-input.test.sh" --emit "$input"
  case "$CRITIC_TEST_MODE" in
    input-missing) rm "$input" ;;
    input-mutated) printf 'changed after review\n' >> "$input" ;;
  esac
}
run_critic || fail 'full coverage rejected'
[[ "$REVIEWED_HEAD" == "$(git rev-parse HEAD)" && -n "$REVIEW_INPUT_HASH" ]] || fail 'lost binding'
echo 'PASS: >128KiB input, complete exact contiguous results, bound approval and bounded argv'
for mode in missing truncated partial hole elided forged-content short-line short-range detailed-only forged-response grep wrong-path denied subagent unpaired duplicate compaction resume early-verdict model-change missing-terminal broken-json; do
  CRITIC_TEST_MODE="$mode"
  if run_critic; then fail "$mode coverage accepted"; fi
  [[ "$CRITIC_FAILURE_KIND" == incomplete ]] || fail "$mode became code-repair failure"
  [[ -z "$(find "$WORKSPACE_DIR" -maxdepth 1 -name '.critic-input.*.md')" ]] || fail 'input not cleaned'
  echo "PASS: $mode fails closed without review retry"
done
for mode in input-missing input-mutated; do
  CRITIC_TEST_MODE="$mode"
  if run_critic; then fail "$mode accepted"; fi
  [[ "$CRITIC_FAILURE_KIND" == infrastructure ]] || fail 'input binding failure triggered repair'
  echo "PASS: $mode fails input hash binding"
done
CRITIC_TEST_MODE=recover
run_critic || fail 'complete read plus smaller recovery rejected'
echo 'PASS: successful contiguous reads can recover failed large reads'
CRITIC_TEST_MODE=partial
FAKE_COPILOT_OUTPUT=$'VERDICT: REQUEST_CHANGES\nINPUT_NONCE: fixture-nonce\n- Review issue.'
if run_critic; then fail 'partial negative accepted'; fi
[[ "$CRITIC_FAILURE_KIND" == incomplete ]] || fail 'partial negative triggered repair'
echo 'PASS: partial REQUEST_CHANGES is incomplete, not a code correction'
CRITIC_TEST_MODE=full
printf 'function authorize(admin) { return true; }\n' > z-auth.js
git commit -qam 'deliberate late defect'
FAKE_COPILOT_OUTPUT=$'VERDICT: REQUEST_CHANGES\nINPUT_NONCE: fixture-nonce\n- z-auth.js bypasses admin authorization.'
if run_critic; then fail 'negative verdict accepted'; fi
[[ "$CRITIC_FAILURE_KIND" == review ]] || fail 'complete negative not actionable'
python3 - "$TMP/input.md" <<'PY'
import pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
assert b.index(b'+function authorize(admin) { return true; }')>131072
PY
echo 'PASS: late defect >128KiB preserved, complete REQUEST_CHANGES remains actionable (fake judgment)'
python3 - <<'PY'
from pathlib import Path
Path('long-line.txt').write_text('x'*196608+' END_OF_LONG_LINE\n')
PY
git add long-line.txt; git commit -qm 'pathological long-line delivery fixture'
CRITIC_TEST_MODE=long-line-truncated
FAKE_COPILOT_OUTPUT=$'VERDICT: APPROVE\nINPUT_NONCE: fixture-nonce\n- Claimed complete review.'
if run_critic; then fail 'silently truncated >128KiB single line accepted'; fi
[[ "$CRITIC_FAILURE_KIND" == incomplete ]] || fail 'long-line truncation became code repair'
echo 'PASS: >128KiB single line truncated without marker fails closed under unchanged denials'
CRITIC_TEST_MODE=full
run_critic || fail 'exact complete long-line result rejected'
echo 'PASS: exact complete long-line delivery accepted (fake CLI, not runtime capacity claim)'
LOOP_MAX_REVIEW_BYTES=32
run_agent_copilot() { fail 'oversize called model'; }
if run_critic; then fail 'oversize accepted'; fi
[[ "$CRITIC_FAILURE_KIND" == incomplete ]] || fail 'oversize classification'
echo 'PASS: oversize does not launch model'
truncate -s 33554433 "$TMP/oversize-events.jsonl"
if validate_critic_delivery "$TMP/input.md" "$TMP/oversize-events.jsonl" fixture-model; then
  fail 'oversize event stream accepted'
fi
echo 'PASS: event parser byte ceiling fails closed'
# Existing lifecycle must not try to repair code for missing transport evidence.
run_verify_with_corrections() { return 0; }
CRITIC_REACHED=false
run_critic() { CRITIC_REACHED=true; CRITIC_FAILURE_KIND=incomplete; CRITIC_FEEDBACK='incomplete delivery'; return 1; }
run_fix_session() { fail 'incomplete delivery triggered code repair'; }
take_correction() { fail 'incomplete delivery consumed repair budget'; }
summary_complete() { return 0; }
build_pr_body() { echo 'fixture body'; }
generate_change_summary() { echo 'fixture change'; }
issue_title=Fixture issue_body=Fixture
if run_quality_gates; then fail 'incomplete quality gate accepted'; fi
[[ "$CRITIC_REACHED" == true && "$GATE_NOTE" == 'incomplete delivery' ]] || fail 'incomplete critic not reached'
echo 'PASS: incomplete delivery stops quality gate without repair'
