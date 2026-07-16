# Hangar — Installation Guide

> Return to [README](../README.md)

---

## Table of contents

1. [System requirements](#1-system-requirements)
2. [GitHub App setup](#2-github-app-setup)
3. [Copilot PAT](#3-copilot-pat)
4. [Clone and configure](#4-clone-and-configure)
5. [Build and start Hangar](#5-build-and-start-hangar)
6. [Verify the installation](#6-verify-the-installation)
7. [Optional: browser terminals](#7-optional-browser-terminals)
8. [Optional: SSH access](#8-optional-ssh-access)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. System requirements

| Requirement | Minimum | Notes |
| --- | --- | --- |
| OS | Linux host or macOS with Docker Desktop | Use a dedicated Linux host/VM for unattended production workers |
| Docker Engine | 24+ | `docker --version` |
| Docker Compose | v2 (plugin) | `docker compose version` — note: no hyphen |
| `jq` | 1.6+ | `brew install jq` / `apt install jq` |
| RAM / disk | Workload-dependent | Size for the target repository's builds plus concurrent Copilot/Squad processes |
| Outbound internet | Required | GitHub, GitHub Copilot, external docs/MCP endpoints, and package registries used by builds |

---

## 2. GitHub App setup

Hangar uses a **GitHub App** (not a PAT) to push branches and create pull requests. The App
token is the publisher credential and must be kept separate from the Copilot PAT.

### Create the App

1. Go to **GitHub → Settings → Developer settings → GitHub Apps → New GitHub App**.
2. Set a name (e.g. `Hangar Worker Fleet`).
3. Set the Homepage URL to your Hangar host or any placeholder.
4. Disable the **Webhook** (uncheck "Active").
5. Under **Repository permissions**, grant:
   - **Contents** — Read & write
   - **Issues** — Read & write
   - **Pull requests** — Read & write
   - **Actions** — Read (lets revision prompts include failed check logs)
   - **Metadata** — Read (required)
6. Under **Where can this GitHub App be installed**, choose your preference.
7. Click **Create GitHub App**.
8. Note down the **App ID** (visible on the app's settings page).
9. Under **Private keys**, click **Generate a private key** and save the `.pem` file securely.

### Install the App on a repository

1. From the App's settings page, click **Install App**.
2. Choose the account/organisation and select the target repository.
3. Note down the **Installation ID** from the URL:
   `https://github.com/settings/installations/<INSTALLATION_ID>`

Set these in `.env.workers`:

```dotenv
GH_APP_ID=<App ID>
GH_APP_INSTALL_ID=<Installation ID>
GH_APP_PEM_FILE=/absolute/path/to/hangar-worker-fleet.private-key.pem
```

---

## 3. Copilot PAT

The Copilot PAT is a **user-owned fine-grained PAT** and must be completely separate from the
GitHub App. It authenticates Copilot inference requests only.

1. Go to **GitHub → Settings → Developer settings → Fine-grained personal access tokens →
   Generate new token**.
2. Under **Account permissions**, enable **Copilot Requests: Read and write**.
3. Grant **no repository permissions**. The GitHub App already handles repository operations;
   giving this token repository access violates the credential separation model.
4. Set an expiry that matches your credential policy; Hangar does not auto-rotate this token.
5. Copy the token and set it in `.env.workers`:

```dotenv
COPILOT_PAT=github_pat_...
```

The PAT owner must have an active GitHub Copilot plan that permits Copilot CLI use.

---

## 4. Clone and configure

```bash
git clone https://github.com/timoknapp/Hangar.git
cd Hangar
```

### Environment file

```bash
cp .env.workers.example .env.workers
```

Open `.env.workers` and fill in the four required values from sections 2 and 3. The same file also
contains namespaced `INTERACTIVE_*` settings for the trusted workstation service; defaults keep
all management ports on loopback.

### Repository assignment

```bash
cp repos.example.json repos.json
```

Edit `repos.json`. Each top-level key is a worker ID (e.g. `worker-1`, `worker-2`).

```json
{
  "worker-1": {
    "url":    "https://github.com/your-org/your-repo.git",
    "owner":  "your-org",
    "repo":   "your-repo",
    "branch": "main",
    "model":  "",
    "effort": "",
    "context": "",
    "loop": {
      "autonomous":         false,
      "critic":             true,
      "criticModel":        "",
      "verify":             "auto",
      "maxRetries":         2,
      "maxPrsPerDay":       2,
      "maxOpenAutoIssues":  3,
      "goalFile":           "auto",
      "workScope":          "green-fit",
      "criticRubric":       "repo-aware",
      "implementer":        "squad"
    }
  }
}
```

To add a second worker, append a `"worker-2": { … }` entry and run `./deploy.sh up` again.
Use HTTPS repository URLs; Hangar's publisher credential helper intentionally serves only
`https://github.com` and does not inject credentials into arbitrary hosts.

For `implementer: "squad"`, initialize and review the target repository's Squad configuration
before assigning it to an unattended worker. Repository-provided instructions, agent files, and
MCP configurations are trusted code with local shell and outbound-network capability.

---

## 5. Build and start Hangar

```bash
./deploy.sh up
```

This command:

1. Reads `repos.json` and generates `docker-compose.workers.yml`.
2. Combines `docker-compose.yml` with the generated worker services under project `hangar-fleet`.
3. Builds the trusted interactive image and guarded worker image.
4. Starts `hangar` plus every `squad-worker-N` service as one Compose stack.

The generated `docker-compose.workers.yml` is auto-generated and should not be edited by hand —
re-run `./deploy.sh generate` (or `up`) if you change `repos.json`.

---

## 6. Verify the installation

```bash
./deploy.sh status           # should show hangar plus all workers
docker logs hangar           # trusted interactive service
docker logs squad-worker-1   # watch startup messages
docker exec squad-worker-1 /home/copilot/runtime-preflight.sh
```

A healthy worker log looks like:

```text
>>> [worker-1] Starting Squad Worker container...
>>> [worker-1] AUTO_UPDATE_CLI=false — skipping CLI update check
>>> [worker-1] Launching worker loop as copilot...
[<timestamp>] [worker-1] Squad Worker starting (poll_interval=60s, repo=<owner>/<repo>)
[<timestamp>] [worker-1] No issues to process, sleeping 60s...
```

The explicit runtime preflight makes one Copilot request and prints
`Copilot runtime preflight: PASS (<default model>)` when authentication works. It is not run
automatically at every restart, avoiding an unconditional billable/model request. If it fails,
check the PAT, Copilot plan, and optional `COPILOT_MODEL` selection.

---

## 7. Optional: browser terminals

The trusted interactive service and each worker can expose a live tmux session via **ttyd**.
They remain separate security contexts even though Docker manages them in one stack.

```dotenv
# .env.workers
INTERACTIVE_ENABLE_TTYD=true
ENABLE_TTYD=true
```

Restart only what changed:

```bash
./deploy.sh restart-interactive
./deploy.sh restart 1
```

The interactive terminal is `http://127.0.0.1:7681`. Worker-1 is `http://127.0.0.1:7691`;
worker ports increment to 7692, 7693, and so on.

> **Do not expose ttyd to the internet.** Use a reverse proxy with authentication (e.g. nginx
> with `auth_basic`, or a VPN).

---

## 8. Optional: SSH access

Paste your public key in `.env.workers`:

```dotenv
SSH_AUTHORIZED_KEY=ssh-ed25519 AAAA... your-key-comment
```

Restart the worker. Connect to the trusted interactive service or a worker with:

```bash
ssh -p 2222 copilot@127.0.0.1
ssh -p 2231 copilot@127.0.0.1
```

Worker ports increment: 2232, 2233, etc.

---

## 9. Troubleshooting

### Worker exits immediately

Check `docker logs squad-worker-1`. Common causes:

- `COPILOT_PAT` is missing or has the wrong format (must start with `github_pat_`).
- `GH_APP_PEM_FILE` path is incorrect or the file is not readable by Docker.
- `repos.json` has no entry for `worker-1`.
- The repository URL is SSH-based; use `https://github.com/<owner>/<repo>.git`.

### `jq` not found

```bash
# macOS
brew install jq

# Debian/Ubuntu
sudo apt install jq
```

### Compose file not regenerating

Delete the stale file and regenerate:

```bash
rm docker-compose.workers.yml
./deploy.sh generate
```

### Copilot session fails with auth error

1. Confirm the PAT is a fine-grained token starting with `github_pat_`.
2. Confirm the PAT has only the **Copilot Requests** account permission.
3. Confirm the PAT owner has an active Copilot subscription.
4. Check that the PAT has not expired.

### Port conflicts

Override ports in `.env.workers`:

```dotenv
INTERACTIVE_TTYD_BIND_ADDRESS=127.0.0.1
INTERACTIVE_SSH_BIND_ADDRESS=192.168.1.10
INTERACTIVE_PREVIEW_BIND_ADDRESS=127.0.0.1
INTERACTIVE_TTYD_PORT=7800
INTERACTIVE_SSH_PORT=2300
TTYD_PORT_W1=7801
SSH_PORT_W1=2301
```

---

> Back to [README](../README.md) · [Architecture](ARCHITECTURE.md) · [Operations](OPERATIONS.md)
