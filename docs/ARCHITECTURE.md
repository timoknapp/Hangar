# Hangar — Architecture

> Return to [README](../README.md)

---

## Table of contents

1. [System overview](#1-system-overview)
2. [Component map](#2-component-map)
3. [Trust boundaries and credential separation](#3-trust-boundaries-and-credential-separation)
4. [The worker loop in detail](#4-the-worker-loop-in-detail)
5. [Ground Control features](#5-ground-control-features)
6. [Cockpit (management interface)](#6-cockpit-management-interface)
7. [Networking](#7-networking)
8. [Data flows](#8-data-flows)
9. [Threat model](#9-threat-model)
10. [Design decisions](#10-design-decisions)

---

## 1. System overview

Hangar turns a server (or development machine) into an autonomous PR factory. Each worker
container runs a tight polling loop: find an unclaimed issue → claim it atomically → implement
it with Copilot → run the configured verification gate → optionally run a fresh critic → open a
ready PR or clearly flagged draft.
A human reviews and merges.

```text
┌─────────────────────────────────────────────────────────┐
│                     Hangar host                         │
│                                                         │
│  deploy.sh ──► docker-compose.workers.yml               │
│                │                                        │
│                ├── squad-worker-1 (repo A)              │
│                ├── squad-worker-2 (repo B)              │
│                └── squad-worker-N (…)                   │
└─────────────────────────────────────────────────────────┘
          │                        ▲
          │ polls / claims          │ PRs / labels
          ▼                        │
    GitHub Issue Board        GitHub API
                                   │
                              Human reviews
                              and merges ✓
```

---

## 2. Component map

### Host-level files

| File | Role |
| --- | --- |
| `deploy.sh` | Orchestration entrypoint: generates compose file, drives `docker compose` |
| `repos.json` | Fleet configuration — maps worker IDs to repositories and loop settings |
| `.env.workers` | Secret values (GitHub App credentials, Copilot PAT, port overrides) |
| `docker-compose.workers.yml` | Auto-generated; do not edit by hand |

### Worker container

| Component | Path in image | Role |
| --- | --- | --- |
| `entrypoint.sh` | `/entrypoint.sh` | Root-level init: fixes volume permissions, clones repo, drops to `copilot` |
| `worker-loop.sh` | `/home/copilot/worker-loop.sh` | Main polling loop running as `copilot` |
| `credential-guard` | `/usr/local/bin/credential-guard` | Compiled binary wrapping `copilot` CLI; used to run credential-isolated sessions |
| `libcredential-guard.so` | `/usr/local/lib/libcredential-guard.so` | LD_PRELOAD constructor: reapplies non-dumpable/no-new-privileges protection after exec |
| `git-credential-helper.sh` | `/home/copilot/git-credential-helper.sh` | Returns the GitHub App token for `git` operations; not visible to `squad-agent` |
| `generate-token.sh` | `/home/copilot/generate-token.sh` | Exchanges GitHub App PEM for a short-lived installation token |
| `runtime-preflight.sh` | `/home/copilot/runtime-preflight.sh` | Optional explicit Copilot credential/model probe |
| `toolbar.js` + `nginx.conf` | `/var/www/html/toolbar.js` | Cockpit toolbar injected into ttyd sessions via nginx reverse proxy |

### Worker image (two-stage build)

```text
Stage 1: debian:12-slim + gcc
  └── compiles credential-guard binary + LD_PRELOAD shim

Stage 2: debian:12-slim + Node 22
  ├── system tools: git, jq, curl, openssl, tmux, openssh-server, nginx
  ├── GitHub CLI (gh)
  ├── @github/copilot CLI (pinned build-time version; optional update check)
  ├── @bradygaster/squad-cli (pinned build-time version; optional update check)
  ├── ttyd 1.7.7 (web terminal)
  ├── users: copilot (publisher) + squad-agent (implementer), group: squad
  └── credential-guard artifacts from Stage 1
```

---

## 3. Trust boundaries and credential separation

The core security property of Hangar is that the process which **can call GitHub** and the
process which **runs AI-generated code** are different OS users in the same container. This is
OS/process isolation and defense in depth, not a hardware or VM security boundary.

```text
┌──────────────────────────────────────────────────────────┐
│  Worker container                                        │
│                                                          │
│  ┌───────────────────────────────────────────────────┐   │
│  │ copilot user (publisher)                          │   │
│  │  • owns GitHub App token (PEM mount + token file) │   │
│  │  • owns COPILOT_PAT (env var)                     │   │
│  │  • runs worker-loop.sh                            │   │
│  │  • is the ONLY process that may:                  │   │
│  │      git push, gh pr create, gh label             │   │
│  └──────────────────┬────────────────────────────────┘   │
│                     │ sudo -n -u squad-agent /usr/bin/env │
│  ┌──────────────────▼────────────────────────────────┐   │
│  │ squad-agent user (implementer)                    │   │
│  │  • NO access to publisher key/token (permissions) │   │
│  │  • runs Copilot implementation sessions           │   │
│  │  • can write to /workspace (shared via squad GID) │   │
│  │  • has no repository-authorized GitHub credential │   │
│  └───────────────────────────────────────────────────┘   │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │ credential-guard + LD_PRELOAD constructor          │  │
│  │  receives the model PAT through stdin and marks    │  │
│  │  token-bearing processes non-dumpable after exec   │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

### Credential separation invariants

1. `GH_APP_PEM_FILE` is mounted read-only and copied into the publisher's mode-`400`, private
  home directory. `squad-agent` cannot traverse that home or read the short-lived token file.
2. `COPILOT_PAT` is piped to `credential-guard`; it does not appear in parent argv/environment.
  The guard sets the Copilot auth variable only inside a non-dumpable process tree, and Copilot's
  secret-env policy strips named auth variables from shell and MCP child environments.
3. Full Squad sessions deny `git push` and `git send-pack`, disable the built-in GitHub MCP, and
  receive no repository-authorized token. They retain shell, external web reads, and explicitly
  attached repository MCP servers so they can still perform capable implementation work.
4. The `copilot` sudo rule is tightly scoped: `copilot ALL=(squad-agent) NOPASSWD: /usr/bin/env`
   — it can only drop to `squad-agent` via `env`, not elevate to root.

---

## 4. The worker loop in detail

```text
entrypoint.sh (root)
  → fix volume permissions
  → clone repo into /workspace/<repo>
  → configure git identity (GitHub App token via credential helper)
  → exec worker-loop.sh as copilot user

worker-loop.sh (copilot user)
  ┌── runtime preflight: smoke-test Copilot auth
  │
  └─ polling loop (every POLL_INTERVAL seconds):
       1. prioritize open issues carrying `squad:revision`, then regular `squad` issues
       2. for each eligible issue:
          a. atomically create refs/heads/squad-claims/issue-<number>
          b. add the visible squad:processing label and worker comment
            c. create branch squad/<issue-number>-<slug>
            d. reset branch to DEFAULT_BRANCH HEAD
            e. sudo -n -u squad-agent: run Copilot implementation session
               (implementer=plain → restricted shell-less session)
            (implementer=squad → full Squad custom-agent multi-agent session)
            f. capture residual edits in a local commit
            g. run verify hook (or classify disabled/unavailable verification)
            h. [optional] run an attested critic session only after verification
            i. re-verify any critic-driven correction
            j. publisher pushes and creates a ready PR on pass or draft on unresolved gates
            k. release the atomic claim ref and update labels/comments
```

### Implementer modes

| Mode | CLI | Network | GitHub access |
| --- | --- | --- | --- |
| `plain` | `@github/copilot` | blocked | none |
| `squad` | `@github/copilot --agent squad` | external docs + configured repository MCPs allowed | no repository-authorized token; builtin GitHub MCP disabled |

---

## 5. Ground Control features

### Atomic claims

The worker creates `refs/heads/squad-claims/issue-<number>` through GitHub's ref API before any
visible label mutation. Ref creation is atomic: one worker wins and siblings skip. The winner then
adds `squad:processing`; labels are operator-visible state, not the concurrency primitive.

### Independent critic

When `loop.critic: true`, after the implementation session completes, a **separate** Copilot
session runs against the diff. The critic session:

- starts with no knowledge of the implementation session's chat history
- optionally uses a different model (`loop.criticModel`)
- reads the diff from a workspace-scoped file (not via network)
- reads rubric/issue/diff from a temporary workspace file and must echo a nonce found only there
- outputs exactly one attested `APPROVE` or `REQUEST_CHANGES` verdict

If the critic returns `REQUEST_CHANGES` and retries remain (`loop.maxRetries`), the implementation
session is retried with the critic's feedback as additional context.

### Verify hook

`loop.verify` options:

| Value | Behaviour |
| --- | --- |
| `"off"` | No verification |
| `"auto"` | Loop detects and runs the project's test suite (npm test, pytest, etc.) |
| `".loop/verify.sh"` | Runs the specified script at the workspace root |
| `"<command>"` | Runs the literal command string |

Verify runs as `squad-agent` inside the workspace. A non-zero exit code triggers a retry up to
`maxRetries`; unresolved gates create or update a clearly flagged draft PR for human review.

### Budget and draft safety

- `maxPrsPerDay` — enforced repository-wide through atomic `squad-budget/YYYY-MM-DD/slot-N`
  Git refs, shared by sibling workers and durable across restarts; revisions bypass this new-PR cap
- `maxOpenAutoIssues` — in `loop.autonomous` mode, limits concurrent self-generated issues so
  the board doesn't fill up with stale work

---

## 6. Cockpit (management interface)

The Cockpit is an nginx reverse proxy that:

1. Serves **ttyd** (web terminal) on port 8080 inside the container.
2. Injects `toolbar.js` into every page — a mobile touch toolbar for terminal keys and common
  Copilot/Squad commands.

Enabled with `ENABLE_TTYD=true`. The nginx config (`worker/nginx.conf`) proxies `/` to ttyd
and injects the toolbar script via `sub_filter`.

The Cockpit is intentionally minimal, but it is **not read-only**: it is a writable shell as the
publisher user. Keep it disabled unless needed and protect it with VPN/reverse-proxy authentication.

---

## 7. Networking

### Container ports (defaults)

| Port (host) | Port (container) | Service | Binds to |
| --- | --- | --- | --- |
| 7691 + N | 8080 | ttyd / Cockpit | `127.0.0.1` |
| 2231 + N | 22 | SSH | `127.0.0.1` |

Where N is the worker index (0-based). All bindings are loopback-only unless overridden with
`TTYD_PORT_WN` / `SSH_PORT_WN` environment variables in `.env.workers`.

### Outbound connections (from worker containers)

| Destination | Protocol | Purpose |
| --- | --- | --- |
| `api.github.com` | HTTPS 443 | Issue polling, PR creation, label operations |
| `github.com` | HTTPS 443 | git clone / push |
| `registry.npmjs.org` | HTTPS 443 | Build-time install; optional CLI update check when enabled |
| GitHub Copilot API | HTTPS 443 | Copilot inference (via PAT) |

Implementation sessions (running as `squad-agent`) can access external documentation and configured
repository MCP endpoints. They receive no publisher token and cannot use Hangar's publisher path,
but outbound access can transmit source data. The `copilot` publisher user retains GitHub access.

---

## 8. Data flows

### Secret handling

```text
.env.workers (host file)
  ↓ docker compose --env-file
  ↓ container environment (copilot user)
  ├── GH_APP_PEM_FILE → /run/secrets/gh-app-key.pem (read-only bind mount)
  │     ↓ generate-token.sh
  │     → /home/copilot/.github-app-token (short-lived; refreshed every ~45 min)
    └── COPILOT_PAT → worker-loop private environment
        ↓ passed as stdin to `credential-guard copilot`
      → non-dumpable Copilot process tree as squad-agent
      → stripped from shell/MCP child environments by Copilot policy
```

### Workspace data

```text
Docker volume: squad-worker-N-workspace
  → /workspace/<repo>   (git checkout; shared copilot:squad 0g+s)

Docker volume: squad-worker-N-copilot-data
  → /home/copilot/.local/share   (Copilot CLI state, session cache)

Docker volume: squad-worker-N-sshd
  → /etc/ssh   (SSH host keys; preserved across restarts)
```

---

## 9. Threat model

### In scope

| Threat | Mitigation |
| --- | --- |
| AI-generated code reading publisher/model credentials | OS file permissions; anonymous-pipe token delivery; non-dumpable process tree; Copilot secret-env policy |
| Worker pushing malicious code directly | `squad-agent` cannot push; only `copilot` can push, and only to a PR branch |
| Two workers claiming the same issue | Atomic Git ref creation before visible labels |
| Copilot session mutating GitHub through Hangar | No repository-authorized child token; builtin GitHub MCP disabled; push/send-pack denied |
| Runaway autonomous mode flooding repos | `maxPrsPerDay`, `maxOpenAutoIssues` caps |
| Token exfiltration via `/proc` | Non-dumpable guard before/after exec; live same-user isolation probes |
| Source exfiltration over allowed web/MCP access | Out of scope for technical prevention; target repos and MCP config are trusted, egress must be restricted externally if required |

### Out of scope

- Compromised Hangar host OS (root access bypasses all container-level mitigations)
- GitHub API-level attacks (covered by GitHub's own security controls)
- Vulnerabilities in the Copilot CLI itself
- Supply chain attacks on `@github/copilot` or `@bradygaster/squad-cli` npm packages

### Human-in-the-loop requirement

Hangar is designed for **assisted autonomy**, not full autonomy. The merge gate is intentionally
held by a human reviewer. Autonomous mode (`loop.autonomous: true`) lets workers self-generate
issues, but every PR must be reviewed before merging. Treat every Hangar PR the same as any
other externally submitted patch.

---

## 10. Design decisions

### Why a GitHub App instead of a PAT for publishing?

GitHub Apps provide fine-grained, installation-scoped permissions and short-lived tokens (1-hour
JWT exchange). A PAT with equivalent repository permissions is a long-lived credential and a
larger blast radius if leaked.

### Why a native guard plus LD_PRELOAD constructor?

Filtering environment variables at the `sudo` boundary is not sufficient because same-user
processes can inspect `/proc/<pid>/environ`. The launcher accepts the model token through stdin,
sets it only after becoming non-dumpable, and installs a small constructor that reapplies
`PR_SET_DUMPABLE=0` and `PR_SET_NO_NEW_PRIVS` after every dynamic exec.

### Why one repository per worker?

Simplifies the trust model (each container's blast radius is exactly one repository), makes
volume management straightforward, and avoids cross-repository credential confusion. Multi-repo
support is a future roadmap item.

### Why pin CLI versions by default?

Copilot and Squad evolve quickly, so unattended `@latest` upgrades can break policy flags or
agent contracts. Hangar pins reviewed build-time versions and defaults `AUTO_UPDATE_CLI=false`.
Operators may opt into startup update checks and should rerun Hangar's capability/critic proofs.

---

> Back to [README](../README.md) · [Install](INSTALL.md) · [Operations](OPERATIONS.md)
