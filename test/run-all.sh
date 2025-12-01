#!/usr/bin/env bash
set -euo pipefail

# Detect and add Homebrew to PATH
if [ -d "/opt/homebrew/bin" ]; then
    export PATH="/opt/homebrew/bin:$PATH"
elif [ -d "/usr/local/bin" ]; then
    export PATH="/usr/local/bin:$PATH"
elif [ -d "/home/linuxbrew/.linuxbrew/bin" ]; then
    export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"
elif [ -n "$HOMEBREW_PREFIX" ]; then
    export PATH="$HOMEBREW_PREFIX/bin:$PATH"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
TEST_DIR="${ROOT_DIR}/test"
RESULT_DIR="${TEST_DIR}/results"
LIB_DIR="${TEST_DIR}/bash/lib"
FIXTURE_TOOL="${ROOT_DIR}/scripts/fixture-tooling/seed-fixtures.sh"

source "${LIB_DIR}/workspace.sh"
source "${LIB_DIR}/git.sh"
source "${LIB_DIR}/report.sh"
source "${LIB_DIR}/artifact_hash.sh"

# declare -A BASH_HASH
# declare -A RUST_HASH
# Using file-based storage for hashes to support bash 3.2
HASH_DIR="${RESULT_DIR}/hashes"
mkdir -p "${HASH_DIR}"

show_usage() {
    cat <<'EOF'
Usage: test/run-all.sh [--scenario <examples|use|patch|all>]

Scenarios:
  examples   Run numbered example Crossfile end-to-end tests (default)
  use        Run alias registration idempotency checks
  patch      Run patch workflow regression suite
  all        Run every scenario sequentially
EOF
}

parse_args() {
    SCENARIO="examples"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --scenario)
                shift
                SCENARIO="${1:-examples}"
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                echo "WARNING: Unknown argument '$1'" >&2
                ;;
        esac
        shift
    done
}

ensure_results_dir() {
    mkdir -p "${RESULT_DIR}" "${RESULT_DIR}/examples"
    : >"${RESULT_DIR}/git.log"
    : >"${RESULT_DIR}/verification.json"
}

seed_fixtures() {
    if [[ -x "${FIXTURE_TOOL}" ]]; then
        "${FIXTURE_TOOL}" >/dev/null
    else
        echo "WARNING: Fixture tool ${FIXTURE_TOOL} missing or not executable" >&2
    fi
}

run_bash_example() {
    local script_id="$1"
    local workspace="$2"
    local script="${TEST_DIR}/bash/examples/${script_id}.sh"
    local scenario_label="examples-${script_id}"

    if [[ ! -x "${script}" ]]; then
        record_result "bash" "${scenario_label}" "skipped" "script missing"
        return 0
    fi

    local output
    if output="$(${script} "${workspace}")"; then
        record_result "bash" "${scenario_label}" "pass"
        local hash_file
        hash_file=$(printf '%s\n' "${output}" | awk -F= '/artifact_hash_file=/{print $2}' | tail -1)
        if [[ -n "${hash_file}" ]]; then
            # BASH_HASH["${script_id}"]="${hash_file}"
            echo "${hash_file}" > "${HASH_DIR}/bash_${script_id}"
        fi
    else
        record_result "bash" "${scenario_label}" "fail"
        return 1
    fi
}

run_rust_examples() {
    local log_file="${RESULT_DIR}/examples/cargo-examples.log"
    mkdir -p "${RESULT_DIR}/examples"
    if (cd "${TEST_DIR}/rust" && cargo test --quiet -- crossfile_ >>"${log_file}" 2>&1); then
        record_result "rust" "examples" "pass"
        for id in 001 002 003 005; do
            local hash_path="${RESULT_DIR}/examples/crossfile-${id}-rust.sha256"
            if [[ -f "${hash_path}" ]]; then
                # RUST_HASH["crossfile-${id}"]="${hash_path}"
                echo "${hash_path}" > "${HASH_DIR}/rust_crossfile-${id}"
            fi
        done
        return 0
    else
        record_result "rust" "examples" "fail"
        return 1
    fi
}

