#!/usr/bin/env bash
# Run the production critic against a synthetic large diff that exceeds the
# Linux per-argument size threshold (~128 KiB). Generates everything inside an
# isolated one-shot container without any private repo, volume, or SHA dependency.
# A valid APPROVE or REQUEST_CHANGES verdict passes; anything else fails.
set -euo pipefail

image="${WORKER_IMAGE:?WORKER_IMAGE is required (e.g. squad-worker:latest)}"
env_file="${ENV_FILE:-.env.workers}"

[[ -f "$env_file" ]] || {
  echo "ERROR: worker env file not found: $env_file" >&2
  exit 1
}

docker run --rm -i \
  --env-file "$env_file" \
  --entrypoint /bin/bash \
  "$image" -s <<'INNER'
set -euo pipefail

echo "Synthetic large-diff critic preflight: starting"

# --- Generate synthetic repository ---
fixture_repo=/tmp/critic-synthetic-diff
rm -rf "$fixture_repo"
git init -q "$fixture_repo"
cd "$fixture_repo"
git config user.name "Critic Test"
git config user.email "critic-test@example.invalid"

# Create base with enough content to produce >128 KiB diff
for i in $(seq 1 200); do
  mkdir -p "src/module-${i}"
  printf 'function handler%d() {\n  return "base-value-%d";\n}\nmodule.exports = { handler%d };\n' \
    "$i" "$i" "$i" > "src/module-${i}/index.js"
done
printf '{"name":"synthetic-app","version":"1.0.0"}\n' > package.json
git add .
git commit -qm "base: 200 modules"
git branch -M main

# Create feature branch with changes across all modules
git checkout -qb feature
for i in $(seq 1 200); do
  printf 'function handler%d() {\n  // Refactored for clarity\n  const result = "updated-value-%d";\n  console.log("Processing module %d");\n  return result;\n}\n\nfunction helper%d() {\n  return handler%d();\n}\n\nmodule.exports = { handler%d, helper%d };\n' \
    "$i" "$i" "$i" "$i" "$i" "$i" "$i" > "src/module-${i}/index.js"
done
git commit -qam "refactor: update all modules"
git update-ref refs/remotes/origin/main "$(git rev-parse main)"

# Verify diff size exceeds threshold
diff_bytes=$(git diff --no-ext-diff main..HEAD | wc -c)
echo "Synthetic diff size: ${diff_bytes} bytes"
[[ "$diff_bytes" -gt 131072 ]] || {
  echo "ERROR: synthetic diff is only ${diff_bytes} bytes, need >128 KiB" >&2
  exit 1
}

# --- Load worker runtime and run the production critic ---
export WORKER_ID=critic-synthetic
export WORKSPACE_DIR="$fixture_repo"
export GITHUB_OWNER="example-org"
export GITHUB_REPO="synthetic-app"
export REPO_BRANCH=main
export LOOP_AUTONOMOUS=false
export LOOP_CRITIC=true
export LOOP_CRITIC_MODEL="${LOOP_CRITIC_MODEL:-}"
export LOOP_CRITIC_RUBRIC=repo-aware
export LOOP_VERIFY=off
export LOOP_IMPLEMENTER=plain
export COPILOT_MODEL="${COPILOT_MODEL:-}"
export COPILOT_EFFORT="${COPILOT_EFFORT:-}"
export COPILOT_CONTEXT="${COPILOT_CONTEXT:-}"

source /home/copilot/worker-loop.sh
CURRENT_ISSUE=1
CURRENT_ISSUE_CONTEXT="Synthetic large-diff critic runtime regression."

cd "$WORKSPACE_DIR"
[[ -d .git ]] || {
  echo "ERROR: fixture .git directory missing after loading worker runtime" >&2
  exit 1
}

runtime_lines=$(git diff --no-ext-diff "${DEFAULT_BRANCH}..HEAD" | wc -l)
echo "Runtime diff lines: $runtime_lines"
[[ "$runtime_lines" -gt 0 ]] || {
  echo "ERROR: runtime diff is empty" >&2
  exit 1
}

# Run the actual critic
branch_name="feature"
rc=0
run_critic || rc=$?

echo "Critic exit code: $rc"

case "$rc" in
  0)
    echo "Synthetic large-diff critic: APPROVE"
    ;;
  1)
    if [[ "${CRITIC_FAILURE_KIND:-}" == "review" ]]; then
      echo "Synthetic large-diff critic: REQUEST_CHANGES (valid)"
    else
      echo "ERROR: critic failed with infrastructure error: ${CRITIC_FAILURE_KIND:-unknown}" >&2
      exit 1
    fi
    ;;
  *)
    echo "ERROR: unexpected critic exit code: $rc" >&2
    exit 1
    ;;
esac

echo "Synthetic large-diff critic preflight: PASS"
INNER
