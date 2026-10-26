#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="$ROOT/README.md"
OPERATIONS="$ROOT/docs/OPERATIONS.md"
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
  'Scenario F — Autonomous budget exhausted' \
  'Scenario G — Human requests a revision' \
  'Scenario H — Critic unavailable'; do
  grep -Fq "$scenario" "$OPERATIONS" || fail "missing OPERATIONS diagram: $scenario"
done
grep -Fq 'docs/OPERATIONS.md#14-pipeline-scenarios' "$README" \
  || fail "README must link the pipeline scenarios"

# The factory positioning and the GitHub-facing controls stay discoverable.
for phrase in 'software factory' 'Governed autonomy' '## 🏭 How the factory works' \
  '### What you do on GitHub' '## Why Hangar?' 'squad:needs-decision' 'squad:split-approved' \
  'squad:spec' 'scope:large-approved' 'tools/factory-metrics.py' 'loop.learning'; do
  grep -Fq "$phrase" "$README" || fail "README must mention: $phrase"
done

# shellcheck disable=SC2016 # Backticks are intentional Markdown delimiters.
grep -Fq 'Human-created `squad` issues do not' "$README" \
  || fail "README must state that manual issues bypass maxPrsPerDay"
grep -Fq 'configured unattended attempts, including revisions' "$README" \
  || fail "README control table must describe configurable unattended budget"

check_mermaid() {
  local file="$1" expected="$2" count
  count=$(awk '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line == "```mermaid") count++
    }
    END { print count + 0 }
  ' "$file")
  [[ "$count" -eq "$expected" ]] \
    || fail "expected $expected Mermaid diagrams in $file, found $count"

  # Mermaid sequence keywords are case-insensitive. A participant named `Loop`
  # collides with the `loop` block keyword and caused GitHub's parser to reject the
  # original flight-pipeline diagram.
  if grep -Eqi '^[[:space:]]*participant[[:space:]]+(loop|alt|opt|par|critical|break|rect|end)([[:space:]]|$)' "$file"; then
    fail "$file uses a reserved Mermaid keyword as a participant identifier"
  fi

  awk -v expected="$expected" '
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
      if (in_mermaid || closed != expected) exit 3
    }
  ' "$file" || fail "$file has an unbalanced Mermaid code fence"
}

check_mermaid "$README" 2
check_mermaid "$OPERATIONS" 10

echo "README content and diagram inventory: PASS (2 README + 10 OPERATIONS Mermaid diagrams)"
