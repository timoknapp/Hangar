# ADR 0001: Factory direction — staged reliability before staged intake

Status: accepted (2026-10-22)

## Context

Hangar runs one fixed pipeline per approved issue: claim, base verify, implement, verify, independent critic, bounded corrections, draft, ready.
Industry "software factory" designs (for example Warp's public factory and the Oz `cloud-factory-demo`) split work into separate stages: triage, spec, implement, review, verify, ship.
Each stage there is a separate run with a durable artifact, and a deterministic applier owns all tracker mutations.

We measured a private reference deployment (two repositories, four workers) from 2026-09-01 to 2026-10-22.
Only 1 of 13 approved issues reached a ready pull request without manual intervention.
The 25 blocking events split into:

| Class | Share | Examples |
|---|---|---|
| Mechanics and infrastructure | 56 % | base preparation failed, critic input delivery not proven for large diffs, CLI masking, model unavailable, cancelled check runs |
| Implementer stopped without changes | 28 % | contract contradiction or missing decision discovered after 20–30 minutes |
| Review exhausted | 16 % | open BLOCK findings after all corrections, often oversized scope |

Output quality was not the problem: every pull request from that period that reached review was merged.

## Decision

Primary goal: an approved issue reaches a ready pull request without human intervention.
Target: at least 80 % over the next ten approved issues per reference repository.
Stops that ask a human a legitimate question (`squad:needs-*`) do not count as intervention; a second metric tracks questions per issue.
Hangar must stay generic for any repository.

Invariants that do not change:

- Approval stays human. No stage may grant approval; triage may only hold work back.
- Fail closed. Automatic retry happens at most once per issue and only for transient infrastructure failures.
- GitHub is the only state store and the only notification channel. Hangar has no chat or messaging integration.
- Agents keep no publisher credentials; a deterministic publisher validates every agent artifact before mutating GitHub.
- Critic severity stays fixed by category; full-input delivery proof stays mandatory.

Delivery order, each block measured before the next:

1. **Receipts and metrics.**
   A hidden machine-readable receipt in the final issue comment of every attempt (stage, outcome, failure class, retry, duration, usage or `unknown`), plus a script that computes the metrics from GitHub alone.
2. **Mechanics.**
   Preflight before every claim (repository ownership and fetch, model reachability, pinned CLI version, disk); an unhealthy worker claims nothing.
   Failure classes with one delayed automatic retry for transient infrastructure failures only.
   A checkpoint after implementation and local verification, so retries resume at verify or critic instead of re-implementing.
   A reaper for orphaned claims, closed or unlabeled issues and stale `squad:processing`; branches are archived, never deleted.
3. **Critic determinism.**
   Large review inputs are split into file groups, each with its own delivery proof; all parts must approve; binary and generated files are reviewed as a hashed list.
   Residual CLI masking publishes a draft with `squad:needs-decision` and exact lines instead of failing.
4. **Decision stops and triage.**
   "Implementer stopped without changes" becomes `squad:needs-decision` with the rationale posted, not `squad:failed`; an answer re-queues the issue.
   An opt-in read-only triage session runs after human approval and before claim.
   It returns validated JSON with `outcome` in `implement | needs-info | needs-spec | too-large | park`, a rationale, at most five questions and a size estimate.
   The publisher applies labels; on any `needs-*` outcome the `squad` label is removed so external dispatchers can advance.
   Repositories may add `.loop/triage.md`, read from the pinned base like the review rubric, for size limits and spec conventions.
   `too-large` posts a split proposal; humans create the parts.
   Self-generated (`loop:auto`) work requires triage plus strict eligibility gates; when in doubt, `park`.
   Revisions skip triage.
5. **Spec work type.**
   An approved `squad:spec` issue runs the same pipeline restricted by a deterministic path check to the repository's spec directory, reviewed with a spec rubric.
   Merging the spec pull request is the approval.
6. **Learning loop (opt-in, last).**
   A weekly proposal pull request may only change `.loop/review-rubric.md` and `.loop/triage.md`, enforced by a path guard.
   It starts only after the main metric is stable above 60 %.

Defaults: blocks 1–3 and `needs-decision` apply to every repository; triage and spec are opt-in per repository.

## Implementation rules

- `worker/worker-loop.sh` is refactored incrementally: each block first extracts the code it touches into `worker/lib/*.sh` without behavior change (separate commit, all tests green), then adds behavior.
- Every new parser or gate gets missing, empty, malformed and boundary fixtures, including a fail-open regression test.
- Rollout goes to all workers at once. The previous image tags are recorded; any new failure class that blocks two consecutive issues, or a worker that fails to start or preflight, triggers an immediate rollback to the previous images.

## Consequences

- Most expected gain comes from blocks 2–3; triage is measured separately afterwards.
- The pipeline gains new visible labels (`squad:needs-info`, `squad:needs-decision`, `squad:needs-spec`, `squad:too-large`, `squad:spec`); external dispatchers must skip `squad:needs-*`.
- Industry factory features not adopted: monitoring agents, computer-use video evidence, agent-chosen severities, agents with tracker write permissions.
