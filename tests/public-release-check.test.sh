#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/tests/public-release-check.sh"
TOKEN_PROBE="$ROOT/.hangar-public-token-probe"
DENYLIST_PROBE="$ROOT/.hangar-public-denylist-probe"
DENYLIST_FILE=$(mktemp)

cleanup() {
  rm -f "$TOKEN_PROBE" "$DENYLIST_PROBE" "$DENYLIST_FILE"
}
trap cleanup EXIT

# A first-commit extraction consists mostly of untracked files. Prove those are
# scanned by constructing a credential shape without storing one in this test.
printf 'github_pat_%s\n' "$(printf 'A%.0s' {1..24})" > "$TOKEN_PROBE"
if bash "$CHECKER" >/dev/null 2>&1; then
  echo "FAIL: public-release checker ignored an untracked credential probe" >&2
  exit 1
fi
rm -f "$TOKEN_PROBE"

# Exact organization/repository/history identifiers belong in an external,
# local-only denylist rather than in the public checker itself.
marker="private-release-probe-${RANDOM}-${RANDOM}"
printf '%s\n' "$marker" > "$DENYLIST_PROBE"
printf '%s\n' "$marker" > "$DENYLIST_FILE"
if HANGAR_PRIVATE_DENYLIST_FILE="$DENYLIST_FILE" bash "$CHECKER" >/dev/null 2>&1; then
  echo "FAIL: public-release checker ignored its external denylist" >&2
  exit 1
fi
rm -f "$DENYLIST_PROBE"
: > "$DENYLIST_FILE"

bash "$CHECKER" >/dev/null
echo "Public-release checker regression tests: PASS"
