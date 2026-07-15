#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="$ROOT/README.md"
MIGRATION_GUIDE="$ROOT/docs/MIGRATING-FROM-COPILOT-WORKSTATION.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -Fq 'git clone https://github.com/timoknapp/Hangar.git' "$README" \
  || fail "README must clone the canonical public Hangar repository"
if grep -Eq 'github\.com/(<your-org>|your-org)/[Hh]angar\.git' "$README"; then
  fail "README still contains a generic Hangar source-repository URL"
fi

[[ ! -e "$MIGRATION_GUIDE" ]] \
  || fail "private copilot-workstation migration guide must not ship publicly"
if grep -Fq 'MIGRATING-FROM-COPILOT-WORKSTATION' "$README"; then
  fail "README still links to the removed private migration guide"
fi

for scenario in \
  'Master cycle' \
  'Scenario A — Happy path' \
  'Scenario B — Empty board' \
  'Scenario C — Verification fails' \
  'Scenario D — Critic requests changes' \
  'Scenario E — Verification unavailable' \
  'Scenario F — Daily budget exhausted' \
  'Scenario G — Human requests a revision' \
  'Scenario H — Critic unavailable'; do
  grep -Fq "$scenario" "$README" || fail "missing README diagram: $scenario"
done

mermaid_count=$(awk '
  {
    line = $0
    sub(/^[[:space:]]+/, "", line)
    if (line == "```mermaid") count++
  }
  END { print count + 0 }
' "$README")
[[ "$mermaid_count" -eq 11 ]] \
  || fail "expected 11 Mermaid diagrams, found $mermaid_count"

# Mermaid sequence keywords are case-insensitive. A participant named `Loop`
# collides with the `loop` block keyword and caused GitHub's parser to reject the
# original flight-pipeline diagram.
if grep -Eqi '^[[:space:]]*participant[[:space:]]+(loop|alt|opt|par|critical|break|rect|end)([[:space:]]|$)' "$README"; then
  fail "README uses a reserved Mermaid keyword as a participant identifier"
fi

awk '
  {
    line = $0
    sub(/^[[:space:]]+/, "", line)
  }
  line == "```mermaid" {
    if (in_mermaid) exit 2
    in_mermaid = 1
    next
  }
  in_mermaid && line == "```" {
    in_mermaid = 0
    closed++
  }
  END {
    if (in_mermaid || closed != 11) exit 3
  }
' "$README" || fail "README has an unbalanced Mermaid code fence"

echo "README content and diagram inventory: PASS (${mermaid_count} Mermaid diagrams)"
