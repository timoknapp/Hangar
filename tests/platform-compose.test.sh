#!/usr/bin/env bash
# shellcheck disable=SC2016
# Assertions below intentionally match literal variable expressions in source files.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY="$ROOT/deploy.sh"
INTERACTIVE_COMPOSE="$ROOT/docker-compose.yml"
ENV_EXAMPLE="$ROOT/.env.workers.example"
REMOTE_DEPLOY="$ROOT/remote-deploy.sh"
README="$ROOT/README.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  local message="$3"
  grep -Fq -- "$expected" "$file" || fail "$message"
}

assert_contains "$INTERACTIVE_COMPOSE" 'name: hangar-fleet' \
  "interactive service must belong to the hangar-fleet project"
assert_contains "$INTERACTIVE_COMPOSE" 'INTERACTIVE_ENABLE_TTYD' \
  "interactive service must use namespaced platform settings"
assert_contains "$INTERACTIVE_COMPOSE" 'INTERACTIVE_VOLUME_PREFIX' \
  "interactive volumes must have stable zero-copy names"
assert_contains "$INTERACTIVE_COMPOSE" 'init: true' \
  "interactive service must reap child processes and forward signals cleanly"

volume_name_count=$(grep -c 'name: "${INTERACTIVE_VOLUME_PREFIX:-hangar}_hangar-' "$INTERACTIVE_COMPOSE")
[[ "$volume_name_count" -eq 5 ]] \
  || fail "expected five stable interactive volume names, found $volume_name_count"

assert_contains "$DEPLOY" '-f "$INTERACTIVE_COMPOSE_FILE"' \
  "platform commands must load the interactive Compose service"
assert_contains "$DEPLOY" '-f "$COMPOSE_FILE"' \
  "platform commands must load generated worker services"
assert_contains "$DEPLOY" 'compose_platform up -d --build' \
  "platform up must start the unified Compose project"
assert_contains "$DEPLOY" 'compose_platform down' \
  "platform down must stop the unified Compose project"
assert_contains "$DEPLOY" 'compose_platform up -d --build hangar' \
  "interactive service must support a targeted restart"
assert_contains "$DEPLOY" '"${WORKER_SERVICES[@]}"' \
  "model changes must recreate workers without restarting interactive Hangar"

for key in \
  INTERACTIVE_REPO_URL \
  INTERACTIVE_REPO_BRANCH \
  INTERACTIVE_WORKSPACE_NAME \
  INTERACTIVE_BIND_ADDRESS \
  INTERACTIVE_TTYD_PORT \
  INTERACTIVE_SSH_PORT \
  INTERACTIVE_PREVIEW_PORT \
  INTERACTIVE_ENABLE_TTYD \
  INTERACTIVE_AUTO_UPDATE_CLI \
  INTERACTIVE_VOLUME_PREFIX; do
  assert_contains "$ENV_EXAMPLE" "${key}=" ".env.workers.example is missing ${key}"
done

[[ ! -e "$ROOT/.env.example" ]] \
  || fail "split-stack .env.example must not remain after configuration unification"
assert_contains "$REMOTE_DEPLOY" 'docker-compose.yml' \
  "remote sync must include the interactive Compose service"
assert_contains "$README" 'one `hangar-fleet` Compose project' \
  "README must describe a single Hangar Compose project"
if grep -Fq 'docker compose up -d' "$README"; then
  fail "README still advertises a separate interactive Compose lifecycle"
fi

echo "Unified Hangar Compose project: PASS (interactive + generated workers)"
