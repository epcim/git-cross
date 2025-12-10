#!/bin/bash
# Source 001 to setup environment and run 'use' tests
# This sets up SANDBOX, upstream_path, upstream_url, and runs 'just cross use'
CLEANUP={$CLEANUP:-true} source test/001_use.sh

log_header "Testing 'just cross patch' (002)..."

# Add content to upstream
mkdir -p "$upstream_path/src/lib"
echo "lib v1" > "$upstream_path/src/lib/lib.txt"
git -C "$upstream_path" add src/lib/lib.txt
git -C "$upstream_path" commit -m "Add lib" -q

# Use and patch
just cross use repo1 "$upstream_url"
just cross patch repo1:src/lib vendor/lib

# Verify
log_header "Verify 'just cross patch' (002)..."
assert_dir_exists "vendor/lib"
assert_file_exists "vendor/lib/lib.txt"
assert_grep "vendor/lib/lib.txt" "lib v1"

# Verify Crossfile
assert_grep "Crossfile" "cross patch repo1:main:src/lib vendor/lib"

echo "Success!"
