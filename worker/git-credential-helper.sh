#!/bin/sh
set -eu

TOKEN_FILE="/home/copilot/.github-app-token"

case "${1:-get}" in
  get)
    protocol=""
    host=""
    while IFS='=' read -r key value; do
      case "$key" in
        protocol) protocol="$value" ;;
        host) host="$value" ;;
      esac
    done

    # Never disclose the installation token to rewritten or unexpected remotes.
    [ "$protocol" = "https" ] || exit 0
    [ "$host" = "github.com" ] || exit 0
    [ -r "$TOKEN_FILE" ] || exit 1

    printf 'username=x-access-token\n'
    printf 'password=%s\n' "$(cat "$TOKEN_FILE")"
    ;;
  store|erase)
    # Installation tokens are short-lived and managed by worker-loop.sh.
    ;;
esac
