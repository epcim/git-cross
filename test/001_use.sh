#!/bin/bash
source test/common.sh

setup_sandbox "$TESTDIR" "true"

# Create a dummy upstream repo
upstream_path=$(create_upstream "repo1")
upstream_url="file://$upstream_path"

log_header "Testing 'just cross use'..."
just cross use repo1 "$upstream_url"

# v0.5.0: remotes are registered in .cross/metadata.json, NOT in the primary repo
assert_file_exists ".cross/metadata.json"
assert_grep ".cross/metadata.json" '"name": "repo1"'
assert_grep ".cross/metadata.json" "\"url\": \"$upstream_url\""

# The primary repo's git remotes must stay untouched
if git remote | grep -q "^repo1$"; then
    echo "Failed: Primary repo must NOT get a git remote (v2: remotes live in .cross)."
    exit 1
fi

# Verify Crossfile updated
assert_file_exists "Crossfile"
assert_grep "Crossfile" "cross use repo1 $upstream_url"

echo "Success!"
