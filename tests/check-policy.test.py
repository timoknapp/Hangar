#!/usr/bin/env python3
"""Offline selector regressions: real immutable Git diff; fake Actions/leases.
No credentials, network, repository scripts, real model or publication.
"""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parents[1] / 'worker/worker-loop.sh'

with tempfile.TemporaryDirectory(prefix='hangar-check-policy-') as directory:
    root = Path(directory)
    repo = root / 'repo'
    repo.mkdir()
    env = dict(PATH=os.environ['PATH'], HOME=str(root), LANG='C.UTF-8',
               GITHUB_OWNER='example', GITHUB_REPO='fixture', REPO_BRANCH='main',
               WORKSPACE_DIR=str(repo), LOOP_STATE_DIR=str(root / 'state'),
               LOOP_CHECK_BACKEND='actions', LOOP_REQUIRED_CHECKS='["unit"]',
               LOOP_REQUIRED_WORKFLOWS='["CI"]', LOOP_IGNORED_WORKFLOWS='[]',
               LOOP_CONDITIONAL_WORKFLOWS=json.dumps([
                   dict(workflow='Dependency Review', checks=['audit'],
                        paths=['policy/**', 'packages/**/package.json', 'owners/*/charter.md'])]),
               SOURCE=str(SOURCE), FIXTURE=str(root))

    def git(*args):
        return subprocess.check_output(['git', '-c', 'core.hooksPath=/dev/null',
                                        '-c', 'core.fsmonitor=false', *args],
                                       cwd=repo, env=env, text=True, stderr=subprocess.DEVNULL).strip()

    git('init', '-q', '-b', 'main')
    git('config', 'user.name', 'Offline fixture')
    git('config', 'user.email', 'fixture@example.invalid')
    (repo / 'policy').mkdir()
    (repo / 'policy/config.json').write_text('{}\n')
    git('add', '.')
    git('commit', '-qm', 'baseline')
    base = git('rev-parse', 'HEAD')
    git('checkout', '-qb', 'feature')
    git('mv', 'policy/config.json', 'moved.json')  # rename OUT must still select
    git('commit', '-qm', 'move selected path')
    head = git('rev-parse', 'HEAD')
    env.update(BASE=base, HEAD_SHA=head)
    shell = '''set -euo pipefail
source "$SOURCE"
source "$(dirname "$SOURCE")/../tests/fixtures/evidence-user-switch.sh"
trap - SIGINT SIGTERM
cd "$WORKSPACE_DIR"
gh() {
  if [[ "$*" == *'--json'* && "$*" == *baseRefOid* ]]; then
    echo 'Unknown JSON field: baseRefOid (deployed CLI compatibility fixture)' >&2; return 96
  fi
  if [[ "$1 $2" == 'pr view' ]]; then
    if [[ "$*" == *'--json number'* ]]; then echo 7
    elif [[ "$*" == *'--jq .isDraft'* ]]; then echo true; else cat "$FIXTURE/meta.json"; fi
    return
  fi
  if [[ "$1" == api && "$2" == */pulls/7 ]]; then
    jq '{state:(if .state=="OPEN" then "open" else "closed" end),draft:.isDraft,
      merged:(.state=="MERGED"),head:{sha:.headRefOid},base:{sha:.baseRefOid},body,
      mergeable:(if .mergeable=="MERGEABLE" then true elif .mergeable=="CONFLICTING" then false else null end)}' "$FIXTURE/meta.json"; return
  fi
  if [[ "$*" == *'--method GET'* ]]; then cat "$FIXTURE/runs.json"; return; fi
  if [[ "$2" =~ /runs/([0-9]+)/attempts/([0-9]+)/jobs ]]; then
    printf '%s\n' "$2" >>"$FIXTURE/requests"
    cat "$FIXTURE/jobs-${BASH_REMATCH[1]}-${BASH_REMATCH[2]}.json"; return
  fi
  echo 'Unexpected fake API operation' >&2; return 97
}
'''

    def call(code, expected=0, extra=None, data=None):
        current = dict(env)
        current.update(extra or {})
        p = subprocess.run(['bash', '--noprofile', '--norc', '-c', shell + code],
                           cwd=repo, env=current, input=data, capture_output=True,
                           text=True, timeout=20)
        assert p.returncode == expected, (code, expected, p.returncode, p.stdout, p.stderr)
        return p

    def selected(paths):
        p = call('select_check_policy "$BASE" "$HEAD_SHA"', data=''.join(p + '\0' for p in paths))
        return 'Dependency Review' in json.loads(p.stdout)['requiredWorkflows']

    cases = 0

    def passed(name):
        global cases
        cases += 1
        print('PASS:', name)

    for paths, wanted in [([], False), (['docs/notes.md'], False),
                          (['policy/a/b.json'], True), (['packages/package.json'], True),
                          (['packages/a/b/package.json'], True), (['owners/alice/charter.md'], True),
                          (['owners/a/b/charter.md'], False), (['Policy/file'], False)]:
        assert selected(paths) == wanted
    passed('positive path semantics: zero/multiple ** directories, single *, case, unrelated')
    result = json.loads(call('resolve_check_policy "$BASE" "$HEAD_SHA"').stdout)
    assert result['conditionalChecks'] == [dict(workflow='Dependency Review', name='audit')]
    passed('real complete immutable diff detects rename/deletion out of selected path')
    git('replace', head, base)
    assert json.loads(call('resolve_check_policy "$BASE" "$HEAD_SHA"').stdout) == result
    git('replace', '-d', head)
    passed('repository replacement refs cannot hide immutable path changes')
    assert 'Dependency Review' not in json.loads(call('resolve_check_policy "$BASE" "$BASE"').stdout)['requiredWorkflows']
    passed('base==head never invents changed-path requirements')
    call('resolve_check_policy "$BASE" 0000000000000000000000000000000000000000', expected=1)
    passed('missing immutable object fails closed')
    for pattern in ['../policy/**', '!policy/**', '[ab]/**', '{a,b}/**', '/policy/**', 'policy//**', 'policy/a**b']:
        invalid = json.dumps([dict(workflow='Dependency Review', checks=['audit'], paths=[pattern])])
        call('init_loop_state', expected=1, extra=dict(LOOP_CONDITIONAL_WORKFLOWS=invalid))
    call('init_loop_state', expected=1, extra=dict(LOOP_CHECK_BACKEND='checks'))
    call('init_loop_state', expected=1, extra=dict(LOOP_IGNORED_WORKFLOWS='["CI"]'))
    call('init_loop_state', expected=1, extra=dict(LOOP_IGNORED_WORKFLOWS='["Dependency Review"]'))
    passed('invalid selectors/backend and required-workflow exclusions rejected at startup')
    call('select_check_policy "$BASE" "$HEAD_SHA"', expected=1, data='policy/no-terminator')
    call('select_check_policy "$BASE" "$HEAD_SHA"', expected=1, data='policy/line\nbreak\0')
    call('select_check_policy "$BASE" "$HEAD_SHA"', expected=1, data='p\0' * 10001)
    call('select_check_policy "$BASE" "$HEAD_SHA"', expected=1, data='a' * 4194305)
    passed('malformed/control-character, over-count and over-byte path inventories fail closed')

    def fixtures(model='success', administrative=None, unit='success', extra_runs=()):
        meta = dict(state='OPEN', isDraft=True, headRefOid=head, baseRefOid=base,
                    body='Bound fixture', mergeable='MERGEABLE')
        runs = []
        jobs = [('CI', 'unit', unit)]
        if model is not None:
            jobs.append(('Dependency Review', 'audit', model))
        if administrative is not None:
            jobs.append(('Release Notes', 'notes', administrative))
        for ident, (workflow, name, conclusion) in enumerate(jobs, 1):
            status = 'queued' if conclusion == 'queued' else 'completed'
            conclusion = None if status == 'queued' else conclusion
            runs.append(dict(id=ident, workflow_id=ident, run_number=2, run_attempt=2,
                             name=workflow, head_sha=head, head_branch='feature',
                             event='pull_request', status=status, conclusion=conclusion))
            (root / f'jobs-{ident}-2.json').write_text(json.dumps(dict(total_count=1, jobs=[
                dict(name=name, status=status, conclusion=conclusion)])))
        runs.extend(extra_runs)
        (root / 'meta.json').write_text(json.dumps(meta))
        (root / 'runs.json').write_text(json.dumps(dict(total_count=len(runs), workflow_runs=runs)))
        (root / 'requests').write_text('')

    code = 'snapshot=$(read_pr_snapshot feature) || exit 91\nremote_checks_ready "$snapshot"\n'
    for state in [None, 'skipped', 'neutral', 'queued', 'failure', 'success']:
        fixtures(state)
        call(code, expected=0 if state == 'success' else 1)
    passed('applicable conditional absent/skipped/neutral/queued/failed blocks; success readies')
    fixtures(None)
    call(code, extra=dict(LOOP_CONDITIONAL_WORKFLOWS='[]'))
    passed('unrelated absent conditional is allowed')
    for state in ['failure', 'queued']:
        fixtures('success', state)
        call(code, expected=1)
        call(code, extra=dict(LOOP_IGNORED_WORKFLOWS='["Release Notes"]'))
    passed('only exact operator-selected administrative failures/pending are nonblocking')
    fixtures('success', 'failure', 'failure')
    call(code, expected=1, extra=dict(LOOP_IGNORED_WORKFLOWS='["Release Notes"]'))
    passed('administrative exclusion never relaxes universal job failure')
    fixtures('success', 'failure')
    path = root / 'jobs-3-2.json'
    jobs = json.loads(path.read_text())
    jobs['jobs'][0]['name'] = 'unit'
    path.write_text(json.dumps(jobs))
    call(code, expected=91, extra=dict(LOOP_IGNORED_WORKFLOWS='["Release Notes"]'))
    passed('excluded workflow containing a universal required job fails closed')
    fixtures('success')
    path = root / 'jobs-2-2.json'
    jobs = json.loads(path.read_text())
    jobs['jobs'].append(copy.deepcopy(jobs['jobs'][0]))
    jobs['total_count'] = 2
    path.write_text(json.dumps(jobs))
    call(code, expected=1)
    passed('duplicate workflow-qualified conditional job blocks')
    fixtures('success')
    path = root / 'runs.json'
    runs = json.loads(path.read_text())
    for index, change in enumerate([dict(id=90, run_number=1, run_attempt=9),
                                     dict(id=91, run_attempt=1), dict(id=92, head_sha='0' * 40),
                                     dict(id=93, event='push'), dict(id=94, head_branch='other')]):
        old = copy.deepcopy(runs['workflow_runs'][1])
        old.update(change, conclusion='failure')
        runs['workflow_runs'].append(old)
    runs['total_count'] = len(runs['workflow_runs'])
    path.write_text(json.dumps(runs))
    call(code)
    assert all('/runs/9' not in line for line in (root / 'requests').read_text().splitlines())
    passed('latest attempt plus exact head/branch/event ignore stale or unrelated failures')
    fixtures('success')
    path = root / 'runs.json'
    runs = json.loads(path.read_text())
    runs['total_count'] += 1
    path.write_text(json.dumps(runs))
    call(code, expected=91)
    passed('truncated Actions inventory fails closed')
    fixtures('success', 'failure')
    (root / 'jobs-3-2.json').unlink()
    call(code, expected=91, extra=dict(LOOP_IGNORED_WORKFLOWS='["Release Notes"]'))
    passed('even excluded workflow requires readable bounded jobs API')
    for state in ['CLOSED', 'MERGED']:
        meta = json.loads((root / 'meta.json').read_text())
        meta['state'] = state
        (root / 'meta.json').write_text(json.dumps(meta))
        call('snapshot=$(read_pr_snapshot feature); [[ "$(jq -r .state <<<"$snapshot")" == "' + state + '" ]]')
    passed('terminal PR metadata bypasses unavailable checks without calling Ready')

    fixtures('success')
    metadata = json.loads(call('read_pr_metadata feature').stdout)
    assert metadata['baseRefOid'] == base and metadata['headRefOid'] == head
    assert metadata['state'] == 'OPEN' and metadata['mergeable'] == 'MERGEABLE'
    path = root / 'meta.json'
    fixture = json.loads(path.read_text())
    fixture.update(mergeable='UNKNOWN', body=None)
    path.write_text(json.dumps(fixture))
    metadata = json.loads(call('read_pr_metadata feature').stdout)
    assert metadata['mergeable'] == 'UNKNOWN' and metadata['body'] == ''
    passed('REST maps exact SHA/PR metadata without unsupported CLI baseRefOid field')
    fixture['headRefOid'] = 'not-a-sha'
    path.write_text(json.dumps(fixture))
    call('read_pr_metadata feature', expected=1)
    passed('invalid REST immutable head fails closed')

    fixtures('success')
    receipt = '''
CURRENT_ISSUE=7 CURRENT_CLAIM_REF=refs/heads/squad-claims/issue-7 CURRENT_CLAIM_OID=owner
TASK_BASE_SHA="$BASE" TASK_DEADLINE=$(( $(date +%s) + 600 ))
VERIFIED_HEAD="$HEAD_SHA" REVIEWED_HEAD="$HEAD_SHA" FINAL_PR_BODY='Bound fixture'
REVIEW_BODY_HASH=$(printf '%s' "$FINAL_PR_BODY" | sha256sum | cut -d' ' -f1)
save_pending_publication 7 feature https://example.invalid/pr/7
'''
    call(receipt)
    saved = json.loads((root / 'state/pending.json').read_text())
    assert saved['checkPolicy'] == result
    passed('pending receipt pins full config, selected workflow/jobs and immutable path hash')
    # Resume in a fresh process after policy drift; no mutation/model call is real.
    p = call('''
publication_authorized() { return 0; }
ensure_pr_is_draft() { return 0; }
cleanup_issue() { printf '%s' "$3" >"$FIXTURE/blocked-reason"; return 0; }
run_agent_copilot() { return 98; }
resume_pending_publication
[[ -f "$LOOP_STATE_DIR/blocked-publication-7.json" ]]
''', extra=dict(LOOP_IGNORED_WORKFLOWS='["Release Notes"]'))
    assert 'policy changed or missing' in (root / 'blocked-reason').read_text()
    passed('fresh-process policy drift blocks existing receipt without retry or Ready')

    # The deployment generator only writes this disposable output; no Docker.
    config = root / 'repos.json'
    env_file = root / 'environment'
    env_file.write_text('')
    loop = dict(checkBackend='actions', requiredChecks=['unit'], requiredWorkflows=['CI'],
                conditionalWorkflows=json.loads(env['LOOP_CONDITIONAL_WORKFLOWS']),
                ignoredWorkflows=['Release Notes'])
    workers = {name: dict(owner='example', repo='fixture', loop=copy.deepcopy(loop))
               for name in ['worker-1', 'worker-2']}
    config.write_text(json.dumps(workers))
    config_env = dict(env, REPOS_JSON=str(config), ENV_FILE=str(env_file),
                      COMPOSE_FILE=str(root / 'compose.yml'))
    generated = subprocess.run(['bash', str(SOURCE.parents[1] / 'deploy.sh'), 'generate'],
                               env=config_env, text=True, capture_output=True, timeout=30)
    assert generated.returncode == 0, generated.stderr
    values = [json.loads(line.strip()[2:]) for line in (root / 'compose.yml').read_text().splitlines()
              if line.strip().startswith('- "LOOP_')]
    assert values.count('LOOP_IGNORED_WORKFLOWS=["Release Notes"]') == 2
    for value in values:
        if value.startswith('LOOP_CONDITIONAL_WORKFLOWS='):
            assert json.loads(value.split('=', 1)[1]) == loop['conditionalWorkflows']
    assert sum(x.startswith('LOOP_CONDITIONAL_WORKFLOWS=') for x in values) == 2
    entrypoint = (SOURCE.parent / 'entrypoint.sh').read_text()
    for name in ['CONDITIONAL_WORKFLOWS', 'IGNORED_WORKFLOWS']:
        assert f'write_workspace_export LOOP_{name} "${{LOOP_{name}:-[]}}"' in entrypoint
    passed('both selector fields survive real Compose generation and entrypoint exports')
    equiv = SOURCE.parents[1] / 'tests/config-equivalence.sh'
    for field in ['conditionalWorkflows', 'ignoredWorkflows']:
        workers['worker-2']['loop'] = copy.deepcopy(loop)
        workers['worker-2']['loop'][field] = []
        config.write_text(json.dumps(workers))
        result = subprocess.run(['bash', str(equiv)], env=config_env, text=True,
                                capture_output=True, timeout=30)
        assert result.returncode == 1 and field in result.stderr
    passed('shared-queue equivalence rejects either selector mismatch')

    # Reject hostile metadata before Git path selection can inspect it.
    (repo / '.git').rename(root / 'git-metadata')
    (repo / '.git').symlink_to(root / 'git-metadata', target_is_directory=True)
    call('resolve_check_policy "$BASE" "$HEAD_SHA"', expected=1)
    passed('conditional selector rejects hostile Git metadata before any Git read')

print(f'Check-policy regressions: {cases} PASS')
