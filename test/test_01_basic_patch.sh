#!/bin/bash
# Test 1: Basic patch functionality

set -e
source "$(dirname "$0")/test_helpers.sh"

setup_test_env

# Setup mock remotes
echo "Setting up mock remotes..."
DEMO_URL=$(create_mock_remote "demo" "docs")

# Setup main repo
setup_main_repo

echo "---------------------------------------------------"
echo "Test 1: Basic patch"
echo "---------------------------------------------------"

just use demo "$DEMO_URL"
just patch demo:docs vendor/docs

assert_file_contains "Crossfile" "cross use demo $DEMO_URL"
assert_file_contains "Crossfile" "cross patch demo:docs vendor/docs"

if [ -f "vendor/docs/file.txt" ]; then
    echo "PASS: vendor/docs/file.txt exists"
else
    echo "FAIL: vendor/docs/file.txt missing"
    exit 1
fi

echo "✅ Test 1 passed"
cleanup_test_env
