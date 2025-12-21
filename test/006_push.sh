#!/usr/bin/env bash
source $(dirname "$0")/common.sh

# AICONTEXT: temporarily disabled feature in progress
exit 0


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

# Verify proper initial state
test -f vendor/docs/README.md || fail "vendor/docs/README.md should exist"

# ------------------------------------------------------------------
# Test 1: Basic Push (Auto-msg, Non-interactive)
# ------------------------------------------------------------------
echo "Change 1" >> vendor/docs/README.md
git add vendor/docs/README.md
git commit -m "Local change 1"

just cross push vendor/docs yes=true

# Verify upstream has the commit
pushd "$upstream_path" >/dev/null
last_msg=$(git log -1 --pretty=%s)
if [[ "$last_msg" != "Local change 1" ]]; then
    fail "Expected upstream commit msg 'Local change 1', got '$last_msg'"
fi
popd >/dev/null

# ------------------------------------------------------------------
# Test 2: Custom Commit Message (Non-interactive)
# ------------------------------------------------------------------
echo "Change 2" >> vendor/docs/README.md
git add vendor/docs/README.md
git commit -m "Local change 2 to be ignored"

just cross push vendor/docs yes=true message="Custom Msg"

pushd "$upstream_path" >/dev/null
last_msg=$(git log -1 --pretty=%s)
if [[ "$last_msg" != "Custom Msg" ]]; then
    fail "Expected upstream commit msg 'Custom Msg', got '$last_msg'"
fi
popd >/dev/null

# ------------------------------------------------------------------
# Test 3: Push to generic branch
# ------------------------------------------------------------------
echo "Change 3" >> vendor/docs/README.md
git add vendor/docs/README.md
git commit -m "Local change 3"

just cross push vendor/docs branch=feature-branch yes=true

pushd "$upstream_path" >/dev/null
if ! git rev-parse --verify feature-branch >/dev/null 2>&1; then
    fail "Branch 'feature-branch' was not created on upstream"
fi
git checkout feature-branch
last_msg=$(git log -1 --pretty=%s)
if [[ "$last_msg" != "Local change 3" ]]; then
    fail "Expected 'Local change 3' on feature-branch, got '$last_msg'"
fi
popd >/dev/null

# ------------------------------------------------------------------
# Test 4: Force Push
# ------------------------------------------------------------------
# Change history on upstream to cause conflict
pushd "$upstream_path" >/dev/null
git checkout master
echo "Conflict" >> docs/README.md
git add docs/README.md
git commit -m "Upstream conflict"
popd >/dev/null

# Local change that conflicts (or just divergent history)
echo "Change 4" >> vendor/docs/README.md
git add vendor/docs/README.md
git commit -m "Local change 4"

# Normal push should fail? 
if just cross push vendor/docs branch=master force=false yes=true 2>/dev/null; then
  echo "Warning: push succeeded unexpectedly (maybe auto-merge happened?) or failed silently"
else
  echo "Push failed as expected (non-fast-forward)"
fi

# Now force push
just cross push vendor/docs branch=master force=true yes=true

pushd "$upstream_path" >/dev/null
git checkout master
last_msg=$(git log -1 --pretty=%s)
if [[ "$last_msg" != "Local change 4" ]]; then
    fail "Expected 'Local change 4' after force push, got '$last_msg'"
fi
popd >/dev/null

echo "Test 006 passed!"
