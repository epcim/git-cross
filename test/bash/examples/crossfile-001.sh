#!/usr/bin/env bash
set -euo pipefail

export workspace=${1:?"workspace path required"}
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../../.. && pwd)"
RESULT_DIR="${ROOT_DIR}/test/results/examples"
mkdir -p "${RESULT_DIR}"

echo "DEBUG: PATH=$PATH" >&2
source "${ROOT_DIR}/test/bash/lib/artifact_hash.sh"

repo_dir="${workspace}/crossfile-001"
rm -rf "${repo_dir}"
echo "Cloning ${ROOT_DIR} to ${repo_dir}..." >&2
git clone "${ROOT_DIR}" "${repo_dir}" >&2 || { echo "git clone failed" >&2; exit 1; }
cp "${ROOT_DIR}/cross" "${repo_dir}/cross" || { echo "cp cross failed" >&2; exit 1; }
chmod +x "${repo_dir}/cross"
cp "${ROOT_DIR}/Justfile" "${repo_dir}/Justfile" || { echo "cp Justfile failed" >&2; exit 1; }
if [[ -f "${ROOT_DIR}/Justfile.cross" ]]; then
    cp "${ROOT_DIR}/Justfile.cross" "${repo_dir}/Justfile.cross" || { echo "cp Justfile.cross failed" >&2; exit 1; }
fi
if [[ -f "${ROOT_DIR}/.env" ]]; then
    cp "${ROOT_DIR}/.env" "${repo_dir}/.env" || { echo "cp .env failed" >&2; exit 1; }
fi

pushd "${repo_dir}" >/dev/null
if [[ -z "${CROSS_ORIG_JUST:-}" ]]; then
    export CROSS_ORIG_JUST="$(command -v just)"
fi
export PATH="${ROOT_DIR}/test/bin:${PATH}"
export JUSTFILE="Justfile.cross"
rm -rf deploy
mkdir -p deploy

# export CROSS_NON_INTERACTIVE=1
# export VERBOSE=true
# source "${repo_dir}/cross"
# if ! type use >/dev/null 2>&1; then
#     echo "Function 'use' not available after sourcing cross" >&2
#     exit 1
# fi
: >"${RESULT_DIR}/crossfile-001-bash.log"
if ! ./cross setup >>"${RESULT_DIR}/crossfile-001-bash.log" 2>&1; then
    rc=$?
    if [[ ${rc} -ne 1 ]]; then
        cat "${RESULT_DIR}/crossfile-001-bash.log" >&2
        exit ${rc}
    fi
fi
FETCHED=('')
{
    ./cross use khue "file://${ROOT_DIR}/test/fixtures/remotes/khue.git"
} >>"${RESULT_DIR}/crossfile-001-bash.log" 2>&1

if ! ./cross patch khue:metal deploy/metal >>"${RESULT_DIR}/crossfile-001-bash.log" 2>&1; then
    rc=$?
    if [[ ${rc} -ne 1 ]]; then
        cat "${RESULT_DIR}/crossfile-001-bash.log" >&2
        exit ${rc}
    fi
fi

if [[ -d deploy/setup/flux ]]; then
    echo "Unexpected directory deploy/setup/flux present" >&2
    exit 1
fi

expected=(
    "deploy/metal/docs/index.md"
)
for path in "${expected[@]}"; do
    if [[ ! -f "${path}" ]]; then
        echo "Expected file ${path} missing" >&2
        exit 1
    fi
done

artifact_hash_collect "${RESULT_DIR}/crossfile-001-bash.sha256" "${expected[@]}"

popd >/dev/null

echo "artifact_hash_file=${RESULT_DIR}/crossfile-001-bash.sha256"
