#!/usr/bin/env bash
# Real OS/profile permission proof in an owned, networkless disposable image.
# Run as root on Docker host: WORKER_IMAGE=<immutable-id> bash this-script
set -euo pipefail
: "${WORKER_IMAGE:?immutable worker image required}"
[[ "$(id -u)" == 0 ]] || { echo 'Run fixture setup as root' >&2; exit 1; }
TMP=$(mktemp -d)
container=''
cleanup() { [[ -z "$container" ]] || docker rm -f -v "$container" >/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
chmod 755 "$TMP"
printf 'Synthetic operator instructions\n' >"$TMP/implementer.md"
printf '#!/bin/bash\necho PROFILE_VERIFY_OK\n' >"$TMP/verify.sh"
chmod 444 "$TMP"/*
container=$(docker create --network none --label hangar.acceptance=profile-access --entrypoint sleep --mount "type=bind,source=$TMP,target=/etc/hangar/instance-profile,readonly" "$WORKER_IMAGE" infinity)
docker start "$container" >/dev/null
docker inspect "$container" | jq -e '.[0] | .HostConfig.NetworkMode=="none" and .HostConfig.Privileged==false and (.Mounts|length)==1 and .Mounts[0].Destination=="/etc/hangar/instance-profile" and .Mounts[0].RW==false' >/dev/null
docker exec -i "$container" bash -s <<'ROOT'
set -euo pipefail
mkdir -p /workspace/probe; chown squad-agent:squad /workspace/probe; chmod 2770 /workspace/probe
printf 'SYNTHETIC_PRIVATE\n' >/home/copilot/private-fixture
chown copilot:squad /home/copilot/private-fixture; chmod 600 /home/copilot/private-fixture
rc=0
bash -c 'echo forbidden >>/etc/hangar/instance-profile/verify.sh' 2>/dev/null || rc=$?
[[ "$rc" != 0 ]]
! grep -q forbidden /etc/hangar/instance-profile/verify.sh
cat >/home/copilot/profile-probe.sh <<'PUBLISHER'
set -euo pipefail
export GITHUB_OWNER=example GITHUB_REPO=fixture WORKSPACE_DIR=/workspace/probe LOOP_PROFILE_DIR=/etc/hangar/instance-profile
source /home/copilot/worker-loop.sh
cd "$WORKSPACE_DIR"
configure_profile_access
test "${COPILOT_PROFILE_ACCESS_ARGS[*]}" = '--add-dir /etc/hangar/instance-profile'
run_agent_command 'cat /etc/hangar/instance-profile/implementer.md && bash /etc/hangar/instance-profile/verify.sh'
PUBLISHER
chmod 644 /home/copilot/profile-probe.sh
su -s /bin/bash copilot -c 'bash /home/copilot/profile-probe.sh'
su -s /bin/bash squad-agent -c 'test ! -r /home/copilot/private-fixture; if printf forbidden >>/etc/hangar/instance-profile/implementer.md; then exit 1; fi' 2>/dev/null
! grep -q forbidden /etc/hangar/instance-profile/implementer.md
ROOT
echo 'PASS: actual coding-user profile read/execute; root and coding writes denied; publisher data unreadable'
