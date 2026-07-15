#!/usr/bin/env bash
# Safe, non-interpolating Copilot credential/model probe for the worker image.
set -euo pipefail

: "${COPILOT_PAT:?COPILOT_PAT is required}"
CRITIC_MODEL="${CRITIC_MODEL:-${COPILOT_MODEL:-}}"
PROBE_DIR="/workspace/runtime-preflight"

mkdir -p "$PROBE_DIR"
chown squad-agent:squad "$PROBE_DIR"
chmod 2770 "$PROBE_DIR"

copilot_args=(
  -C "$PROBE_DIR"
  -p "Respond with exactly RUNTIME_PREFLIGHT_OK. Do not use tools."
  --silent
  --stream off
  --allow-all-tools
  --disable-builtin-mcps
  --no-ask-user
  --no-remote
  --no-remote-export
  --no-color
  "--secret-env-vars=COPILOT_GITHUB_TOKEN,GITHUB_TOKEN,GH_TOKEN,COPILOT_PAT"
  --deny-tool=shell
  --deny-tool=write
  --deny-tool=url
)
[[ -n "$CRITIC_MODEL" ]] && copilot_args+=(--model "$CRITIC_MODEL")

output=$(printf '%s' "$COPILOT_PAT" | sudo -n -u squad-agent /usr/bin/env -i \
  HOME=/home/squad-agent \
  USER=squad-agent \
  LOGNAME=squad-agent \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  LANG=C.UTF-8 \
  LC_ALL=C.UTF-8 \
  CI=true \
  NO_COLOR=1 \
  /usr/local/bin/credential-guard copilot "${copilot_args[@]}")

test "$output" = "RUNTIME_PREFLIGHT_OK"
echo "Copilot runtime preflight: PASS (${CRITIC_MODEL:-default model})"
