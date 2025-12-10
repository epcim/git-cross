#!/bin/bash
source test/common.sh

setup_sandbox "$TESTDIR" "true"

# Create a dummy upstream repo
upstream_path=$(create_upstream "repo1")
upstream_url="file://$upstream_path"

log_header "Testing 'just cross use'..."
just cross use repo1 "$upstream_url"

# Verify remote added
if ! git remote show | grep -q "^repo1$"; then
    echo "Failed: Remote repo1 not added."
    exit 1
fi

# Verify Crossfile updated
assert_file_exists "Crossfile"
assert_grep "Crossfile" "cross use repo1 $upstream_url"

echo "Success!"
