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

preflight_workspace() {
  local free
  free=$(df -Pm "$WORKSPACE_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
  [[ "$free" =~ ^[0-9]+$ ]] || { PREFLIGHT_REASON="free disk space unreadable"; return 1; }
  (( free >= LOOP_MIN_FREE_MB )) || { PREFLIGHT_REASON="only ${free} MB free (< ${LOOP_MIN_FREE_MB} MB)"; return 1; }
  cd "$WORKSPACE_DIR" 2>/dev/null || { PREFLIGHT_REASON="workspace unavailable"; return 1; }
  sanitize_repository_git_config || { PREFLIGHT_REASON="repository Git metadata rejected"; return 1; }
  workspace_clean || { PREFLIGHT_REASON="workspace is dirty or its evidence is rejected"; return 1; }
  repair_shared_workspace_modes || { PREFLIGHT_REASON="shared workspace permissions cannot be repaired"; return 1; }
  fetch_task_base >/dev/null || { PREFLIGHT_REASON="cannot fetch ${DEFAULT_BRANCH} into the workspace"; return 1; }
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
