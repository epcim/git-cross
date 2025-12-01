#!/usr/bin/env bash
set -euo pipefail

workspace=${1:?"workspace path required"}
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd)"
RESULT_DIR="${ROOT_DIR}/test/results"
LIB_DIR="${ROOT_DIR}/test/bash/lib"
mkdir -p "${RESULT_DIR}"

source "${LIB_DIR}/log_assert.sh"

run_clean_patch() {
    local repo_dir="$1"
    local log_file="${RESULT_DIR}/patch-clean.log"

    rm -rf "${repo_dir}"
    git clone --local --no-hardlinks "${ROOT_DIR}" "${repo_dir}" >/dev/null
cp "${ROOT_DIR}/cross" "${repo_dir}/cross"
    pushd "${repo_dir}" >/dev/null
    rm -rf deploy
    mkdir -p deploy

    export CROSS_NON_INTERACTIVE=1
    export VERBOSE=true
    if ! ./cross patch bill:/setup/flux deploy/flux --branch master >"${log_file}" 2>&1; then
        cat "${log_file}" >&2
        exit 1
    fi

    if [[ ! -f deploy/flux/cluster/cluster.yaml ]]; then
        echo "Expected deploy/flux/cluster/cluster.yaml to exist" >&2
        exit 1
    fi

    if [[ -d deploy/setup/flux ]]; then
        echo "Unexpected directory deploy/setup/flux present" >&2
        exit 1
    fi

    log_assert_before "${log_file}" "Configuring sparse checkout" "git fetch" || exit 1

    popd >/dev/null
}

run_dirty_patch() {
    local repo_dir="$1"
    local log_file="${RESULT_DIR}/patch-dirty.log"

    pushd "${repo_dir}" >/dev/null
    echo "local-change" >> deploy/flux/local.txt

    export CROSS_NON_INTERACTIVE=1
    export VERBOSE=true
    if ./cross patch bill:/setup/flux deploy/flux --branch master >"${log_file}" 2>&1; then
        echo "Expected patch command to fail when worktree is dirty" >&2
        exit 1
    fi

    if [[ ! -f deploy/flux/local.txt ]]; then
        echo "Dirty worktree file unexpectedly modified" >&2
        exit 1
    fi

    if ! grep -q "ERROR" "${log_file}"; then
        echo "Expected error message in dirty log" >&2
        exit 1
    fi

    popd >/dev/null
}

repo_dir="${workspace}/patch-workflow"
run_clean_patch "${repo_dir}"
run_dirty_patch "${repo_dir}"
