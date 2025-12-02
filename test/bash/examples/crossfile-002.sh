#!/usr/bin/env bash
set -euo pipefail

workspace=${1:?"workspace path required"}
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../../.. && pwd)"
RESULT_DIR="${ROOT_DIR}/test/results/examples"
mkdir -p "${RESULT_DIR}"

source "${ROOT_DIR}/test/bash/lib/artifact_hash.sh"

repo_dir="${workspace}/crossfile-002"
rm -rf "${repo_dir}"
git clone "${ROOT_DIR}" "${repo_dir}" >/dev/null 2>&1
cp "${ROOT_DIR}/cross" "${repo_dir}/cross"
chmod +x "${repo_dir}/cross"
cp "${ROOT_DIR}/Justfile" "${repo_dir}/Justfile"
if [[ -f "${ROOT_DIR}/Justfile.cross" ]]; then
    cp "${ROOT_DIR}/Justfile.cross" "${repo_dir}/Justfile.cross"
fi
if [[ -f "${ROOT_DIR}/.env" ]]; then
    cp "${ROOT_DIR}/.env" "${repo_dir}/.env"
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
: >"${RESULT_DIR}/crossfile-002-bash.log"
if ! ./cross setup >>"${RESULT_DIR}/crossfile-002-bash.log" 2>&1; then
    rc=$?
    if [[ ${rc} -ne 1 ]]; then
        cat "${RESULT_DIR}/crossfile-002-bash.log" >&2
        exit ${rc}
    fi
fi
FETCHED=('')
{
    ./cross use khue "file://${ROOT_DIR}/test/fixtures/remotes/khue.git"
    ./cross use bill "file://${ROOT_DIR}/test/fixtures/remotes/bill.git"
} >>"${RESULT_DIR}/crossfile-002-bash.log" 2>&1

for spec in "khue:metal deploy/metal" "bill:setup/flux deploy/flux"; do
    if ! ./cross patch ${spec} >>"${RESULT_DIR}/crossfile-002-bash.log" 2>&1; then
        rc=$?
        if [[ ${rc} -ne 1 ]]; then
            cat "${RESULT_DIR}/crossfile-002-bash.log" >&2
            exit ${rc}
        fi
    fi
done


for spec in "khue:metal deploy/metal" "bill:setup/flux deploy/flux"; do
    if ! ./cross patch ${spec} >>"${RESULT_DIR}/crossfile-002-bash.log" 2>&1; then
        rc=$?
        if [[ ${rc} -ne 1 ]]; then
            cat "${RESULT_DIR}/crossfile-002-bash.log" >&2
            exit ${rc}
        fi
    fi
done

if [[ -d deploy/setup/flux ]]; then
    echo "Unexpected directory deploy/setup/flux present" >&2
    exit 1
fi

expected=(
    "deploy/metal/docs/index.md"
    "deploy/flux/cluster/cluster.yaml"
)
artifact_hash_collect "${RESULT_DIR}/crossfile-002-bash.sha256" "${expected[@]}"


popd >/dev/null

echo "artifact_hash_file=${RESULT_DIR}/crossfile-002-bash.sha256"
