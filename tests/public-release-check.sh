#!/usr/bin/env bash
# Audit the exact local publish set: tracked files plus untracked, nonignored
# files. This is intentionally safe before a first extraction commit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAIL=0
SCANNED=0
DENYLIST_FILE="${HANGAR_PRIVATE_DENYLIST_FILE:-}"

fail() {
  echo "FAIL: $*" >&2
  FAIL=1
}

if [[ -n "$DENYLIST_FILE" && ! -f "$DENYLIST_FILE" ]]; then
  echo "ERROR: HANGAR_PRIVATE_DENYLIST_FILE is not a readable file" >&2
  exit 2
fi

scan_external_denylist() {
  local file="$1" entry
  [[ -n "$DENYLIST_FILE" ]] || return 0
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    entry=${entry%$'\r'}
    [[ -n "$entry" && "$entry" != \#* ]] || continue
    if LC_ALL=C grep -Fqi -- "$entry" "$file"; then
      fail "$file contains an entry from the external private denylist"
      return
    fi
  done < "$DENYLIST_FILE"
}

scan_text_file() {
  local file="$1"

  if LC_ALL=C grep -Eq 'github_pat_[A-Za-z0-9_]{20,}' "$file"; then
    fail "$file contains a GitHub fine-grained PAT pattern"
  fi
  if LC_ALL=C grep -Eq '(gh[pousr]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16})' "$file"; then
    fail "$file contains a credential-like token pattern"
  fi
  if LC_ALL=C grep -Eq -- '-----BEGIN ([A-Z0-9]+ )?PRIVATE KEY-----' "$file"; then
    fail "$file contains a private key block"
  fi
  if LC_ALL=C grep -Eq 'https://[^/@[:space:]]+:[^/@[:space:]]+@github\.com' "$file"; then
    fail "$file contains a credential-bearing GitHub URL"
  fi
  if LC_ALL=C grep -Eq '/Users/[[:alnum:]_.-]+/' "$file"; then
    fail "$file contains an absolute macOS user path"
  fi

  scan_external_denylist "$file"
}

while IFS= read -r -d '' file; do
  [[ -e "$file" || -L "$file" ]] || continue
  SCANNED=$((SCANNED + 1))

  case "$file" in
    .env|.env.workers|.env.remote|repos.json|docker-compose.workers.yml)
      fail "private deployment artifact is in the publish set: $file"
      continue
      ;;
    *.pem|*.key|*.p12|*.pfx)
      fail "credential file is in the publish set: $file"
      continue
      ;;
  esac

  if [[ -L "$file" ]]; then
    link_target=$(readlink "$file")
    if [[ "$link_target" == /* || "/$link_target/" == *"/../"* ]]; then
      fail "$file is an absolute or parent-traversing symlink"
    fi
    continue
  fi
  [[ -f "$file" ]] || continue

  # Empty files need no content scan. MIME encoding `binary` avoids loading
  # images and other non-text assets into grep.
  [[ -s "$file" ]] || continue
  if [[ "$(file --brief --mime-encoding "$file")" == "binary" ]]; then
    continue
  fi
  scan_text_file "$file"
done < <(git ls-files --cached --others --exclude-standard -z)

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi

echo "Public-release content check: PASS (${SCANNED} publishable files scanned)"
