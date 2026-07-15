# Hangar Test Suite

## Categories

### Local Gate (`final-gate.sh`)

Runs automatically on every pre-merge check. Validates:

- Bash syntax (`bash -n`) for all shell scripts
- ShellCheck lint for all shell scripts
- `jq` validation of JSON fixtures
- JavaScript/Python/C fixture syntax (C on Linux only)
- Public-release content check (no private artifacts)
- Generic config equivalence across shared-queue workers
- PR fail-closed ordering assertions
- Worker-loop unit/integration test suite

### Live Proofs (remote — require running fleet)

| Script | Purpose | Prerequisites |
| --- | --- | --- |
| `validate-live-workers.remote.sh` | Full fleet runtime assertions | Running containers, `repos.json` |
| `squad-capability-preflight.remote.sh` | Squad shell/MCP/delegation proof | Active worker with Squad mode |
| `check-copilot-token-boundary.remote.sh` | Copilot PAT has no repo mutation | Running container |
| `check-live-agent-secret-isolation.remote.sh` | No secrets in agent processes | Active Copilot session |
| `check-failed-run-access.remote.sh` | GitHub App can read Actions logs | Running container, env file |
| `critic-real-diff-preflight.remote.sh` | Production critic on large synthetic diff | Docker, worker image |
| `critic-runtime-preflight.remote.sh` | Critic model connectivity | Running container |
| `runtime-preflight.test.sh` | Container isolation boundary | Running container |
| `mcp-capability-smoke.remote.sh` | MCP server handshake | Active session |
| `validate-squad-session.remote.sh` | Squad session lifecycle | Active session |

### Deployment (remote — run on Docker host)

| Script | Purpose | Prerequisites |
| --- | --- | --- |
| `deploy-workers.remote.sh` | Recreate specific workers by ID | Docker host, env file, repos.json |
| `deploy-preflight.sh` | Pre-deploy credential/model check | Docker host, env file |
| `credential-separation.sh` | PAT rotation verification | Docker host, env/container |

### Diagnostics & Recovery (remote)

| Script | Purpose | Prerequisites |
| --- | --- | --- |
| `diagnose-worker-issue.remote.sh` | Issue/PR state and worker logs | Container, repo args |
| `list-active-claims.remote.sh` | Report claim refs and processing issues | Container, env, repo args |
| `prepare-revision-retry.remote.sh` | Release stale claim for retry | Container, env, repo/issue args |
| `remediate-tokenized-remotes.remote.sh` | Remove embedded tokens from git config | Container(s) |
| `run-rotation-check.sh` | SSH-invoke rotation verification | SSH to Docker host |
| `verify-rotation.remote.sh` | On-host PAT rotation assertion | Docker host |

## Running

```bash
# Full local gate (CI)
bash tests/final-gate.sh

# Individual local tests
bash tests/worker-loop.test.sh
bash tests/config-equivalence.sh
bash tests/pr-guard.test.sh
bash tests/public-release-check.sh

# Remote proofs (from Docker host with fleet running)
bash tests/validate-live-workers.remote.sh
bash tests/deploy-workers.remote.sh 3 4
```

## Conventions

- All local tests use synthetic data only (no real tokens, repos, or owners)
- Remote scripts require explicit arguments or derive values from `repos.json`
- No test prints secret values; only existence/absence booleans
- Fixtures in `tests/fixtures/` are fully synthetic
