#!/bin/bash
# =============================================================================
# auth-setup.sh — One-time interactive auth for GitHub + Copilot CLI
# Run inside the container: docker exec -it hangar su - copilot -c 'bash ~/auth-setup.sh'
# Or from within the ttyd web terminal (exit tmux first with Ctrl+b d)
# =============================================================================
set -euo pipefail

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace/repo}"
REPO_URL="${REPO_URL:-}"
REPO_BRANCH="${REPO_BRANCH:-main}"

echo "================================================"
echo "  Hangar Interactive Session — Authentication Setup"
echo "================================================"
echo ""

# --- Step 1: GitHub CLI auth ---
echo "--- Step 1/4: GitHub CLI Authentication ---"
if gh auth status &>/dev/null; then
  echo "Already authenticated with GitHub CLI."
  gh auth status
else
  echo "Opening device flow authentication..."
  echo "You'll get a code — enter it at https://github.com/login/device"
  echo ""
  gh auth login --web --git-protocol ssh
fi
echo ""

# --- Step 2: SSH key for git ---
echo "--- Step 2/4: SSH Key Setup ---"
mkdir -p "$HOME/.ssh"
if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
  echo "SSH key already exists."
else
  echo "Generating SSH key..."
  ssh-keygen -t ed25519 -C "hangar" -f "$HOME/.ssh/id_ed25519" -N ""
  echo ""
  echo "Add this public key to your GitHub account:"
  echo "  https://github.com/settings/ssh/new"
  echo ""
  cat "$HOME/.ssh/id_ed25519.pub"
  echo ""
  read -rp "Press Enter after adding the key to GitHub..."
fi

# Add GitHub to known hosts
ssh-keyscan -t ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
echo ""

# --- Step 3: Clone repo ---
echo "--- Step 3/4: Repository Setup ---"
if [[ -d "$WORKSPACE_DIR/.git" ]]; then
  echo "Repository already cloned at $WORKSPACE_DIR"
  cd "$WORKSPACE_DIR"
  git fetch origin
  git checkout "$REPO_BRANCH"
  git pull
else
  if [[ -n "$REPO_URL" ]]; then
    echo "Cloning $REPO_URL..."
    git clone -b "$REPO_BRANCH" "$REPO_URL" "$WORKSPACE_DIR"
  else
    echo "REPO_URL not set — skipping clone. Set it in .env and restart."
  fi
fi
echo ""

# --- Step 4: Verify Copilot CLI ---
echo "--- Step 4/4: Copilot CLI Verification ---"
if command -v copilot &>/dev/null; then
  echo "Copilot CLI is available."
  copilot --version 2>/dev/null || echo "(version check not supported)"
else
  echo "ERROR: copilot-cli not found."
  exit 1
fi
echo ""

# --- Done ---
echo "================================================"
echo "  Setup complete!"
echo "================================================"
echo ""
echo "Type 'copilot' to start a session."
echo "Use '/resume' to reconnect to a previous session."
echo ""
