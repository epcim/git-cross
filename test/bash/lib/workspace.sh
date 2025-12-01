#!/usr/bin/env bash
set -euo pipefail

create_workspace() {
    local root="${CROSS_TEST_TMPDIR:-$(mktemp -d)}"
    if [[ -n "${CROSS_TEST_TMPDIR:-}" ]]; then
        mkdir -p "${root}"
        root="$(mktemp -d "${root%/}/cross-e2e-XXXXXX")"
    fi
    printf '%s\n' "${root}"
}

cleanup_workspace() {
    local dir="$1"
    if [[ -d "${dir}" ]]; then
        rm -rf "${dir}"
    fi
}
