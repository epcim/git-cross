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
    # Try to find just and add to PATH
    if [ -f "$HOME/.cargo/bin/just" ]; then
        export PATH="$HOME/.cargo/bin:$PATH"
    elif [ -f "/opt/homebrew/bin/just" ]; then
        export PATH="/opt/homebrew/bin:$PATH"
    elif [ -f "/usr/local/bin/just" ]; then
        export PATH="/usr/local/bin:$PATH"
    fi
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
    # Discover tests
    # We look for files starting with digits in test/ directory
    # Note: We are running from ROOT_DIR, so test/ is ./test/
    tests=(test/[0-9]*.sh)
fi

for t in "${tests[@]}"; do
    # If the file doesn't exist (e.g. glob failed), skip
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
