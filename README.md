<div align="center">
  <img src="docs/assets/hangar-mark.svg" width="120" height="120" alt="Hangar mark — a friendly copilot robot ready to launch" />
  <h1>Hangar</h1>
  <p><strong>Where your copilots live, get fueled up, and launch.</strong></p>
  <p><em>The self-hosted flight deck for coding agents.</em></p>
  <p>Your hardware. Your repositories. Your merge button.</p>

  <p>
    <img alt="CI: GitHub Actions" src="https://img.shields.io/badge/CI-GitHub_Actions-2088FF?logo=githubactions&amp;logoColor=white" />
    <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg" />
    <img alt="Status: v0.1 source-only" src="https://img.shields.io/badge/status-v0.1_source--only-orange.svg" />
    <img alt="Platform: Docker / Linux" src="https://img.shields.io/badge/platform-Docker%20%7C%20Linux-informational.svg" />
  </p>
</div>

---

> **⚠️ Security notice.** Worker containers run AI-generated code and open real pull requests
> against your repositories. Review the [Security model](#-security-model) section and
> [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before connecting any repository you care about.
> Autonomous mode is experimental and disabled by default.

---

## What is Hangar?

Hangar is an open-source, self-hosted control plane that runs a fleet of GitHub Copilot coding
agents — called **Squad Workers** — on your own hardware. Workers poll a GitHub issue board, claim
tasks atomically, run a full Copilot implementation session, and open a pull request. You review
and merge; Hangar never touches the merge button.

It is not affiliated with or endorsed by GitHub, Inc. GitHub Copilot is a separate subscription
service with its own [terms](https://docs.github.com/en/site-policy/github-terms/github-terms-for-additional-products-and-features).
Hangar is an independent wrapper and coordination layer that calls the Copilot CLI on your behalf.

---

## Three pillars

### 🛫 Cockpit

An optional web interface accessible from mobile or desktop — built around **ttyd** and **tmux** —
giving you live visibility into any worker session. `ENABLE_TTYD=true` to activate; off by default.

### ✈️ Squadron

A **fleet of containerised workers**, each mapped to one repository via `repos.json`. Workers
build from source with pinned Copilot/Squad CLI versions and run in separate workspace volumes.
Add an entry to `repos.json` and run `./deploy.sh up`; enable automatic CLI updates only if you
explicitly accept unreviewed upstream upgrades.

### 🧭 Ground Control

The operational layer that keeps quality high and blast radius small:

| Control | What it does |
| --- | --- |
| **Atomic claims** | A Git ref (`squad-claims/issue-N`) is created atomically before the visible `squad:processing` label; only one worker wins |
| **Independent critic** | A second Copilot session — optionally running a different model — reviews the diff *without* the implementer's context |
| **Verify hook** | Runs your own test suite or a custom script before publication; failures trigger bounded correction and then a flagged draft |
| **Autonomous budget / draft safety** | `maxPrsPerDay` caps daily `loop:auto` PR attempts; manual issues and revisions bypass it |
| **Credential isolation** | OS permissions protect publisher credentials; a native guard protects the model-token process tree and strips secrets from child tools |

---

## ✈️ Quick start

### Prerequisites

- Docker Engine 24+ and Docker Compose v2
- `jq` (`brew install jq` / `apt install jq`)
- A GitHub App installed on your organisation or account with **Contents**, **Issues**, and
  **Pull Requests** read/write permissions plus **Actions** read permission
- A user-owned fine-grained PAT with the **Copilot Requests** account permission **only**
  (no repository permissions — the GitHub App owns those)
- An active **GitHub Copilot** subscription on the PAT owner's account
- For the recommended Squad path: a target repository with Squad configuration already committed,
  or Node.js 22.5+ and npm 10+ for the one-time initialization in Step 4

### 1. Clone and copy the example files

> **Source-only release:** Hangar v0.1 has no npm package. Do **not** run unscoped
> `npx hangar`; that package name belongs to an unrelated project.

```bash
git clone https://github.com/timoknapp/Hangar.git
cd Hangar

cp .env.workers.example  .env.workers
cp repos.example.json    repos.json
```

### 2. Configure secrets

Edit `.env.workers` — the four required values:

```dotenv
GH_APP_ID=123456
GH_APP_INSTALL_ID=123456
GH_APP_PEM_FILE=/absolute/path/to/gh-app-private-key.pem
COPILOT_PAT=github_pat_...   # fine-grained, Copilot Requests permission only
```

The App installation ID is the number at the end of its installation URL. See
[the full GitHub App walkthrough](docs/INSTALL.md#2-github-app-setup).

All other settings have safe defaults. Worker `ENABLE_TTYD` and
`INTERACTIVE_ENABLE_TTYD` both default to `false`; worker `SSH_AUTHORIZED_KEY` is optional.

### 3. Assign a repository to a worker

Edit `repos.json` — one entry per worker:

```json
{
  "worker-1": {
    "url":    "https://github.com/your-org/your-repo.git",
    "owner":  "your-org",
    "repo":   "your-repo",
    "branch": "main",
    "model":  "",
    "loop": {
      "autonomous":        false,
      "critic":            true,
      "criticModel":       "",
      "criticRubric":      "repo-aware",
      "verify":            "auto",
      "maxPrsPerDay":      2,
      "implementer":       "squad"
    }
  }
}
```

This is Hangar's **recommended guarded starter profile**, not the raw compatibility defaults:
it enables automatic verification, the independent critic, full Squad implementation, and a
two-PR daily safety cap for autonomous `loop:auto` work. Human-created `squad` issues do not
consume that budget. The [configuration reference](#reposjson-fields) lists the fallback defaults
used when fields are omitted.

### 4. Initialize Squad in the target repository

The recommended `implementer: "squad"` path requires committed Squad configuration in each
target repository. On a machine with Node.js 22.5+ and npm 10+, run:

```bash
cd /path/to/your-target-repository
npx @bradygaster/squad-cli@0.11.0 init --preset default
git status --short
```

Review the generated agents, instructions, workflows, and MCP configuration, then commit and push
them through your normal repository workflow. Unattended workers treat target-repository
configuration as trusted code. See the
[Squad project](https://github.com/bradygaster/squad) for customization options.

### 5. Start Hangar

```bash
./deploy.sh up        # starts interactive Hangar + generated worker services
./deploy.sh status    # confirms the complete hangar-fleet stack
```

Docker now shows one `hangar-fleet` Compose project containing the trusted `hangar` workstation
and every `squad-worker-N` service. Workers poll for open issues carrying the `squad` label. With
the guarded starter profile above, a worker claims, implements, verifies, independently reviews,
and opens a ready PR or clearly flagged draft. If you disable verification or the critic, those
stages are skipped as documented in the configuration reference.

> **Loopback-only default.** Interactive SSH/ttyd use ports 2222/7681; worker SSH/ttyd use
> 2231+/7691+. All bind to `127.0.0.1` unless explicitly overridden. Do not expose these ports
> directly to the internet; use a VPN or authenticated reverse proxy.

## 🖥️ Interactive workstation (optional)

The `hangar` service is an operator-driven development container rather than an autonomous
worker. It provides SSH/ttyd, tmux, Copilot CLI, Squad CLI, and persistent workspace/auth volumes.
It starts with the workers under the same Compose project; configure its `INTERACTIVE_*` values
in `.env.workers`, then run the one-time authentication helper if needed:

```bash
./deploy.sh restart-interactive
docker exec -it hangar su - copilot -c 'bash ~/auth-setup.sh'
```

This interactive image intentionally gives the `copilot` operator passwordless sudo and does not
use the worker publisher/implementer boundary. Treat it as a trusted workstation, keep its ports
on loopback, and do not use it as a sandbox for untrusted repositories.

---

## 🗺️ Architecture

```mermaid
flowchart TD
    subgraph "Your hardware — Hangar host"
      D["deploy.sh"] -->|"combines"| C["docker-compose.yml + generated workers"]
      C -->|"one hangar-fleet project"| H["hangar — trusted interactive service"]
      C --> W1["squad-worker-1"]
      C --> W2["squad-worker-2"]
      C --> Wn["squad-worker-n …"]
    end

    subgraph "squad-worker-N container"
        PUB["copilot user\n(publisher / loop runner)"]
        AGENT["squad-agent user\n(implements code)"]
        GUARD["credential-guard\n(LD_PRELOAD shim)"]
        PUB -->|"launch guarded session as squad-agent"| AGENT
        GUARD -.->|"protects model-token process tree"| AGENT
    end

    subgraph "GitHub"
        ISSUES["Issue board"]
        REPO["Repository"]
        PR["Pull Request"]
    end

    W1 -->|"polls / atomic claim"| ISSUES
    AGENT -->|"local edits / tests only"| W1
    PUB -->|"git push verified branch"| REPO
    PUB -->|"gh pr create"| PR
    PR -->|"Human reviews"| MERGE(["✓ Merge"])

    style GUARD fill:#b91c1c,color:#fff
    style MERGE fill:#166534,color:#fff
```

### Issue → PR flight pipeline

```mermaid
sequenceDiagram
    participant Board  as "Issue board"
    participant Worker as "Worker process"
    participant Impl   as "Copilot session (squad-agent)"
    participant Critic as "Independent critic (optional)"
    participant Verify as "Verify hook (optional)"
    participant GH     as "GitHub"

    Worker->>Board: poll for unclaimed tasks
    Board-->>Worker: issue found
    Worker->>Board: atomically create claim ref, then add squad:processing
    Worker->>Impl: run implementation session (local workspace only)
    Impl-->>Worker: local commits / residual edits
    opt verify enabled
        Worker->>Verify: run test suite or custom script
        Verify-->>Worker: pass / fail to bounded correction
    end
    opt critic enabled after verification
        Worker->>Critic: fresh read-only review of attested diff input
        Critic-->>Worker: APPROVE / REQUEST_CHANGES / unavailable
        Note over Worker,Critic: Critic-driven fixes are fully re-verified
    end
    Worker->>GH: publisher pushes branch and creates ready or draft PR
    Note over GH: Human reviews and merges
```

## 🛫 How it operates — every scenario

The summary above is the straight-line journey. The diagrams below cover the complete worker
cycle and each operational branch. They are collapsed by default to keep the README scannable.

### Master cycle

```mermaid
flowchart TD
    Wake([Worker wakes for a poll cycle]) --> Revision{Revision issue waiting?}
    Revision -->|yes| ClaimRevision[Atomically claim issue ref<br/>checkout existing PR branch]
    Revision -->|no| NewIssue{Queued squad issue waiting?<br/>manual first}

    NewIssue -->|yes| AutoIssue{Issue has loop:auto?}
    NewIssue -->|no| Autonomous{Autonomous mode enabled?}
    AutoIssue -->|no; manual| ClaimManual[Atomically claim manual issue ref]
    AutoIssue -->|yes| Budget{Autonomous PR budget available?}
    Budget -->|no| Idle[Idle loop:auto work;<br/>manual issues and revisions remain eligible]
    Budget -->|yes| ClaimAuto[Atomically claim loop:auto issue ref]
    ClaimAuto --> Reserve[Atomically reserve autonomous budget slot]

    Autonomous -->|no| Idle
    Autonomous -->|yes| AutoCapacity{Budget and auto-issue capacity available?}
    AutoCapacity -->|no| Idle
    AutoCapacity -->|yes| Generate[Generate one goal-aligned squad issue]
    Generate --> Wake

    ClaimRevision --> Implement[Run Copilot or Squad implementation]
    ClaimManual --> Implement
    Reserve --> Implement
    Implement --> VerifyState{Verification state?}
    VerifyState -->|disabled| CriticState{Independent critic enabled?}
    VerifyState -->|unavailable| Draft[Publish a flagged draft PR]
    VerifyState -->|configured| RunVerify[Run build and tests]
    RunVerify -->|pass| CriticState
    RunVerify -->|fail| VerifyRetries{Correction retries left?}
    VerifyRetries -->|yes| VerifyFix[Correct from verification log]
    VerifyFix --> RunVerify
    VerifyRetries -->|no| Draft

    CriticState -->|no| Ready[Publish a ready PR]
    CriticState -->|yes| Review[Fresh attested read-only review]
    Review -->|APPROVE| Ready
    Review -->|REQUEST_CHANGES| CriticRetries{Correction retries left?}
    CriticRetries -->|yes| CriticFix[Apply critic feedback]
    CriticFix --> RunVerify
    CriticRetries -->|no| Draft
    Review -->|unavailable or malformed| InfraRetries{Critic retries left?}
    InfraRetries -->|yes| Review
    InfraRetries -->|no| Draft

    Ready --> Finish[Add squad:done<br/>release atomic claim]
    Draft --> Finish
    Finish --> Idle
    Idle --> Wake
```

<details>
<summary><b>Scenario A — Happy path: queued issue to ready PR</b></summary>

```mermaid
sequenceDiagram
    participant Worker as "Hangar worker"
    participant GitHub as "GitHub"
    participant Impl as "Squad implementer"
    participant Verify as "Verify gate"
    participant Critic as "Independent critic"

    Worker->>GitHub: Poll and find issue 42 with squad label
    Worker->>GitHub: Create atomic claim ref
    Worker->>GitHub: Add squad:processing
    Worker->>Impl: Implement issue 42 locally
    Impl-->>Worker: Local commits and residual edits
    Worker->>Verify: Run build and tests
    Verify-->>Worker: PASS
    Worker->>Critic: Review attested diff against rubric
    Critic-->>Worker: APPROVE
    Worker->>GitHub: Push branch and open ready PR
    Worker->>GitHub: Add squad:done and release claim ref
    Note over GitHub: A human reviews and merges
```

</details>

<details>
<summary><b>Scenario B — Empty board: generate the next task</b></summary>

```mermaid
sequenceDiagram
    participant Worker as "Hangar worker"
    participant GitHub as "GitHub"
    participant Planner as "Read-only planner"

    Worker->>GitHub: Poll revision and squad queues
    GitHub-->>Worker: No eligible issue
    Note over Worker: Autonomous mode is enabled<br/>Budget and auto-issue capacity remain
    Worker->>Planner: Read goal source and repository context
    Planner-->>Worker: Return one highest-value scoped task
    Worker->>GitHub: File issue with squad and loop:auto
    Note over Worker: A later cycle handles it through Scenario A
```

</details>

<details>
<summary><b>Scenario C — Verification fails: bounded self-correction</b></summary>

```mermaid
sequenceDiagram
    participant Worker as "Hangar worker"
    participant Impl as "Squad implementer"
    participant Verify as "Verify gate"

    Worker->>Impl: Implement requested change
    Impl-->>Worker: Local commits
    Worker->>Verify: Run complete build and test command
    Verify-->>Worker: FAIL with bounded log tail
    Worker->>Impl: Correct from verification feedback
    Impl-->>Worker: Fix commits
    Worker->>Verify: Re-run complete build and test command
    Verify-->>Worker: PASS
    Note over Worker: Continue to independent critic before publication
```

</details>

<details>
<summary><b>Scenario D — Critic requests changes: revise, re-verify, re-review</b></summary>

```mermaid
sequenceDiagram
    participant Worker as "Hangar worker"
    participant Impl as "Squad implementer"
    participant Verify as "Verify gate"
    participant Critic as "Independent critic"

    Worker->>Critic: Review attested diff against rubric
    Critic-->>Worker: REQUEST_CHANGES with reasons
    Worker->>Impl: Apply critic feedback
    Impl-->>Worker: Revised commits
    Worker->>Verify: Re-run complete build and tests
    Verify-->>Worker: PASS
    Worker->>Critic: Review the new attested diff
    Critic-->>Worker: APPROVE
    Note over Worker: Only the re-verified revision can become a ready PR
```

</details>

<details>
<summary><b>Scenario E — Verification unavailable: fail safely to draft</b></summary>

```mermaid
sequenceDiagram
    participant Worker as "Hangar worker"
    participant Impl as "Squad implementer"
    participant Verify as "Verify discovery"
    participant GitHub as "GitHub"

    Worker->>Impl: Implement requested change
    Impl-->>Worker: Local commits
    Worker->>Verify: Resolve automatic build and test command
    Verify-->>Worker: No supported command detected
    Worker->>GitHub: Push branch and open draft PR
    Worker->>GitHub: Add verification-unavailable warning to PR body
    Note over GitHub: Human review is required before merge
```

</details>

<details>
<summary><b>Scenario F — Autonomous budget exhausted: manual work remains eligible</b></summary>

```mermaid
sequenceDiagram
    participant Worker as "Hangar worker"
    participant GitHub as "GitHub"

    Worker->>GitHub: Check revision queue, then manual squad issues
    GitHub-->>Worker: Generated issue found after manual and revision queues are empty
    Worker->>GitHub: Read autonomous budget refs
    GitHub-->>Worker: Daily autonomous cap reached
    Worker-->>Worker: Idle autonomous work until the next poll interval
    Note over Worker,GitHub: Manual squad issues and revisions bypass the cap
```

</details>

<details>
<summary><b>Scenario G — Human requests a revision on an existing PR</b></summary>

```mermaid
sequenceDiagram
    participant Human as "Human reviewer"
    participant GitHub as "GitHub"
    participant Worker as "Hangar worker"
    participant Impl as "Squad implementer"
    participant Gates as "Verify and critic gates"

    Human->>GitHub: Comment on issue and add squad:revision
    Worker->>GitHub: Atomically claim the issue
    Worker->>GitHub: Fetch existing PR branch and failed checks
    Worker->>Impl: Apply only the requested revision
    Impl-->>Worker: Revision commits
    Worker->>Gates: Verify and independently review revision
    alt Gates pass
      Gates-->>Worker: Ready
      Worker->>GitHub: Force-with-lease update of the same PR branch
    else Gates remain unresolved
      Gates-->>Worker: Draft required
      Worker->>GitHub: Convert existing PR to draft before push
      Worker->>GitHub: Force-with-lease update with gate warning
    end
    Worker->>GitHub: Remove squad:revision and release claim ref
```

</details>

<details>
<summary><b>Scenario H — Critic unavailable: retry infrastructure, then draft</b></summary>

```mermaid
sequenceDiagram
    participant Worker as "Hangar worker"
    participant Critic as "Independent critic"
    participant GitHub as "GitHub"

    Worker->>Critic: Submit read-only review file with nonce
    Critic-->>Worker: Timeout, malformed output, or missing attestation
    loop Bounded infrastructure retries
      Worker->>Critic: Retry unchanged diff without modifying code
      Critic-->>Worker: No valid attested verdict
    end
    Worker->>GitHub: Open draft PR with critic-unavailable warning
    Note over GitHub: No missing verdict is inferred as approval
```

</details>

---

## Configuration reference

### `repos.json` fields

| Field | Default | Description |
| --- | --- | --- |
| `url` | — | HTTPS clone URL |
| `owner` / `repo` | — | Used for `gh` API calls |
| `branch` | `main` | Base branch |
| `model` | CLI default | Copilot model for implementation |
| `loop.autonomous` | `false` | Self-generate work when the board is empty (**experimental**) |
| `loop.critic` | `false` | Run an independent second-pass critic review |
| `loop.criticModel` | same as `model` | Separate model for the critic pass |
| `loop.verify` | `"off"` | `"off"` \| `"auto"` \| `"<cmd>"` \| `".loop/verify.sh"` |
| `loop.maxRetries` | `2` | Self-correction attempts per quality gate failure |
| `loop.maxPrsPerDay` | `0` (off) | Repository-wide daily cap for `loop:auto` PR attempts; manual issues and revisions bypass it |
| `loop.maxOpenAutoIssues` | `3` | Concurrent self-generated issue cap |
| `loop.goalFile` | `"auto"` | Goal source for autonomous planning; discovers `.loop/GOAL.md`, `BACKLOG.md`, or `.squad/GOAL.md` |
| `loop.workScope` | `"all"` | `"all"` \| `"green-fit"` (only deterministic, well-scoped autonomous tasks) |
| `loop.criticRubric` | `"auto"` | `"auto"` \| `"repo-aware"` \| repository-relative rubric path |
| `loop.implementer` | `"plain"` | `"plain"` (restricted) \| `"squad"` (full Squad coordinator; v0.1 recommended path) |

### Interactive settings in `.env.workers`

| Setting | Default | Description |
| --- | --- | --- |
| `INTERACTIVE_REPO_URL` | empty | Optional repository cloned into the trusted workstation |
| `INTERACTIVE_WORKSPACE_NAME` | `repo` | Workspace directory below `/workspace` |
| `INTERACTIVE_ENABLE_TTYD` | `false` | Enable the writable browser terminal |
| `INTERACTIVE_BIND_ADDRESS` | `127.0.0.1` | Bind address for interactive SSH, ttyd, and preview ports |
| `INTERACTIVE_TTYD_PORT` | `7681` | Interactive browser-terminal port |
| `INTERACTIVE_SSH_PORT` | `2222` | Interactive SSH port |
| `INTERACTIVE_VOLUME_PREFIX` | `hangar` | Stable volume prefix; keep unchanged when upgrading existing data |

### `deploy.sh` commands

```text
./deploy.sh up                  Start interactive Hangar and all workers
./deploy.sh down                Stop the complete Hangar platform
./deploy.sh restart [N]         Restart worker N
./deploy.sh restart-interactive Rebuild/restart only the interactive service
./deploy.sh reset [N]           Wipe workspace volume and restart worker N
./deploy.sh generate            Regenerate compose file only (no docker action)
./deploy.sh status              Show all services in the unified stack
./deploy.sh set-model <model>   Update Copilot model for all workers
```

---

## 🔒 Security model

Hangar uses separate OS identities and layered process controls for the trusted publisher and the
component that runs Copilot-generated code:

| User | Automated pipeline role | Security boundary |
| --- | --- | --- |
| `copilot` (publisher) | Own GitHub App credentials, sanitize Git config, orchestrate gates, push branches, create PRs | Trusted operator identity; automated build/test commands are delegated rather than run with publisher credentials |
| `squad-agent` (implementer) | Write code, run local shell/tests in `/workspace`, read external docs and configured repository MCP tools | Cannot traverse publisher home, use publisher sudo, or receive a repository-authorized token |

Additional mitigations:

- **`credential-guard`** binary + LD_PRELOAD constructor — the model PAT is delivered through
  an anonymous pipe, token-bearing processes are marked non-dumpable after every exec, and shell,
  delegated agents, and MCP processes cannot read those environments through `/proc`.
- **Publication barrier** — full Squad sessions explicitly deny `git push`/`git send-pack`, disable
  the built-in GitHub MCP, strip named auth variables from shell/MCP environments, and receive no
  repository-authorized credential. External web reads and explicitly configured repository MCP
  servers remain available and can transmit repository data; review them as trusted code.
- **Loopback-only management ports** — ttyd and SSH do not bind to `0.0.0.0` by default.
- **Human-gated merges** — workers open PRs; only a human can merge.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full trust boundary diagram and
threat model.

---

## Current limitations (v0.1)

- **Source-only** — no prebuilt Docker image, no published npm package, no CLI installer.
  Build from source with `./deploy.sh up`.
- One repository per worker container. Multi-repo workers are not yet supported.
- The Cockpit dashboard is functional but minimal.
- Autonomous mode (`loop.autonomous: true`) is experimental. Enable only with a low
  `maxPrsPerDay` and review every PR manually until you trust the output quality. The cap applies
  only to `loop:auto` work; human-created `squad` issues remain immediately eligible.
- Requires an active GitHub Copilot subscription. Copilot models are not self-hosted; all
  inference happens via GitHub's Copilot API.

---

## Documentation

| Document | Contents |
| --- | --- |
| [docs/INSTALL.md](docs/INSTALL.md) | Full installation guide — prerequisites, GitHub App setup, first worker |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | System design, trust boundaries, threat model, component map |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Day-to-day ops: logs, scaling, credential rotation, debugging |

---

## Contributing

Issues and pull requests are welcome. Please open an issue to discuss non-trivial changes before
submitting a PR. All contributions must pass the test suite in `tests/`.

---

## License

MIT — see [LICENSE](LICENSE).

---

<div align="center">
  <sub>
    Hangar is an independent open-source project and is not affiliated with or endorsed by GitHub, Inc.<br/>
    GitHub® and GitHub Copilot® are registered trademarks of GitHub, Inc.<br/>
    A valid GitHub Copilot subscription and acceptance of
    <a href="https://docs.github.com/en/site-policy/github-terms/github-terms-for-additional-products-and-features">GitHub's terms</a>
    are required to use this software.
  </sub>
</div>
