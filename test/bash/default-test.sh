#!/usr/bin/env bash
set -euo pipefail

workspace=${1:?"workspace path required"}
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd)"
RESULT_DIR="${ROOT_DIR}/test/results"

source "${ROOT_DIR}/test/bash/lib/artifact_hash.sh"

clone_dir="${workspace}/cross-repo"
rm -rf "${clone_dir}"
git clone --local --no-hardlinks "${ROOT_DIR}" "${clone_dir}" >/dev/null

cat >"${clone_dir}/Crossfile" <<EOF
use bill file://${ROOT_DIR}/test/fixtures/remotes/bill.git
use khue file://${ROOT_DIR}/test/fixtures/remotes/khue.git
patch bill:/setup/flux deploy/flux --branch master
patch khue:/metal deploy/metal --branch master
EOF

pushd "${clone_dir}" >/dev/null
rm -rf deploy
mkdir -p deploy

export CROSS_NON_INTERACTIVE=1
export VERBOSE=true
if ! ./cross; then
    echo "cross command failed" >&2
    exit 1
fi

if [[ -d deploy/setup/flux ]]; then
    echo "Unexpected directory deploy/setup/flux present" >&2
    exit 1
fi

mkdir -p "${RESULT_DIR}"
for path in deploy/flux/cluster/cluster.yaml deploy/metal/docs/index.md; do
    if [[ ! -e "${path}" ]]; then
        echo "Expected file ${path} missing" >&2
        exit 1
    fi
 done
artifact_hash_collect "${RESULT_DIR}/default-artifacts-bash.sha256" \
    deploy/flux/cluster/cluster.yaml \
    deploy/metal/docs/index.md

if git status --short | grep -q "deploy/setup/flux"; then
    echo "Root git status shows unexpected deploy/setup/flux entries" >&2
    exit 1
fi

if ! git -C deploy/flux status | grep -q "branch is up to date with 'bill/master'"; then
    echo "deploy/flux status missing expected message" >&2
    exit 1
fi

popd >/dev/null

echo "Default testcase completed successfully"
echo "artifact_hash_file=${RESULT_DIR}/default-artifacts-bash.sha256"
