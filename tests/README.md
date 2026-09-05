# Hangar Test Suite

## Categories

### Local Gate (`final-gate.sh`)

Runs automatically on every pre-merge check. Validates:

- Bash syntax (`bash -n`) for all shell scripts
- ShellCheck lint for all shell scripts
- `jq` validation of JSON fixtures
- JavaScript/Python/C fixture syntax (C on Linux only)
- Public-release content check (no private artifacts)
- README source URL, diagram inventory, and Mermaid keyword regression
- Generic config equivalence across shared-queue workers
- PR fail-closed ordering assertions
- Worker-loop unit/integration test suite

The worker suite also runs `critic-complete-input.test.sh`. Critic acceptance
requires complete exact numbered `view` results in publisher-captured CLI JSONL,
followed by a main-model response and successful terminal result. This was
verified with CLI 1.0.70; incompatible/missing events, coverage holes, truncated
content, model switches and context compaction fail closed as incomplete, without
code-repair retries. The existing input-byte and task-time budgets still apply.
The 32 MiB event-parser ceiling also fails closed. Full text reaching the model
is not proof of understanding or review correctness; image/policy/verification
requirements remain separate. Runtime acceptance must test both a clean large
diff and a real late defect, not force an approval of a defective fixture.

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
bash tests/readme-content.test.sh
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

### Immutable local evidence boundary

`immutable-evidence.test.sh` reproduces replacement-ref review omission and both
index-mask false passes using only disposable Git repositories and a local bare
receiver. It checks trusted base rules, the full critic input, ancestry, the
verified/published object IDs, flags introduced by verification, forged stat
caches, raw-byte/mode changes, corrupt objects/indexes, and unsafe paths. The
existing full JSONL delivery validator and its semantic limits are unchanged.

The worker supports **full SHA-1 checkouts with ordinary regular tracked files**.
All trusted Git object interpretation disables replacement objects and commit
graphs; replacement refs remain intact (ignored, never silently deleted).
Metadata validation rejects grafts, shallow history, alternate/promisor stores,
Git indirection, symlinks/hardlinks/special metadata, sparse/extended-format
configuration and sparse indexes before publisher interpretation. A read-only
unprivileged `git fsck --strict` also rejects damaged objects/trees. Masked
(assume-unchanged/skip-worktree), unmerged, symlink and gitlink index entries block.

Before **and after** verification, the worker compares the exact index path/mode/
object inventory to immutable HEAD, then independently hashes every tracked
regular file's **raw bytes** with the Git blob header. It never uses status/diff
stat caches or executes attribute filters/textconv to establish equality. Parent
symlinks, hardlinks, missing/nonregular files, incompatible paths/encodings and
mode mismatches fail closed. Git inventories have a 32 MiB output ceiling; large
files are hashed in bounded chunks; checks use the remaining task deadline. CRLF/smudge/LFS-transformed worktrees are not
raw-byte equality, even when Git calls them clean. Sparse checkouts, tracked
symlinks/submodules and alternate object stores require explicit operator
recovery/materialization; no partial-checkout exemption exists.

The inline checker is publisher-owned code run as the coding user with an empty
environment, fixed system Node/Git paths, and no publisher credentials. Neither
source bytes, path values nor digests are emitted on rejection. It does not run
as root. The existing boundary must terminate coding-user processes before
checks; the operator must protect workspace ancestors, publisher tools/state,
and prevent concurrent writers or hostile mounts. This is not a filesystem
snapshot or protection against a compromised kernel/Git. Verification remains
untrusted code: before/after equality cannot establish what a deliberately
self-modifying test executed and then restored within the command.

Ignored generated build artifacts remain allowed; tracked files cannot be hidden
by ignore rules. Nonignored untracked files still block clean admission and
publication. Unsupported metadata/content is an infrastructure block, retaining
work and flags without reset/clean/unstage or model code-repair retries. A final
raw-content check precedes publication, including draft-only operation. Local
fixtures replace only the checker user switch (not the checker); live privilege
and image acceptance remain separate gates. Do not materialize sensitive source
merely to satisfy this full-tree check; safe source selection is an operator
prerequisite, not a path exemption in public policy.
