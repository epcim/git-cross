#!/usr/bin/env bash
set -euo pipefail

artifact_hash_collect() {
    local output="$1"
    shift
    mkdir -p "$(dirname "${output}")"
    : >"${output}"
    local path
    for path in "$@"; do
        shasum -a 256 "${path}"
    done | sort >"${output}"
}

artifact_hash_compare() {
    local baseline="$1"
    local candidate="$2"

    if [[ ! -f "${baseline}" ]]; then
        echo "Baseline hash file ${baseline} missing" >&2
        return 1
    fi
    if [[ ! -f "${candidate}" ]]; then
        echo "Candidate hash file ${candidate} missing" >&2
        return 1
    fi

    if cmp -s "${baseline}" "${candidate}"; then
        return 0
    fi

    echo "Artifact hashes differ between ${baseline} and ${candidate}" >&2
    diff -u "${baseline}" "${candidate}" >&2 || true
    return 1
}
