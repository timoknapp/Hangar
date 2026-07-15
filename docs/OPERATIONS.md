# Hangar — Operations Guide

> Return to [README](../README.md)

---

## Table of contents

1. [Daily workflow](#1-daily-workflow)
2. [Fleet management](#2-fleet-management)
3. [Viewing logs](#3-viewing-logs)
4. [Cockpit web terminal](#4-cockpit-web-terminal)
5. [Worker health and preflight](#5-worker-health-and-preflight)
6. [Credential rotation](#6-credential-rotation)
7. [Scaling the fleet](#7-scaling-the-fleet)
8. [Workspace lifecycle](#8-workspace-lifecycle)
9. [Updating the CLI](#9-updating-the-cli)
10. [Rebuilding worker images](#10-rebuilding-worker-images)
11. [Debugging worker sessions](#11-debugging-worker-sessions)
12. [Monitoring and alerting](#12-monitoring-and-alerting)

---

## 1. Daily workflow

The normal operating pattern once Hangar is running:

1. **Open an issue** on the repository assigned to a worker.
2. **Apply the `squad` label** to put it on the worker queue.
3. **Wait** — the worker claims the issue within one `POLL_INTERVAL` (default: 60 seconds).
4. **Watch progress** via `docker logs -f squad-worker-1` or the Cockpit terminal.
5. **Review the PR** when it appears — treat it like any externally submitted patch.
6. **Merge** if satisfied. For another implementation pass, add the requested details to the issue
  and apply `squad:revision`; revision work is prioritized over new queue items.

---

## 2. Fleet management

### Start / stop

```bash
./deploy.sh up       # start all workers (regenerates compose first)
./deploy.sh down     # stop and remove all worker containers (volumes preserved)
```

### Restart a specific worker

```bash
./deploy.sh restart 1    # restart worker-1
./deploy.sh restart 3    # restart worker-3
```

### Reset a worker (wipe workspace)

```bash
./deploy.sh reset 1      # delete workspace volume and restart worker-1
```

Use this if the workspace git state is corrupted or if you want the worker to re-clone from
scratch. This does **not** delete the `copilot-data` or `sshd` volumes.

### Show running workers

```bash
./deploy.sh status
# or
docker compose -f docker-compose.workers.yml ps
```

### Change the Copilot model for all workers

Pass a model ID available to your Copilot plan to `./deploy.sh set-model`. This updates the model
in `repos.json`, regenerates the compose file, and recreates all running containers. Leave
`model` empty to use the Copilot CLI default rather than pinning an ID that may become stale.

---

## 3. Viewing logs

```bash
# Follow logs for a specific worker
docker logs -f squad-worker-1

# Last 100 lines
docker logs --tail=100 squad-worker-1

# All workers
docker compose -p hangar-fleet -f docker-compose.workers.yml --env-file .env.workers logs -f
```

### Log markers

| Prefix | Meaning |
| --- | --- |
| `>>> [worker-N]` | Container entrypoint messages |
| `[<UTC timestamp>] [worker-N]` | Worker-loop lifecycle, claims, gates, and publication |
| `[<UTC timestamp>] [worker-N] [copilot]` | Streamed implementation-session output |
| `ERROR:` inside a worker line | A failed operation or fail-closed safety decision |

---

## 4. Cockpit web terminal

Enable in `.env.workers`:

```dotenv
ENABLE_TTYD=true
```

Then restart the target worker:

```bash
./deploy.sh restart 1
```

Access the Cockpit at `http://127.0.0.1:7691` (worker-1). Worker-2 is at `7692`, etc.

The Cockpit opens a live, **writable** tmux session as the trusted `copilot` publisher user. You can:

- Watch the worker loop in real time
- Inspect `/workspace/<repo>` for uncommitted changes
- Run `gh pr list` to see recent PR activity

> **Security reminder.** The Cockpit does not require authentication by default and its shell can
> publish to GitHub. Keep it disabled unless needed. Never expose it directly; use a VPN or an
> authenticated reverse proxy and retain the default loopback bind.

### SSH access

If `SSH_AUTHORIZED_KEY` is set in `.env.workers`:

```bash
ssh -p 2231 copilot@127.0.0.1    # worker-1
ssh -p 2232 copilot@127.0.0.1    # worker-2
```

---

## 5. Worker health and preflight

The image includes `runtime-preflight.sh`, an explicit live Copilot API probe for checking the
credential and configured/default model. It is not invoked automatically on every restart.

### Manual preflight

```bash
docker exec squad-worker-1 /home/copilot/runtime-preflight.sh
```

A passing preflight prints: `Copilot runtime preflight: PASS (<model or default model>)`

A failing preflight usually means:

- `COPILOT_PAT` is expired or invalid
- The PAT owner's Copilot subscription has lapsed
- The specified model is not available on the account's subscription tier

### Check active claims

```bash
gh issue list --repo <owner>/<repo> --label "squad:processing" --state open
gh api repos/<owner>/<repo>/git/matching-refs/heads/squad-claims/
```

---

## 6. Credential rotation

### Rotating the Copilot PAT

1. Generate a new fine-grained PAT (Copilot Requests account permission only) from GitHub Settings.
2. Update `COPILOT_PAT` in `.env.workers`.
3. Restart all workers: `./deploy.sh down && ./deploy.sh up`

Workers do not cache the PAT between restarts; the new value takes effect immediately on the
next container start.

### Rotating the GitHub App private key

1. In your GitHub App settings, generate a new private key.
2. Replace the `.pem` file at the path specified in `GH_APP_PEM_FILE`.
3. Restart workers: `./deploy.sh down && ./deploy.sh up`
4. Revoke the old private key from the GitHub App settings.

> The short-lived App installation token (generated from the PEM) is refreshed roughly every
> 45 minutes by `generate-token.sh`. A key rotation takes effect on the next token refresh
> after the container restart.

---

## 7. Scaling the fleet

### Adding a worker

1. Add a new entry to `repos.json`:

   ```json
   "worker-3": {
     "url":   "https://github.com/your-org/another-repo.git",
     "owner": "your-org",
     "repo":  "another-repo",
     "branch": "main",
    "model": "",
     "loop": {
       "autonomous": false,
       "critic": true,
       "verify": "auto",
       "maxPrsPerDay": 2,
       "workScope": "green-fit",
       "criticRubric": "repo-aware",
       "implementer": "squad"
     }
   }
   ```

2. Run `./deploy.sh up` — only the new container is created; existing workers are unaffected.

### Removing a worker

1. Stop the specific container: `docker stop squad-worker-3 && docker rm squad-worker-3`
2. Remove the entry from `repos.json`.
3. Optionally remove the volumes:

   ```bash
   docker volume rm \
     hangar-fleet_squad-worker-3-workspace \
     hangar-fleet_squad-worker-3-copilot-data \
     hangar-fleet_squad-worker-3-sshd
   ```

4. Regenerate the compose file: `./deploy.sh generate`

### Multiple workers on the same repository

You can point multiple workers at the same repository. Workers coordinate through atomic Git
refs (`squad-claims/issue-N`) and use labels only as visible workflow state. Repository-wide
`squad-budget/<date>/slot-N` refs coordinate the daily new-PR budget.
This is useful for parallelising work on a large backlog but requires careful rate-limit
awareness (GitHub API quota is shared per installation).

---

## 8. Workspace lifecycle

Each worker's repository checkout lives in a Compose-managed volume mounted at
`/workspace/<repo>`. With the default project name, Docker normally renders it as
`hangar-fleet_squad-worker-N-workspace`; confirm the exact name with `docker volume ls`.

### Inspect the workspace

```bash
docker exec -it squad-worker-1 bash
ls /workspace/
git -C /workspace/<repo> log --oneline -5
```

### Hard reset (without destroying the volume)

```bash
docker exec squad-worker-1 bash -c \
  "git -C /workspace/<repo> reset --hard origin/main && git clean -fd"
```

### Full volume wipe and re-clone

```bash
./deploy.sh reset 1
```

---

## 9. Updating the CLI

Workers use the Copilot and Squad CLI versions pinned in `worker/Dockerfile` by default.
This keeps policy flags and custom-agent behavior reproducible.

To opt into unreviewed upstream updates on each container start:

```bash
AUTO_UPDATE_CLI=true     # in .env.workers
./deploy.sh restart 1
```

For a reviewed upgrade, leave `AUTO_UPDATE_CLI=false`, update the two version arguments in
`worker/Dockerfile`, rebuild, and rerun the complete local/live validation suite before rollout.

```bash
AUTO_UPDATE_CLI=false
./deploy.sh up
```

---

## 10. Rebuilding worker images

The worker image is built on `./deploy.sh up` if it doesn't exist. To force a rebuild:

```bash
# Force rebuild without cache (picks up OS + npm updates)
docker compose -f docker-compose.workers.yml build --no-cache

# Then restart
./deploy.sh down && ./deploy.sh up
```

Set `CACHE_BUST` explicitly only when you need to invalidate the CLI install layer; normal
`./deploy.sh up` builds reuse Docker's cache and the pinned versions.

---

## 11. Debugging worker sessions

### Attaching to a running worker

```bash
docker exec -it squad-worker-1 bash
# You are now the copilot user inside the container
```

### Inspecting a failed implementation session

After a failed attempt, the workspace branch remains checked out with any partial changes:

```bash
docker exec -it squad-worker-1 bash
git -C /workspace/<repo> log --oneline -3
git -C /workspace/<repo> diff HEAD
```

### Running a manual implementation session

Do not invoke `copilot` directly as `squad-agent`: that bypasses Hangar's anonymous-pipe token
delivery, process guard, secret-child policy, and cleanup checks. Use the shipped runtime preflight
for an auth/model probe, or create a disposable labelled issue to exercise the complete path.

### Critic session debugging

Enable the critic with detailed logging by temporarily setting `LOOP_CRITIC_RUBRIC=repo-aware`
and watching the worker log for `[CRITIC]` lines.

---

## 12. Monitoring and alerting

Hangar does not ship a monitoring stack. Recommended approaches:

### Log forwarding

Use Docker's log drivers (`json-file`, `syslog`, `fluentd`) to forward container logs to your
existing log aggregation system:

```yaml
# In docker-compose.workers.yml (add to each service)
logging:
  driver: "json-file"
  options:
    max-size: "50m"
    max-file: "5"
```

### Health check

Each worker container exposes no HTTP health endpoint by default. A simple Docker health
check can be added to verify the polling loop is alive:

```yaml
healthcheck:
  test: ["CMD", "pgrep", "-f", "worker-loop.sh"]
  interval: 60s
  timeout: 5s
  retries: 3
```

### PR rate monitoring

Check the daily PR volume with:

```bash
gh pr list --repo your-org/your-repo \
  --search "is:pr created:>$(date -d '24 hours ago' '+%Y-%m-%dT%H:%M:%SZ') author:app/<your-app-slug>" \
  --json number,title | jq length
```

---

> Back to [README](../README.md) · [Install](INSTALL.md) · [Architecture](ARCHITECTURE.md)
