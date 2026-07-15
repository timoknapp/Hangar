# Migrating from copilot-workstation to Hangar

> Return to [README](../README.md)

---

## Overview

If you have been running the older **`copilot-workstation`** layout (a single Docker Compose
project with a Cockpit container plus worker containers, typically stored in a
`copilot-workstation/` subdirectory), this guide walks you through migrating to the
**Hangar** layout.

The migration is **low-risk but not zero-risk**. Follow the backup strategy in
[Step 1](#step-1-back-up-first) before making any changes.

> **Note on Compose project and volume names.** The old layout normally used a Compose project
> name derived from its directory. Hangar explicitly uses `hangar-fleet`, normally producing
> volumes such as `hangar-fleet_squad-worker-N-workspace`. These are different volumes — old
> data is not automatically available under the new names. Decide whether to migrate workspace
> data or allow workers to re-clone (see [Step 4](#step-4-decide-on-workspace-data)).

---

## Step 1: Back up first

Before touching anything, take a snapshot of your current state.

### 1a. Export a list of open claims (issues currently being worked on)

For every assigned repository, export open issues and inspect both legacy `claimed-by-*` labels
and current `squad:processing` state. Also list `refs/heads/squad-claims/*` through the GitHub API.
Save these results outside either source checkout as rollback evidence.

Review this list. If any workers are actively processing issues, wait for them to complete
(or remove the claim labels manually after stopping containers — do not leave orphaned claims).

### 1b. Stop old workers gracefully

```bash
# From the directory containing your old docker-compose.workers.yml
docker compose -f docker-compose.workers.yml down
```

Confirm with `docker ps` that no `squad-worker-*` or `cockpit` containers are running.
After graceful shutdown, confirm no claim ref remains for an interrupted issue. Do not delete a
claim ref until you have verified the owning worker is stopped and preserved its workspace.

### 1c. Copy workspace volumes (optional, see Step 4)

If you want to preserve in-progress work from workspace volumes, copy them now:

```bash
# Example: copy worker-1 workspace to a backup volume
docker run --rm \
  -v <old-workspace-volume>:/source:ro \
  -v hangar-migration-worker-1-backup:/backup \
  alpine sh -c "cp -a /source/. /backup/"
```

Repeat for each worker whose workspace you want to preserve.

---

## Step 2: Clone (or pull) the Hangar repository

```bash
# If you haven't cloned Hangar yet:
git clone https://github.com/<your-org>/hangar.git
cd hangar

# If you already have a checkout:
cd hangar && git pull
```

---

## Step 3: Create the new configuration files

### 3a. Environment file

```bash
cp .env.workers.example .env.workers
```

Open `.env.workers`. Copy your existing values from the old setup:

| Old variable | New variable | Notes |
| --- | --- | --- |
| `GH_APP_ID` | `GH_APP_ID` | Same |
| `GH_APP_INSTALL_ID` | `GH_APP_INSTALL_ID` | Same |
| `GH_APP_PEM_FILE` | `GH_APP_PEM_FILE` | Absolute path; update if the file moved |
| `COPILOT_PAT` | `COPILOT_PAT` | Same token; verify it has not expired |
| `ENABLE_TTYD` | `ENABLE_TTYD` | Same; default `false` |
| `SSH_AUTHORIZED_KEY` | `SSH_AUTHORIZED_KEY` | Same |
| Worker port overrides | `TTYD_PORT_WN` / `SSH_PORT_WN` | Rename if needed; check for conflicts |

### 3b. Repository assignment

```bash
cp repos.example.json repos.json
```

Open `repos.json` and add an entry for each worker you had in the old setup. The structure is
the same as the old `repos.json` if you used one, with the addition of the `loop` object for
Ground Control settings.

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
      "verify":            "auto",
      "maxPrsPerDay":      2,
      "maxOpenAutoIssues": 3,
      "workScope":         "green-fit",
      "criticRubric":      "repo-aware",
      "implementer":       "squad"
    }
  }
}
```

Reproduce one entry per worker from your old configuration.

---

## Step 4: Decide on workspace data

You have two options for each worker's workspace:

### Option A: Re-clone (recommended for most cases)

Let Hangar clone the repository fresh. This is safe when:

- No uncommitted work exists in the old workspace
- No in-progress Copilot session was interrupted mid-way

Re-clone happens automatically on `./deploy.sh up` — the entrypoint clones the repo if
`/workspace/<repo>` is empty.

### Option B: Migrate workspace data

If you have valuable uncommitted work in an old workspace volume, create the new containers and
volumes **without starting the worker loop**, then restore the data:

```bash
# Generate configuration and create stopped containers/volumes
./deploy.sh generate
docker compose -p hangar-fleet -f docker-compose.workers.yml \
  --env-file .env.workers create

