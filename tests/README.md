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
- Manual-intake priority, identity/approval revocation, concurrent per-issue claims,
  legacy/manual pending receipts and complete >100-PR history reconciliation

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
unprivileged raw-object checker rejects damaged **required** objects (see below). Masked
(assume-unchanged/skip-worktree), unmerged, symlink and gitlink index entries block.

Before **and after** verification, the worker compares the exact index path/mode/
object inventory to immutable HEAD, then independently hashes every tracked
regular file's **raw bytes** with the Git blob header. It never uses status/diff
stat caches or executes attribute filters/textconv to establish equality. Parent
symlinks, hardlinks, missing/nonregular files, incompatible paths/encodings and
mode mismatches fail closed. Git inventories and individual commit/tree buffers
have a 32 MiB ceiling; tree bytes and expanded inventory bytes each have a 32 MiB
aggregate ceiling. Metadata entries, ancestor commits/parent edges and snapshot
entries are capped at 250,000, paths at 4,096 characters. Blobs and worktree
files stream in bounded chunks; checks use the remaining task deadline. CRLF/smudge/LFS-transformed worktrees are not
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

### Required object scope and availability

`evidence-availability.test.sh` exercises normal `--no-hardlinks` clones with
reachable legacy zero-padded tree modes and `.GIT` history, non-UTF8 historical
commit messages, and unreachable malformed loose objects. None blocks admission
when absent from the required snapshots. The same production sanitizer runs at
persisted-volume startup: there is no startup-only exemption or weakened mode.
The startup fixture executes the actual entrypoint admission block, substituting
only account setup; container/privilege acceptance is still a separate gate.

The checker explicitly disables replacements/commit graphs and lazy fetch. It
streams `git cat-file --batch` raw objects, checks the requested type and length,
and recomputes the Git SHA-1 header + payload hash; `cat-file -s`, object names,
status and normalized `ls-tree` output are **not** content proof. Packed and loose
objects use the same check. Every invocation validates:

- HEAD, task base and task start, plus explicit input roots (freshly fetched base,
  revision head and independent selector base/head); each root's complete tree
  and blobs, plus all staged index blobs;
- all ancestor commit bytes and structural tree/parent/identity headers used by
  ancestry; commit message encodings need not be UTF-8;
- when a task base is bound, snapshots introduced in `base..HEAD`, including
  intermediate changes later reverted (publication still transfers that history).

Raw required trees must have canonical regular-file/directory modes, safe UTF-8
names, canonical ordering, unique names and correctly typed/hash-bound children.
Legacy historical tree encodings are tolerated only outside this required set;
they are not a permission to admit unsafe current trees. Historical snapshots
outside that set, other refs/reflogs and unreachable object payloads are not
integrity-scanned. In particular, old blobs unused by evidence are not read just
to admit a task. Selecting an old snapshot as a base makes its objects required.
This is evidence validation, **not a repository backup/full-history audit**.

The offline matrix covers baseline/verify/critic, new and revision admission,
fresh-base checks, publication preconditions and persisted-volume startup, real
required corruption/misaddressing (commit/tree/blob/ancestor/base/index/input),
unsafe current trees, preserved unreachable garbage and packed large blobs.
The full gate additionally covers masks/replacements, filters, CRLF, metadata
indirection, critic delivery, Actions, pending receipts and approval semantics.
Do not globally export `GIT_NO_REPLACE_OBJECTS` when running attack fixtures:
the vulnerable control must honor replacements; production passes its own flag.

### Evidence recovery

A Git-accepted optional historical header such as `x_legacy` can still block task
admission and persisted-workspace startup. This is a known unsupported-history
limitation, not proof of corruption; `git fsck --strict` is not a compatibility
certificate. See the concrete [C1 compatibility and operating warning](../docs/OPERATIONS.md#known-git-compatibility-limit-c1)
before attempting any recovery. Resetting or re-cloning the same history does not
resolve it.

On `Repository evidence blocked`, stop/restrict the worker and **preserve the
checkout, object files, index flags and logs** for inspection. No automatic gc,
prune, reset, clean, unstage or deletion is performed. The fixed admission does
not require cleanup of unreachable malformed objects; retrying the same intact
checkout works when the required evidence is healthy. Restarting is not a repair
for corrupt required evidence, and startup still fails closed for that case.

An operator should inspect a separate copy with trusted Git, check storage and
compare required objects against a known-good authoritative clone/backup. Keep
unpublished work and the original damaged evidence before explicitly restoring
objects or replacing the runtime volume with a verified full clone. Rerun all
admission, verification and review gates; do not reuse old approval receipts for
changed evidence. `git fsck` is an optional operator audit, not the admission
oracle; `--strict` can flag valid old imports, and a whole-store failure can be
unrelated garbage. Do not blindly prune to turn an error green.

For sparse/shallow/alternate/promisor metadata, tracked links/submodules, masked
indexes, normalized CRLF/smudge/LFS bytes or resource ceilings, supply a supported
full regular-file checkout or obtain an explicit operator-supported redesign.
Do not suppress checks, silently clear flags or materialize excluded sensitive
source. Deadline/large-history cost is a deliberate fail-closed resource limit;
no large-monorepo performance or atomic-snapshot claim is made.

### Manual intake fixtures

`manual-intake.test.sh` replaces GitHub with synthetic API responses and a disposable
local Git ref store. Claim commits and compare-and-swap ref creation are real Git;
no public issues, labels, PRs, branches or deployments are mutated. It covers two
free workers with distinct manual issues versus a same-issue collision, existing
WIP/ready PR and exhausted budget, scheduled bots without `loop:auto`, fresh author
revalidation, restart/Ready and revocation, exact-head drift, old receipts, busy
workers, config wiring and complete paginated history with late open/closed PRs.
These local regression fixtures do not establish live worker/GitHub API acceptance. Deployment and live acceptance remain separate.
