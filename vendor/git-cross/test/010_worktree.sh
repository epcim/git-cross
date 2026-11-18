#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

# The cd/wt commands now print a path instead of opening a subshell.
# Skip this test unless the Go implementation was explicitly requested.
if [ "${TEST_USE_IMPL:-}" != "go" ]; then
    echo "Skipping test 010: cd/wt implementation checks are opt-in (TEST_USE_IMPL=go)"
    exit 0
fi

setup_sandbox
cd "$SANDBOX"

upstream_path=$(create_upstream "shell-worktree")
upstream_url="file://$upstream_path"

pushd "$upstream_path" >/dev/null
mkdir -p src
echo "shell data" > src/data.txt
git add src/data.txt
git commit -m "Add shell data" >/dev/null
popd >/dev/null

just cross use demo "$upstream_url" >/dev/null
just cross patch demo:src vendor/shell-src >/dev/null

# Test cd with explicit path: stdout is exactly the absolute local path.
expected_local=$(cd vendor/shell-src && pwd -P)
output=$(just cross cd vendor/shell-src 2>/dev/null)
if [ "$output" != "$expected_local" ]; then
    fail "cd with explicit path returned '$output', expected '$expected_local'"
fi

# Test wt with explicit path: stdout is exactly the absolute worktree path.
wt=$(jq -r '.patches[] | select(.local_path == "vendor/shell-src") | .worktree' .cross/metadata.json)
expected_wt=$(cd "$wt" && pwd -P)
output=$(just cross wt vendor/shell-src 2>/dev/null)
if [ "$output" != "$expected_wt" ]; then
    fail "wt with explicit path returned '$output', expected '$expected_wt'"
fi

# Test cd from patch directory (implicit context).
pushd vendor/shell-src >/dev/null
output=$(just cross cd 2>/dev/null)
if [ "$output" != "$expected_local" ]; then
    fail "cd from patch directory returned '$output', expected '$expected_local'"
fi
popd >/dev/null

echo "Shell cd command tests passed!"
