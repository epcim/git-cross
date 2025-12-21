#!/usr/bin/env bash
set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

export PATH=$HOME/homebrew/bin:$PATH

run_implementation_tests() {
    local impl=$1
    echo "==================================================="
    echo " RUNNING TESTS FOR: $impl"
    echo "==================================================="
    
    case "$impl" in
        shell)
            ./test/run-all.sh
            ;;
        rust)
            ./test/008_rust_cli.sh
            ;;
        go)
            ./test/009_go_cli.sh
            ;;
        *)
            echo "Unknown implementation: $impl"
            return 1
            ;;
    esac
}

failed_count=0
impls=("shell" "rust" "go")

for impl in "${impls[@]}"; do
    if ! run_implementation_tests "$impl"; then
        echo -e "${RED}FAILED: $impl${NC}"
        failed_count=$((failed_count + 1))
    else
        echo -e "${GREEN}PASSED: $impl${NC}"
    fi
done

echo "==================================================="
if [ "$failed_count" -eq 0 ]; then
    echo -e "${GREEN}All implementations passed!${NC}"
    exit 0
else
    echo -e "${RED}$failed_count implementation(s) failed.${NC}"
    exit 1
fi
