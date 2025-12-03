#!/bin/bash
set -euo pipefail

# Universal test runner for git-cross

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
TEST_DIR="${ROOT_DIR}/test"
RESULT_DIR="${TEST_DIR}/results"

# Ensure results directory exists
mkdir -p "${RESULT_DIR}"

# Source helpers if available, but tests should also source them
# source "${TEST_DIR}/test_helpers.sh"

run_test_script() {
    local script="$1"
    local script_name
    script_name=$(basename "$script")
    
    echo "======================================================="
    echo "Running test: ${script_name}"
    echo "======================================================="
    
    if [[ ! -x "$script" ]]; then
        echo "WARNING: ${script} is not executable, attempting to run with bash"
        if bash "$script"; then
            echo "✅ ${script_name} PASSED"
            return 0
        else
            echo "❌ ${script_name} FAILED"
            return 1
        fi
    else
        if "$script"; then
            echo "✅ ${script_name} PASSED"
            return 0
        else
            echo "❌ ${script_name} FAILED"
            return 1
        fi
    fi
}

run_all_tests() {
    local failed=0
    local passed=0
    local total=0
    
    echo "Running all tests in ${TEST_DIR}..."
    
    # Find all test_*.sh scripts
    local tests=()
    while IFS= read -r -d '' file; do
        tests+=("$file")
    done < <(find "${TEST_DIR}" -maxdepth 1 -name "test_*.sh" -print0 | sort -z)
    
    if [[ ${#tests[@]} -eq 0 ]]; then
        echo "No tests found matching 'test_*.sh' in ${TEST_DIR}"
        exit 1
    fi
    
    for script in "${tests[@]}"; do
        ((total++))
        if run_test_script "$script"; then
            ((passed++))
        else
            ((failed++))
        fi
    done
    
    echo "-------------------------------------------------------"
    echo "Test Summary: ${passed}/${total} passed, ${failed} failed"
    echo "-------------------------------------------------------"
    
    if [[ $failed -gt 0 ]]; then
        exit 1
    fi
}

run_specific_test() {
    local id="$1"
    # Try to find matching script
    # Matches: test_${id}_*.sh or test_${id}.sh
    
    local match
    match=$(find "${TEST_DIR}" -maxdepth 1 -name "test_${id}*.sh" | head -n 1)
    
    if [[ -z "$match" ]]; then
        # Try without prefix if user gave full name or partial
        match=$(find "${TEST_DIR}" -maxdepth 1 -name "*${id}*.sh" | head -n 1)
    fi
    
    if [[ -n "$match" ]]; then
        run_test_script "$match"
    else
        echo "Error: No test found matching ID '${id}'"
        exit 1
    fi
}

main() {
    if [[ $# -eq 0 ]]; then
        run_all_tests
    else
        run_specific_test "$1"
    fi
}

main "$@"
