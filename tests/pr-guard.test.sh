#!/usr/bin/env bash
# Static fail-closed publication assertions that complement behavioral helper tests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER="$ROOT/worker/worker-loop.sh"

revision=$(sed -n '/^process_revision()/,/^}/p' "$WORKER")
issue=$(sed -n '/^process_issue()/,/^}/p' "$WORKER")

lookup_line=$(printf '%s\n' "$revision" | grep -n 'lookup_pr_url_for_branch' | head -1 | cut -d: -f1)
draft_line=$(printf '%s\n' "$revision" | grep -n 'ensure_pr_is_draft' | head -1 | cut -d: -f1)
push_line=$(printf '%s\n' "$revision" | grep -n -- '--force-with-lease=refs/heads' | head -1 | cut -d: -f1)

test -n "$lookup_line"
test -n "$draft_line"
test -n "$push_line"
test "$lookup_line" -lt "$draft_line"
test "$draft_line" -lt "$push_line"

printf '%s\n' "$issue" | grep -q 'Could not determine existing PR state safely'
printf '%s\n' "$revision" | grep -q 'Could not re-read revision PR state safely'
if printf '%s\n' "$revision" | grep -q 'git push --force origin'; then
	echo "destructive revision force-push fallback found" >&2
	exit 1
fi

echo "PR fail-closed ordering: PASS"