# Overlay the old workspace onto the new volume
# WARNING: this overwrites the fresh clone — only do this if you have uncommitted work to recover
docker run --rm \
  -v hangar-migration-worker-1-backup:/source:ro \
  -v hangar-fleet_squad-worker-1-workspace:/dest \
  alpine sh -c "cp -a /source/. /dest/"

# Start only after every selected volume has been restored and checked
./deploy.sh up
```

After restart, verify the workspace state:

```bash
docker exec squad-worker-1 git -C /workspace/<repo> status
```

---

## Step 5: Start Hangar

```bash
./deploy.sh up
./deploy.sh status
docker logs squad-worker-1
```

A healthy startup looks like:

```text
>>> [worker-1] Starting Squad Worker container...
>>> [worker-1] AUTO_UPDATE_CLI=false — skipping CLI update check
>>> [worker-1] Launching worker loop as copilot...
[<timestamp>] [worker-1] Squad Worker starting (poll_interval=60s, repo=<owner>/<repo>)
```

---

## Step 6: Verify and clean up

### 6a. Confirm workers are polling correctly

```bash
docker logs -f squad-worker-1   # watch for poll cycles
```

### 6b. Verify no orphaned claims

Check for both legacy `claimed-by-*` labels and current `squad:processing` labels. Current Hangar
workers coordinate through `refs/heads/squad-claims/issue-N`, so inspect matching refs as well.

```bash
gh issue list --repo <owner>/<repo> --label "squad:processing" --state open --json number,title
gh api repos/<owner>/<repo>/git/matching-refs/heads/squad-claims/
```

Remove any stale claims manually:

```bash
gh issue edit <number> --repo <owner>/<repo> --remove-label "<stale-label>"
```

### 6c. Remove old volumes (after confirming migration is successful)

> **Only do this after running Hangar successfully for at least one complete issue cycle.**

```bash
# List old volumes to confirm names
docker volume ls | grep copilot-workstation

# Remove them (irreversible)
docker volume rm copilot-workstation_squad-worker-1-workspace
docker volume rm copilot-workstation_squad-worker-1-copilot-data
docker volume rm copilot-workstation_squad-worker-1-sshd
# Repeat for each worker
```

### 6d. Remove old backup volumes (optional)

```bash
docker volume rm hangar-migration-worker-1-backup
```

---

## Rollback strategy

If Hangar is not working correctly, you can return to the old setup:

1. Stop Hangar: `./deploy.sh down`
2. Return to the old directory: `cd /path/to/old/copilot-workstation`
3. Start the old workers: `docker compose -f docker-compose.workers.yml up -d`

Your old volumes are still intact unless you explicitly deleted them. The old and new setups
use different volume names so they do not conflict.

---

## Key differences summary

| Aspect | Old copilot-workstation | Hangar |
| --- | --- | --- |
| Compose project name | Directory-derived (commonly `copilot-workstation`) | `hangar-fleet` |
| Volume name pattern | `<old-project>_squad-worker-N-*` | `hangar-fleet_squad-worker-N-*` |
| Container name pattern | `squad-worker-N` (same) | `squad-worker-N` (same) |
| Compose file | Manually maintained or generated | Always auto-generated by `deploy.sh` |
| Configuration | `repos.json` + `.env.workers` | `repos.json` + `.env.workers` (same structure) |
| Ground Control | Basic loop | Full critic / verify / budget controls via `loop` object |
| Cockpit | Integrated `cockpit` container | Built into each worker; `ENABLE_TTYD=true` |
| Image build | `worker/Dockerfile` | `worker/Dockerfile` (same; worker image only) |

---

> Back to [README](../README.md) · [Install](INSTALL.md) · [Operations](OPERATIONS.md)
