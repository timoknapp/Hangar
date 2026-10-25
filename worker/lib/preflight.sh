# shellcheck shell=bash
# Worker health before every claim: an unhealthy worker claims nothing, so
# infrastructure faults never land on an issue. Checks are publisher-side and
# cheap; the model probe is cached (LOOP_MODEL_PROBE_TTL) so repeated claim
# races cost no extra model calls.

LOOP_MIN_FREE_MB="${LOOP_MIN_FREE_MB:-2048}"
LOOP_MODEL_PROBE_TTL="${LOOP_MODEL_PROBE_TTL:-3600}"
PREFLIGHT_MODELS_OK_UNTIL=0
PREFLIGHT_REASON=""
PREFLIGHT_LAST_LOGGED=""

HANGAR_CLI_PIN_FILE="${HANGAR_CLI_PIN_FILE:-/etc/hangar-copilot-cli-version}"

# Images without a pin file (older builds) skip this check rather than guess.
preflight_cli_version() {
  [[ "${AUTO_UPDATE_CLI:-false}" != true && -r "$HANGAR_CLI_PIN_FILE" ]] || return 0
  local actual pinned
  pinned=$(head -1 "$HANGAR_CLI_PIN_FILE" | tr -d '[:space:]')
  actual=$(copilot --version 2>/dev/null | sed -nE 's/^GitHub Copilot CLI ([0-9]+(\.[0-9]+)*)\.?$/\1/p' | head -1)
  [[ -n "$pinned" && "$actual" == "$pinned" ]] && return 0
  PREFLIGHT_REASON="Copilot CLI ${actual:-unreadable} differs from pinned ${pinned:-unreadable}"
  return 1
}

preflight_models() {
  (( $(date +%s) < PREFLIGHT_MODELS_OK_UNTIL )) && return 0
  local model out rc saved_deadline="$TASK_DEADLINE"
  local -a models=("${COPILOT_MODEL:-}")
  [[ "${LOOP_CRITIC:-false}" != true || "${LOOP_CRITIC_MODEL:-}" == "${COPILOT_MODEL:-}" || -z "${LOOP_CRITIC_MODEL:-}" ]] ||
    models+=("$LOOP_CRITIC_MODEL")
  for model in "${models[@]}"; do
    local -a args=(-C "$WORKSPACE_DIR" -p "Respond with exactly HANGAR_PREFLIGHT_OK. Do not use tools."
      --silent --stream off "${COPILOT_COMMON_ARGS[@]}" "${COPILOT_READ_ONLY_ARGS[@]}")
    [[ -n "$model" ]] && args+=(--model "$model")
    TASK_DEADLINE=$(( $(date +%s) + 120 )) rc=0
    out=$(run_agent_copilot "${COPILOT_PAT:-}" "${args[@]}" 2>/dev/null) || rc=$?
    TASK_DEADLINE="$saved_deadline"
    if (( rc != 0 )) || [[ "$(tr -d '[:space:]' <<<"$out")" != HANGAR_PREFLIGHT_OK ]]; then
      PREFLIGHT_REASON="model ${model:-<default>} not usable (exit ${rc})"
      return 1
    fi
  done
  PREFLIGHT_MODELS_OK_UNTIL=$(( $(date +%s) + LOOP_MODEL_PROBE_TTL ))
}

# Playwright browsers must match the repository's lockfile, not the image build:
# a dependency bump otherwise breaks every UI test with "Executable doesn't
# exist". Versions come from tracked lockfiles at the fetched base (strictly
# validated); each missing one is installed once as the coding user (no
# credentials, same trust as `npm ci` in verification) and then remembered.
preflight_browsers() {
  local base="$1" path version marker
  local -a versions=()
  while IFS= read -r path; do
    version=$(git show "${base}:${path}" 2>/dev/null | jq -r '.packages["node_modules/playwright-core"].version // empty' 2>/dev/null) || continue
    [[ "$version" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && versions+=("$version")
  done < <(git ls-tree -r --name-only "$base" 2>/dev/null | grep -E '(^|/)package-lock\.json$' | grep -v node_modules | head -20)
  (( ${#versions[@]} )) || return 0
  local saved_deadline="$TASK_DEADLINE"
  for version in $(printf '%s\n' "${versions[@]}" | sort -u); do
    marker="${AGENT_HOME}/.cache/ms-playwright/.hangar-playwright-${version}"
    sudo -n -u "$AGENT_USER" /usr/bin/env -i HOME="$AGENT_HOME" PATH="$AGENT_PATH" /usr/bin/test -f "$marker" && continue
    log "Installing Playwright ${version} browsers for the repository lockfile"
    TASK_DEADLINE=$(( $(date +%s) + 900 ))
    if ! run_agent_command "npm exec --yes --package=playwright-core@${version} -- playwright-core install chromium && touch '${marker}'" >/dev/null 2>&1; then
      TASK_DEADLINE="$saved_deadline"
      PREFLIGHT_REASON="Playwright ${version} browsers could not be installed"
      return 1
    fi
    TASK_DEADLINE="$saved_deadline"
  done
}

preflight_workspace() {
  local free
  free=$(df -Pm "$WORKSPACE_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
  [[ "$free" =~ ^[0-9]+$ ]] || { PREFLIGHT_REASON="free disk space unreadable"; return 1; }
  (( free >= LOOP_MIN_FREE_MB )) || { PREFLIGHT_REASON="only ${free} MB free (< ${LOOP_MIN_FREE_MB} MB)"; return 1; }
  cd "$WORKSPACE_DIR" 2>/dev/null || { PREFLIGHT_REASON="workspace unavailable"; return 1; }
  sanitize_repository_git_config || { PREFLIGHT_REASON="repository Git metadata rejected"; return 1; }
  workspace_clean || { PREFLIGHT_REASON="workspace is dirty or its evidence is rejected"; return 1; }
  repair_shared_workspace_modes || { PREFLIGHT_REASON="shared workspace permissions cannot be repaired"; return 1; }
  local base
  base=$(fetch_task_base) || { PREFLIGHT_REASON="cannot fetch ${DEFAULT_BRANCH} into the workspace"; return 1; }
  preflight_browsers "$base"
}

# Returns 1 when the worker must not claim; logs once per distinct reason.
worker_preflight() {
  PREFLIGHT_REASON=""
  if preflight_workspace && preflight_cli_version && preflight_models; then
    [[ -z "$PREFLIGHT_LAST_LOGGED" ]] || log "Worker preflight healthy again; admission resumed"
    PREFLIGHT_LAST_LOGGED=""
    return 0
  fi
  if [[ "$PREFLIGHT_REASON" != "$PREFLIGHT_LAST_LOGGED" ]]; then
    log_error "Worker unhealthy, claiming nothing: ${PREFLIGHT_REASON}"
    PREFLIGHT_LAST_LOGGED="$PREFLIGHT_REASON"
  fi
  return 1
}
