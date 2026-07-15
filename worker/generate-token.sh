#!/usr/bin/env bash
# =============================================================================
# generate-token.sh — GitHub App Installation Token Generator
# Generates a short-lived installation token from a GitHub App private key.
# Outputs ONLY the token to stdout; all diagnostics go to stderr.
# Can be sourced (provides generate_install_token function) or executed directly.
# =============================================================================

set -euo pipefail

# --- Base64url encode (RFC 7515) ---
_b64url() {
  openssl base64 -e -A | tr '+/' '-_' | tr -d '='
}

# --- Main token generation function ---
generate_install_token() {
  local app_id="${1:-${GH_APP_ID:-}}"
  local install_id="${2:-${GH_APP_INSTALL_ID:-}}"
  local pem_file="${3:-${GH_APP_PEM_FILE:-}}"

  if [[ -z "$app_id" ]]; then
    echo "ERROR: GH_APP_ID is not set" >&2
    return 1
  fi
  if [[ -z "$install_id" ]]; then
    echo "ERROR: GH_APP_INSTALL_ID is not set" >&2
    return 1
  fi
  if [[ -z "$pem_file" ]]; then
    echo "ERROR: GH_APP_PEM_FILE is not set" >&2
    return 1
  fi
  if [[ ! -f "$pem_file" ]]; then
    echo "ERROR: PEM file not found: $pem_file" >&2
    return 1
  fi

  # Build JWT (RS256)
  local now iat exp jwt_header jwt_payload jwt_unsigned jwt_signature jwt
  now=$(date +%s)
  iat=$((now - 60))
  exp=$((now + 600))

  jwt_header=$(printf '{"alg":"RS256","typ":"JWT"}' | _b64url)
  jwt_payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "${iat}" "${exp}" "${app_id}" | _b64url)
  jwt_unsigned="${jwt_header}.${jwt_payload}"
  jwt_signature=$(printf '%s' "${jwt_unsigned}" | openssl dgst -sha256 -sign "${pem_file}" | _b64url)
  jwt="${jwt_unsigned}.${jwt_signature}"

  echo "Requesting installation token for app=$app_id install=$install_id ..." >&2

  # Exchange JWT for installation token
  local response token
  response=$(curl -sf -X POST \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/app/installations/${install_id}/access_tokens" 2>&1) || {
    echo "ERROR: Failed to request installation token. Response:" >&2
    echo "$response" >&2
    return 1
  }

  token=$(echo "$response" | jq -r '.token // empty')
  if [[ -z "$token" ]]; then
    echo "ERROR: No token in API response:" >&2
    echo "$response" >&2
    return 1
  fi

  echo "Token generated successfully (expires in ~1 hour)" >&2
  # Output ONLY the token to stdout
  printf '%s' "$token"
}

# --- Run directly if executed (not sourced) ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  generate_install_token "$@"
fi
