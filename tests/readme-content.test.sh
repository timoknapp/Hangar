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

# Offline subset: inline Markdown links into docs/ and ATX headings outside
# fenced code blocks. Slugs retain Unicode letters/numbers, spaces, _ and -;
# inline backticks and punctuation are removed, and duplicate slugs get -N.
# This is deliberately not a complete GitHub Markdown parser (no HTML anchors,
# reference links, Setext headings or escaped/nested link destinations).
python3 - "$ROOT" <<'PYTHON'
from pathlib import Path
import re
import sys
import tempfile
import unicodedata
from urllib.parse import unquote, urlsplit


def prose_lines(text):
    fence = None
    for line in text.splitlines():
        match = re.match(r"^\s*(`{3,}|~{3,})(.*)$", line)
        if match:
            run, tail = match.groups()
            if fence is None:
                fence = run
            elif run[0] == fence[0] and len(run) >= len(fence) and not tail.strip():
                fence = None
            continue
        if fence is None:
            yield line


def heading_anchors(text):
    anchors = set()
    for line in prose_lines(text):
        match = re.match(r"^ {0,3}#{1,6}\s+(.+?)\s*$", line)
        if not match:
            continue
        heading = re.sub(r"\s+#+\s*$", "", match[1]).lower()
        slug = "".join(
            char for char in heading
            if char in " _-" or unicodedata.category(char)[0] in "LNM"
        ).replace(" ", "-")
        anchor, suffix = slug, 0
        while anchor in anchors:
            suffix += 1
            anchor = f"{slug}-{suffix}"
        anchors.add(anchor)
    return anchors


def check_links(root, text):
    errors = []
    for line in prose_lines(text):
        for destination in re.findall(r"\[[^\]\n]*\]\(([^\s)]+)\)", line):
            url = urlsplit(destination)
            # Never fetch external URLs, even ones containing docs/.
            if url.scheme or url.netloc:
                continue
            path = unquote(url.path)
            if not path.startswith(("docs/", "./docs/")):
                continue
            target = root / path
            if not target.is_file():
                errors.append(f"missing documentation file: {destination}")
            elif url.fragment and unquote(url.fragment) not in heading_anchors(
                target.read_text(encoding="utf-8")
            ):
                errors.append(f"missing documentation anchor: {destination}")
    return errors


# Synthetic fixtures prove failures without editing tracked documentation.
with tempfile.TemporaryDirectory() as directory:
    fixture = Path(directory)
    (fixture / "docs").mkdir()
    (fixture / "docs/example.md").write_text(
        "## Decision stops (`squad:needs-decision`)\n"
        "## Triage (`loop.triage`, opt-in)\n"
        "## Repeated!\n## Repeated!\n"
        "```sh\n# Not a heading\n```\n", encoding="utf-8"
    )
    good = (
        "[decision](docs/example.md#decision-stops-squadneeds-decision)\n"
        "[triage](./docs/example.md#triage-looptriage-opt-in)\n"
        "[duplicate](docs/example.md#repeated-1)\n"
        "[file](docs/example.md)\n"
        "[external](https://example.invalid/docs/missing.md#missing)\n"
        "[protocol-relative](//example.invalid/docs/missing.md)\n"
        "```md\n[example](docs/missing.md)\n```\n"
    )
    if check_links(fixture, good):
        raise SystemExit("FAIL: valid documentation-link fixtures were rejected")
    for destination, expected in (
        ("docs/missing.md", "file"),
        ("docs/example.md#missing-anchor", "anchor"),
        ("docs/example.md#not-a-heading", "anchor"),
    ):
        errors = check_links(fixture, f"[regression]({destination})")
        if len(errors) != 1 or f"missing documentation {expected}:" not in errors[0]:
            raise SystemExit(f"FAIL: regression fixture was not detected: {destination}")

root = Path(sys.argv[1])
errors = check_links(root, (root / "README.md").read_text(encoding="utf-8"))
if errors:
    raise SystemExit("\n".join(f"FAIL: {error}" for error in errors))
print("README local documentation links and regression fixtures: PASS")
PYTHON
