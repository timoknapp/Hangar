#!/usr/bin/env bash
# Real Linux/sudo boundary proof in a DISPOSABLE worker image.
# Usage: WORKER_IMAGE=hangar-worker:ci bash tests/agent-launch.container.sh
# Never use a live worker: no host credentials or volumes are mounted.
set -euo pipefail
: "${WORKER_IMAGE:?Build the candidate worker image and set WORKER_IMAGE}"
docker run --rm -i --network none --entrypoint /bin/bash "$WORKER_IMAGE" -euo pipefail <<'CONTAINER'
mkdir -p /workspace/probe
chown squad-agent:squad /workspace/probe
chmod 2770 /workspace/probe
printf 'synthetic publisher secret\n' >/home/copilot/publisher-fixture
chown copilot:squad /home/copilot/publisher-fixture
chmod 600 /home/copilot/publisher-fixture
cat >/workspace/probe/check-boundary.sh <<'PROBE'
#!/bin/bash
set -euo pipefail
test "$(id -un)" = squad-agent
test "$(id -u)" != 0
for field in CapInh CapPrm CapEff CapBnd CapAmb; do
  test "$(awk -v name="$field:" '$1==name {print $2}' /proc/self/status)" = 0000000000000000
done
test "$(awk '$1=="NoNewPrivs:" {print $2}' /proc/self/status)" = 1
test "$(id -G | wc -w)" = 1
test "$HOME" = /home/squad-agent
test "$COPILOT_TASK_WAIT_TIMEOUT_SECONDS" = 86400
if env | cut -d= -f1 | grep -Eq '^(GH_TOKEN|GITHUB_TOKEN|COPILOT_PAT|PUBLISHER_MARKER)$'; then exit 1; fi
! cat /home/copilot/publisher-fixture 2>/dev/null
! sudo -n /usr/local/bin/agent-launch command true 2>/dev/null
! sudo -n -u copilot /usr/bin/env 2>/dev/null
! setpriv --bounding-set=+all true 2>/dev/null
printf 'BOUNDARY_OK\n'
PROBE
chown root:squad /workspace/probe/check-boundary.sh
chmod 644 /workspace/probe/check-boundary.sh
cat >/home/copilot/probe.sh <<'PUBLISHER'
#!/bin/bash
set -euo pipefail
export GITHUB_OWNER=example GITHUB_REPO=repo REPO_BRANCH=main
export WORKSPACE_DIR=/workspace/probe PUBLISHER_MARKER=should-not-inherit
source /home/copilot/worker-loop.sh
cd "$WORKSPACE_DIR"
agent_startup_canary
run_agent_command 'bash /workspace/probe/check-boundary.sh'
rc=0
run_agent_command 'exit 9' || rc=$?
test "$rc" = 9
run_agent_command 'sleep 60 &'
test -z "$(ps -o stat= -u squad-agent | awk '$1 !~ /^Z/ {print}')"
PUBLISHER
chown copilot:squad /home/copilot/probe.sh
chmod 700 /home/copilot/probe.sh
su -s /bin/bash copilot -c 'bash /home/copilot/probe.sh'
CONTAINER
echo 'Protected command boundary: PASS (real container, no model/API call)'