compare_parity() {
    local id
    for id in 001 002 003; do
        local key="crossfile-${id}"
        # local bash_hash="${BASH_HASH["${key}"]:-}"
        # local rust_hash="${RUST_HASH["${key}"]:-}"
        local bash_hash=""
        local rust_hash=""
        if [[ -f "${HASH_DIR}/bash_${key}" ]]; then
            bash_hash=$(cat "${HASH_DIR}/bash_${key}")
        fi
        if [[ -f "${HASH_DIR}/rust_${key}" ]]; then
            rust_hash=$(cat "${HASH_DIR}/rust_${key}")
        fi
        if [[ -z "${bash_hash}" || -z "${rust_hash}" ]]; then
            record_result "parity" "${key}" "skipped" "missing hash files"
            continue
        fi
        if artifact_hash_compare "${bash_hash}" "${rust_hash}"; then
            record_result "parity" "${key}" "pass"
        else
            record_result "parity" "${key}" "fail" "hash mismatch"
        fi
    done
}

run_examples() {
    local workspace="$1"
    for id in 001 002 003; do
        run_bash_example "crossfile-${id}" "${workspace}"
    done
    if run_rust_examples; then
        compare_parity
    fi
}

run_use() {
    local workspace="$1"
    local script="${TEST_DIR}/bash/use-alias.sh"
    if [[ -x "${script}" ]]; then
        if "${script}" "${workspace}" >>"${RESULT_DIR}/use-bash.log" 2>&1; then
            record_result "bash" "use" "pass"
        else
            record_result "bash" "use" "fail"
        fi
    else
        record_result "bash" "use" "skipped" "script missing"
    fi
}

run_patch() {
    local workspace="$1"
    local script="${TEST_DIR}/bash/patch-workflow.sh"
    if [[ -x "${script}" ]]; then
        if "${script}" "${workspace}" >>"${RESULT_DIR}/patch-bash.log" 2>&1; then
            record_result "bash" "patch" "pass"
        else
            record_result "bash" "patch" "fail"
        fi
    else
        record_result "bash" "patch" "skipped" "script missing"
    fi
}

run_verification_commands() {
    local workspace="$1"
    local status=0

    if ! bash -n "${ROOT_DIR}/cross" >>"${RESULT_DIR}/verification.log" 2>&1; then
        record_verification "bash -n cross" "fail"
        status=1
    else
        record_verification "bash -n cross" "pass"
    fi

    if command -v shellcheck >/dev/null 2>&1; then
        if ! shellcheck "${ROOT_DIR}/cross" >>"${RESULT_DIR}/verification.log" 2>&1; then
            record_verification "shellcheck cross" "fail"
            status=1
        else
            record_verification "shellcheck cross" "pass"
        fi
    else
        record_verification "shellcheck cross" "skipped" "shellcheck not installed"
    fi

    if ! (cd "${workspace}" && "${ROOT_DIR}/cross" status --refresh) >>"${RESULT_DIR}/verification.log" 2>&1; then
        record_verification "cross status --refresh" "fail"
        status=1
    else
        record_verification "cross status --refresh" "pass"
    fi

    return "${status}"
}

main() {
    parse_args "$@"
    ensure_results_dir
    seed_fixtures

    local workspace
    workspace="$(create_workspace)"
    cp "${ROOT_DIR}/Justfile" "${workspace}/Justfile"
    echo "INFO: Using temporary workspace ${workspace}" >&2
    trap 'cleanup_workspace "${workspace}"' EXIT

    case "${SCENARIO}" in
        examples)
            run_examples "${workspace}"
            ;;
        use)
            run_use "${workspace}"
            ;;
        patch)
            run_patch "${workspace}"
            ;;
        all)
            run_examples "${workspace}"
            run_use "${workspace}"
            run_patch "${workspace}"
            ;;
        *)
            echo "ERROR: Unknown scenario '${SCENARIO}'" >&2
            exit 1
            ;;
    esac

    run_verification_commands "${workspace}"
    write_report "${RESULT_DIR}/verification.json"
    echo "INFO: Verification report written to ${RESULT_DIR}/verification.json" >&2
}

main "$@"
