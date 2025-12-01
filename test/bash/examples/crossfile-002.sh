#!/usr/bin/env bash
set -euo pipefail

workspace=${1:?"workspace path required"}
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../../.. && pwd)"
RESULT_DIR="${ROOT_DIR}/test/results/examples"
mkdir -p "${RESULT_DIR}"

source "${ROOT_DIR}/test/bash/lib/artifact_hash.sh"

repo_dir="${workspace}/crossfile-002"
rm -rf "${repo_dir}"
git clone --local --no-hardlinks "${ROOT_DIR}" "${repo_dir}" >/dev/null
cp "${ROOT_DIR}/cross" "${repo_dir}/cross"

pushd "${repo_dir}" >/dev/null
rm -rf deploy
mkdir -p deploy

export CROSS_NON_INTERACTIVE=1
export VERBOSE=true
source "${repo_dir}/cross"
: >"${RESULT_DIR}/crossfile-002-bash.log"
setup >>"${RESULT_DIR}/crossfile-002-bash.log" 2>&1
FETCHED=('')
{
    use khue "file://${ROOT_DIR}/test/fixtures/remotes/khue.git"
    use bill "file://${ROOT_DIR}/test/fixtures/remotes/bill.git"
    patch khue:/metal deploy/metal
    patch bill:/setup/flux deploy/flux
} >>"${RESULT_DIR}/crossfile-002-bash.log" 2>&1

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
