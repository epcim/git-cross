#!/usr/bin/env bash
set -euo pipefail

workspace=${1:?"workspace path required"}
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../../.. && pwd)"
RESULT_DIR="${ROOT_DIR}/test/results/examples"
mkdir -p "${RESULT_DIR}"

source "${ROOT_DIR}/test/bash/lib/artifact_hash.sh"

repo_dir="${workspace}/crossfile-005"
rm -rf "${repo_dir}"
git clone --local --no-hardlinks "${ROOT_DIR}" "${repo_dir}" >/dev/null
cp "${ROOT_DIR}/cross" "${repo_dir}/cross"
cp "${ROOT_DIR}/Justfile" "${repo_dir}/Justfile"
cp "${ROOT_DIR}/.env" "${repo_dir}/.env"
cp "${ROOT_DIR}/examples/Crossfile-005" "${repo_dir}/Crossfile"

pushd "${repo_dir}" >/dev/null

# Create a user Justfile with posthook
cat <<EOF > Justfile
# User's Justfile
posthook:
    @echo "User posthook executed"
    @touch posthook_executed
EOF

: >"${RESULT_DIR}/crossfile-005-bash.log"
./cross setup >>"${RESULT_DIR}/crossfile-005-bash.log" 2>&1

{
    ./cross exec just posthook
} >>"${RESULT_DIR}/crossfile-005-bash.log" 2>&1

if [[ ! -f "posthook_executed" ]]; then
    echo "Expected file posthook_executed missing" >&2
    exit 1
fi

artifact_hash_collect "${RESULT_DIR}/crossfile-005-bash.sha256" "posthook_executed"

popd >/dev/null

echo "artifact_hash_file=${RESULT_DIR}/crossfile-005-bash.sha256"
