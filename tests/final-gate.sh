#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# --- JSON syntax ---
jq_targets=()
# shellcheck disable=SC2043
for f in tests/fixtures/squad-mcp-config.json; do
  [[ -f "$f" ]] && jq_targets+=("$f")
done
[[ -f repos.example.json ]] && jq_targets+=(repos.example.json)
if [[ ${#jq_targets[@]} -gt 0 ]]; then
  jq -e . "${jq_targets[@]}" >/dev/null
fi

# --- JS/Python fixture syntax ---
[[ -f tests/fixtures/squad-capability-mcp.mjs ]] && \
  node --check tests/fixtures/squad-capability-mcp.mjs
[[ -f tests/fixtures/process-secret-scan.py ]] && \
  python3 -c 'from pathlib import Path; p=Path("tests/fixtures/process-secret-scan.py"); compile(p.read_text(), str(p), "exec")'

# --- C syntax (Linux only) ---
if [[ "$(uname -s)" == "Linux" ]]; then
  c_files=()
  [[ -f worker/credential-guard.c ]] && c_files+=(worker/credential-guard.c)
  [[ -f worker/credential-guard-preload.c ]] && c_files+=(worker/credential-guard-preload.c)
  if [[ ${#c_files[@]} -gt 0 ]]; then
    cc -fsyntax-only -Wall -Wextra -Werror "${c_files[@]}"
  fi
fi

# --- Collect shell scripts ---
shell_scripts=()
for f in \
  worker/worker-loop.sh \
  worker/entrypoint.sh \
  worker/git-credential-helper.sh \
  worker/runtime-preflight.sh \
  deploy.sh \
  remote-deploy.sh \
  tests/worker-loop.test.sh \
  tests/config-equivalence.sh \
  tests/check-failed-run-access.remote.sh \
  tests/check-live-agent-secret-isolation.remote.sh \
  tests/check-copilot-token-boundary.remote.sh \
  tests/credential-separation.sh \
  tests/critic-real-diff-preflight.remote.sh \
  tests/critic-runtime-preflight.remote.sh \
  tests/deploy-preflight.sh \
  tests/deploy-workers.remote.sh \
  tests/diagnose-worker-issue.remote.sh \
  tests/list-active-claims.remote.sh \
  tests/mcp-capability-smoke.remote.sh \
  tests/prepare-revision-retry.remote.sh \
  tests/pr-guard.test.sh \
  tests/readme-content.test.sh \
  tests/public-release-check.sh \
  tests/public-release-check.test.sh \
  tests/remediate-tokenized-remotes.remote.sh \
  tests/runtime-preflight.test.sh \
  tests/squad-capability-preflight.remote.sh \
  tests/validate-live-workers.remote.sh \
  tests/validate-squad-session.remote.sh \
  tests/run-rotation-check.sh \
  tests/verify-rotation.remote.sh \
  tests/final-gate.sh; do
  [[ -f "$f" ]] && shell_scripts+=("$f")
done

# --- bash -n ---
bash -n "${shell_scripts[@]}"

# --- ShellCheck ---
shellcheck "${shell_scripts[@]}"

# --- Local test execution ---
bash tests/readme-content.test.sh
bash tests/public-release-check.test.sh
bash tests/public-release-check.sh
bash tests/config-equivalence.sh
bash tests/pr-guard.test.sh
bash tests/worker-loop.test.sh
