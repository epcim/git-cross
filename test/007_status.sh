#!/usr/bin/env bash
source $(dirname "$0")/common.sh

# Initialize
setup_sandbox
# common.sh sets SANDBOX and cd's into it, which is our local repo.

# Setup upstream
upstream_path=$(create_upstream "upstream-repo")
upstream_url="file://$upstream_path"

# Ensure docs directory exists in upstream
pushd "$upstream_path" >/dev/null
mkdir -p docs
echo "Docs content" > docs/README.md
git add docs/README.md
git commit -m "Add docs"
popd >/dev/null

# Use and Patch
just cross use upstream "$upstream_url"
just cross patch upstream:docs vendor/docs

# Helper to check status output
check_status() {
    local path="$1"
    local pattern="$2"
    local output=$(just cross status)
    
    if ! echo "$output" | grep -q "$path"; then
         fail "Status output missing path '$path'"
    fi
    
    if ! echo "$output" | grep "$path" | grep -q "$pattern"; then
         echo "Status Output:"
         echo "$output"
         fail "Status for '$path' did not match pattern '$pattern'"
    fi
}

# ------------------------------------------------------------------
# Test 1: Clean
# ------------------------------------------------------------------
check_status "vendor/docs" "Clean.*Synced"

# ------------------------------------------------------------------
# Test 2: Modified (Local change)
# ------------------------------------------------------------------
echo "Modification" >> vendor/docs/README.md
check_status "vendor/docs" "Modified.*Synced"

# Revert change for next test
git checkout vendor/docs/README.md

# ------------------------------------------------------------------
# Test 3: Behind (Upstream has new commits)
# ------------------------------------------------------------------
pushd "$upstream_path" >/dev/null
echo "Upstream change" >> docs/README.md
git add docs/README.md
git commit -m "Upstream update"
popd >/dev/null

# We need to fetch in the worktree to see "behind"
# 'just cross sync' would pull and update, making it synced again.
# We manually fetch in the worktree to simulate the state where we know about updates but haven't synced.
# First, identify worktree
wt_dir=$(find .git/cross/worktrees -maxdepth 1 -name "upstream_*" | head -n 1)
if [ -z "$wt_dir" ]; then fail "Worktree not found"; fi

git -C "$wt_dir" fetch upstream
check_status "vendor/docs" "Clean.*1 behind"

# ------------------------------------------------------------------
# Test 4: Ahead (Local changes committed in WT)
# ------------------------------------------------------------------
# Reset upstream to match local first (simplification)
# or just make a new commit in WT that is ahead of upstream/master
# We are currently 1 behind. Let's sync to get even.
just cross sync vendor/docs
check_status "vendor/docs" "Clean.*Synced"

# Now commit something in WT
pushd "$wt_dir" >/dev/null
echo "WT change" >> docs/README.md
git add docs/README.md
git commit -m "WT changes"
popd >/dev/null

check_status "vendor/docs" ".*1 ahead"

# ------------------------------------------------------------------
# Test 5: Missing WT
# ------------------------------------------------------------------
rm -rf "$wt_dir"
check_status "vendor/docs" "Missing WT"

echo "Test 007 passed!"
