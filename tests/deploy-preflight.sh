#!/usr/bin/env bash
# Host-side credential-rotation preflight. Run from the Hangar checkout on the Docker host.
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env.workers}"
: "${OLD_WORKER:?OLD_WORKER is required (running container that still has the previous PAT)}"
: "${PREFLIGHT_IMAGE:?PREFLIGHT_IMAGE is required (candidate Hangar worker image)}"

new_pat=$(sed -n 's/^COPILOT_PAT=//p' "$ENV_FILE" | head -1)
old_pat=$(docker exec "$OLD_WORKER" printenv COPILOT_PAT)

test -n "$new_pat"
test -n "$old_pat"
test "$new_pat" != "$old_pat"

docker_args=(run --rm \
  --env-file "$ENV_FILE" \
  --entrypoint /home/copilot/runtime-preflight.sh \
)
[[ -n "${CRITIC_MODEL:-}" ]] && docker_args+=(-e "CRITIC_MODEL=${CRITIC_MODEL}")
docker_args+=("$PREFLIGHT_IMAGE")
docker "${docker_args[@]}"

echo "Deployment credential/model preflight: PASS"
