#!/bin/bash
# Test 2: Sync updates from upstream

set -e
source "$(dirname "$0")/test_helpers.sh"

setup_test_env

# Setup mock remotes
echo "Setting up mock remotes..."
DEMO_URL=$(create_mock_remote "demo" "docs")

# Setup main repo
setup_main_repo

echo "---------------------------------------------------"
echo "Test 2: Sync updates from upstream"
echo "---------------------------------------------------"

# Initial patch
just use demo "$DEMO_URL"
just patch demo:docs vendor/docs

# Update the remote
cd ..
update_mock_remote "demo" "docs" "Updated content"
cd main-repo

# Record current content
BEFORE=$(cat vendor/docs/file.txt)

# Sync should pull updates AND update local files automatically
just sync > /dev/null 2>&1 || echo "Sync completed (may have warnings)"

# Check if visible files were updated
if grep -q "Updated content" vendor/docs/file.txt; then
    echo "PASS: Sync automatically updated local files"
else
    echo "FAIL: Sync did not update local files"
    exit 1
fi

echo "✅ Test 2 passed"
cleanup_test_env
