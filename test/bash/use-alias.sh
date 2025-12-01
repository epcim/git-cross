#!/usr/bin/env bash
set -euo pipefail

workspace=${1:?"workspace path required"}
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd)"
RESULT_DIR="${ROOT_DIR}/test/results"
mkdir -p "${RESULT_DIR}"

repo_dir="${workspace}/use-alias"
rm -rf "${repo_dir}"
git clone --local --no-hardlinks "${ROOT_DIR}" "${repo_dir}" >/dev/null
cp "${ROOT_DIR}/cross" "${repo_dir}/cross"

pushd "${repo_dir}" >/dev/null

metadata_digest() {
    if [[ ! -d .git/cross ]]; then
        echo "missing-cross-metadata"
        return
    fi
    find .git/cross -type f -print0 | sort -z | xargs -0 shasum -a 256 2>/dev/null
}

remote_url="file://${ROOT_DIR}/test/fixtures/remotes/bill.git"

./cross use demo "${remote_url}" >>"${RESULT_DIR}/use-alias.log" 2>&1
first_hash=$(metadata_digest)
./cross use demo "${remote_url}" >>"${RESULT_DIR}/use-alias.log" 2>&1
second_hash=$(metadata_digest)

if [[ "${first_hash}" != "${second_hash}" ]]; then
    echo "Alias metadata changed between runs" >&2
    exit 1
fi

popd >/dev/null
