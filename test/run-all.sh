#!/bin/bash
set -euo pipefail

# Test case parameters
export TESTDIR=$PWD/testdir # or keep empty to use tempdir

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "Running all tests..."
echo "PATH is: $PATH"
if ! command -v just >/dev/null; then
    echo "WARNING: just not found in PATH"
    # PATH adjustment for development environments
    for p in "$HOME/.cargo/bin" "$HOME/homebrew/bin" "/opt/homebrew/bin" "/usr/local/bin"; do
        if [ -d "$p" ]; then
            export PATH="$p:$PATH"
        fi
    done
fi
failed=0
total=0

# If args are provided, run specific tests
# If args are provided, run specific tests
if [ $# -gt 0 ]; then
    tests=()
    for arg in "$@"; do
        if [[ "$arg" =~ ^[0-9]+$ ]]; then
            # Find test file starting with this number (padded or not)
            # Try exact match first then padded
            matches=(test/"$arg"_*.sh)
            if [ ! -f "${matches[0]}" ]; then
                # Try with leading zeros (assuming 3 digits)
                printf -v pad "%03d" "$arg"
                matches=(test/"$pad"_*.sh)
            fi
            
            if [ -f "${matches[0]}" ]; then
                tests+=("${matches[0]}")
            else
                echo "Warning: No test found for index $arg"
            fi
        else
            # Assume it's a filename
            tests+=("$arg")
        fi
    done
else
    # Discover tests.
    # Every remaining test targets the v0.5.0+ gitdir architecture; the retired
    # ones (005 replay, 008/011 rust, 021 compare) were deleted with their
    # commands. Rust itself was deleted in v0.5.1; just-side sub-cases of Go-only
    # commands SKIP (just_ref_implements in common.sh).
    tests=(test/[0-9]*.sh)
fi


# Go-level integration tests (src-go/*_test.go) cover the update/resolve contract
# directly, so they run before the shell suite.
if [ $# -eq 0 ] && command -v go >/dev/null 2>&1; then
    total=$((total + 1))
    echo "Running go test ./src-go ..."
    if ( cd src-go && go test -mod=mod ./... ) 2>&1 | tee src-go/go-test.log; then
        echo -e "${GREEN}PASS: go test ./src-go${NC}"
    else
        echo -e "${RED}FAIL: go test ./src-go${NC}"
        failed=$((failed + 1))
    fi
    echo "---------------------------------------------------"
fi

for t in "${tests[@]}"; do
    # If the file doesn't exist (e.g. glob failed), skip
    
    # Clean shared testdir between tests to prevent stale worktree state
    if [ -d "$TESTDIR" ]; then
        chmod -R u+w "$TESTDIR" 2>/dev/null || true
        rm -r "$TESTDIR" 2>/dev/null || true
    fi
    [ -f "$t" ] || continue
    
    total=$((total + 1))
    echo "Running $t ..."
    
    # Run test in a subshell to isolate failures, stream output to stdout and log
    if bash "$t" 2>&1 | tee "$t.log"; then
        echo -e "${GREEN}PASS: $t${NC}"
    else
        echo -e "${RED}FAIL: $t${NC}"
        failed=$((failed + 1))
    fi
    echo "---------------------------------------------------"
done

echo "---------------------------------------------------"
if [ "$failed" -eq 0 ]; then
    echo -e "${GREEN}All $total tests passed.${NC}"
    exit 0
else
    echo -e "${RED}$failed out of $total tests failed.${NC}"
    exit 1
fi
