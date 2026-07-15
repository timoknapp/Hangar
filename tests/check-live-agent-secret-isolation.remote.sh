#!/usr/bin/env bash
# Scan active coding-user processes from a clean same-user process. Prints only
# variable names/PIDs on failure, never credential values.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${WORKER_CONTAINER:?WORKER_CONTAINER is required}"
container="$WORKER_CONTAINER"
scanner="/tmp/process-secret-scan.py"

active=$(docker exec -u squad-agent "$container" /usr/bin/env -i \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  pgrep -u squad-agent -f copilot || true)
[[ -n "$active" ]] || {
  echo "ERROR: no active Copilot process found for isolation proof" >&2
  exit 1
}

docker cp "$script_dir/fixtures/process-secret-scan.py" "$container:$scanner"
docker exec "$container" chown squad-agent:squad "$scanner"
docker exec -u squad-agent "$container" /usr/bin/env -i \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  python3 "$scanner"
docker exec "$container" rm -f "$scanner"
