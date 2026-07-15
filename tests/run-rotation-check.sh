#!/usr/bin/env bash
# SSH to Docker host and run the rotation verification script.
set -euo pipefail

: "${REMOTE_HOST:?REMOTE_HOST is required (e.g. worker-host.example.net)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scp "$SCRIPT_DIR/verify-rotation.remote.sh" "${REMOTE_HOST}:/tmp/verify-worker-rotation.sh" >/dev/null
ssh "$REMOTE_HOST" 'bash /tmp/verify-worker-rotation.sh; rc=$?; rm -f /tmp/verify-worker-rotation.sh; exit $rc'
