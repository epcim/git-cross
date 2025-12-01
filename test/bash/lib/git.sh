#!/usr/bin/env bash
set -euo pipefail

GIT_LOG_FILE="${GIT_LOG_FILE:-test/results/git.log}"

git_logged() {
    mkdir -p "$(dirname "${GIT_LOG_FILE}")"
    local timestamp
    timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '%s git %s\n' "${timestamp}" "$*" >>"${GIT_LOG_FILE}"
    git "$@"
}
