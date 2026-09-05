#!/usr/bin/env bash
# Run the production critic against a synthetic large diff that exceeds the
# Linux per-argument size threshold (~128 KiB). Generates everything inside an
# isolated one-shot container without any private repo, volume, or SHA dependency.
# Requires a clean-control approval and rejection of an authorization defect
# beyond the old truncation boundary. Model/auth calls occur only when invoked.
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
for i in $(seq 1 320); do
  mkdir -p "src/module-${i}"
  printf 'function handler%d() {\n  return "base-value-%d";\n}\nmodule.exports = { handler%d };\n' \
    "$i" "$i" "$i" > "src/module-${i}/index.js"
done
printf '{"name":"synthetic-app","version":"1.0.0"}\n' > package.json
mkdir -p z-security
printf 'function authorize(isAdmin) { return isAdmin === true; }\nmodule.exports = { authorize };\n' > z-security/access.js
git add .
git commit -qm "base: 320 modules"
git branch -M main

# Create feature branch with changes across all modules
git checkout -qb feature
for i in $(seq 1 320); do
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

# Run the actual production critic as publisher against the disposable shared repo.
chown -R squad-agent:squad "$fixture_repo"
find "$fixture_repo" -type d -exec chmod 2770 {} +
find "$fixture_repo" -type f -exec chmod 660 {} +
cat >/tmp/critic-fixture-run.sh <<'RUN'
set -euo pipefail
export WORKER_ID=critic-synthetic WORKSPACE_DIR=/tmp/critic-synthetic-diff
export GITHUB_OWNER=example-org GITHUB_REPO=synthetic-app REPO_BRANCH=main
export LOOP_AUTONOMOUS=false LOOP_CRITIC=true LOOP_CRITIC_RUBRIC=repo-aware
export LOOP_VERIFY=off LOOP_IMPLEMENTER=plain LOOP_MAX_REVIEW_BYTES=262144
source /home/copilot/worker-loop.sh
cd "$WORKSPACE_DIR"
command git config --global --add safe.directory "$WORKSPACE_DIR"
CURRENT_ISSUE=1
CURRENT_ISSUE_CONTEXT='Refactor synthetic module handlers without changing admin authorization. The authorization function must deny non-admins.'
TASK_BASE_SHA=$(git rev-parse main)
TASK_START_HEAD="$TASK_BASE_SHA"
TASK_BRANCH=feature
FINAL_PR_BODY='## Problem
Synthetic module refactor.
## Root Cause
Existing fixture duplication.
## Solution
Refactor handlers, do not alter access control.
## Testing
Runtime critic fixture, no product test claim. UI: N/A — no UI.
## Future Work
None.'
run_critic
# Deliberate defect sorts after >1500 lines; critic must reject it, not approve a prefix.
printf 'function authorize(isAdmin) { return true; }\nmodule.exports = { authorize };\n' >z-security/access.js
git -c user.name=Fixture -c user.email=fixture@example.invalid add z-security/access.js
git -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'fixture: incorrect admin authorization'
rc=0
run_critic || rc=$?
test "$rc" = 1
test "$CRITIC_FAILURE_KIND" = review
printf '%s\n' "$CRITIC_FEEDBACK" | grep -Eqi 'authoriz|admin|access'
echo 'Synthetic full-diff critic: clean control approved; late authorization defect rejected'
RUN
chmod 755 /tmp/critic-fixture-run.sh
sudo -n -E -u copilot /usr/bin/bash /tmp/critic-fixture-run.sh
INNER
