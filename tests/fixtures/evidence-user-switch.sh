#!/usr/bin/env bash
# Offline fixtures have no coding-user account. Replace ONLY the exact evidence
# helper user switch; execute its real inline program with the empty environment.
# This is NOT an OS privilege/isolation proof. Never source in production.
sudo() {
  [[ "$*" == "-n -u $AGENT_USER /usr/bin/env -i HOME=$AGENT_HOME PATH=$AGENT_PATH /usr/bin/timeout --kill-after=10 "* ]] || return 99
  shift 3
  "$@"
}
# Production uses publisher-owned identity; sanitizer intentionally drops local
# repo identity. Synthetic fixture commits stay possible after sanitization.
export GIT_AUTHOR_NAME=Fixture GIT_COMMITTER_NAME=Fixture
export GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_EMAIL=fixture@example.invalid
