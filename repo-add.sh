#!/bin/bash
# =============================================================================
# repo-add.sh — Clone a new repo into /workspace/ at runtime
# Usage: repo-add <git-url> [branch]
# Example: repo-add git@github.com:org/my-app.git master
# =============================================================================
set -e

if [[ -z "${1:-}" ]]; then
  echo "Usage: repo-add <git-url> [branch]"
  echo ""
  echo "Examples:"
  echo "  repo-add git@github.com:user/my-app.git"
  echo "  repo-add git@github.com:user/my-app.git develop"
  echo ""
  echo "Currently cloned repos:"
  for d in /workspace/*/; do
    [[ -d "$d/.git" ]] && echo "  - $(basename "$d") ($(git -C "$d" remote get-url origin 2>/dev/null || echo 'unknown'))"
  done
  exit 1
fi

REPO_URL="$1"
BRANCH="${2:-}"
REPO_NAME=$(basename "$REPO_URL" .git)
REPO_DIR="/workspace/$REPO_NAME"

if [[ -d "$REPO_DIR/.git" ]]; then
  echo "✓ Repo already exists: $REPO_DIR"
  echo "  Remote: $(git -C "$REPO_DIR" remote get-url origin)"
  echo "  Branch: $(git -C "$REPO_DIR" branch --show-current)"
  exit 0
fi

echo ">>> Cloning $REPO_URL${BRANCH:+ (branch: $BRANCH)} into $REPO_DIR..."
mkdir -p "$REPO_DIR"
if [[ -n "$BRANCH" ]]; then
  git clone -b "$BRANCH" "$REPO_URL" "$REPO_DIR"
else
  git clone "$REPO_URL" "$REPO_DIR"
fi
echo "✓ Done. Switch with: cd /workspace/$REPO_NAME"
