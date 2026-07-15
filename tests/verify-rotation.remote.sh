#!/usr/bin/env bash
# Verify PAT rotation on the Docker host. Requires explicit env/container args.
set -euo pipefail

: "${ENV_FILE:?ENV_FILE is required (path to .env.workers)}"
: "${WORKER_CONTAINER:?WORKER_CONTAINER is required (e.g. squad-worker-1)}"

new_pat=$(sed -n 's/^COPILOT_PAT=//p' "$ENV_FILE" | head -1)
old_pat=$(docker exec "$WORKER_CONTAINER" printenv COPILOT_PAT)

test -n "$new_pat"
test -n "$old_pat"
test "$new_pat" != "$old_pat"

echo "PAT rotation confirmed"
