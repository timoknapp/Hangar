#!/usr/bin/env bash
# Verify a host env file contains a dedicated Copilot credential distinct from
# the publisher token currently loaded by a running worker. Prints booleans only.
set -euo pipefail

: "${ENV_FILE:?ENV_FILE is required}"
: "${WORKER_CONTAINER:?WORKER_CONTAINER is required}"

new_pat=$(sed -n 's/^COPILOT_PAT=//p' "$ENV_FILE" | head -1)
old_pat=$(docker exec "$WORKER_CONTAINER" printenv COPILOT_PAT)

test -n "$new_pat"
test -n "$old_pat"
test "$new_pat" != "$old_pat"

echo "Copilot credential rotation: PASS"
