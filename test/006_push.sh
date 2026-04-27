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
# Allow pushing to current branch (required for local test repos)
git config receive.denyCurrentBranch ignore
popd >/dev/null

# Detect the default branch name used by upstream
default_branch=$(git -C "$upstream_path" rev-parse --abbrev-ref HEAD)

# Use and Patch
just cross use upstream "$upstream_url"
just cross patch upstream:docs vendor/docs

# Verify proper initial state
test -f vendor/docs/README.md || fail "vendor/docs/README.md should exist"

# ------------------------------------------------------------------
# Test 1: Basic Push (Auto-msg, Non-interactive)
# ------------------------------------------------------------------
log_header "Test 1: Basic push with auto-generated message..."
echo "Change 1" >> vendor/docs/README.md
git add vendor/docs/README.md
git commit -m "Local change 1"

# Just recipe signature: push path="" branch="" force="false" yes="false" message=""
# Arguments are POSITIONAL: path, branch, force, yes, message
# NOTE: We call Justfile.cross directly because the `just cross` wrapper uses
# *ARGS which loses empty string arguments during re-expansion.
REPO_DIR=$(git rev-parse --show-toplevel)
export REPO_DIR
JUSTFILE_CROSS="$SANDBOX/Justfile.cross"

REPO_DIR="$REPO_DIR" just --justfile "$JUSTFILE_CROSS" push vendor/docs "" false true

# Verify upstream has the commit
pushd "$upstream_path" >/dev/null
git reset --hard HEAD  # refresh working tree after receiving push
last_msg=$(git log -1 --pretty=%s)
if [[ "$last_msg" != "Local change 1" ]]; then
    fail "Expected upstream commit msg 'Local change 1', got '$last_msg'"
fi
popd >/dev/null
log_success "Test 1 passed: Basic push"

# ------------------------------------------------------------------
# Test 2: Custom Commit Message (Non-interactive)
# ------------------------------------------------------------------
log_header "Test 2: Push with custom commit message..."
echo "Change 2" >> vendor/docs/README.md
git add vendor/docs/README.md
git commit -m "Local change 2 to be ignored"

REPO_DIR="$REPO_DIR" just --justfile "$JUSTFILE_CROSS" push vendor/docs "" false true "Custom Msg"

pushd "$upstream_path" >/dev/null
git reset --hard HEAD
last_msg=$(git log -1 --pretty=%s)
if [[ "$last_msg" != "Custom Msg" ]]; then
    fail "Expected upstream commit msg 'Custom Msg', got '$last_msg'"
fi
popd >/dev/null
log_success "Test 2 passed: Custom commit message"

# ------------------------------------------------------------------
# Test 3: Push to a named branch
# ------------------------------------------------------------------
log_header "Test 3: Push to named branch..."
echo "Change 3" >> vendor/docs/README.md
git add vendor/docs/README.md
git commit -m "Local change 3"

REPO_DIR="$REPO_DIR" just --justfile "$JUSTFILE_CROSS" push vendor/docs feature-branch false true

pushd "$upstream_path" >/dev/null
if ! git rev-parse --verify feature-branch >/dev/null 2>&1; then
    fail "Branch 'feature-branch' was not created on upstream"
fi
last_msg=$(git -C "$upstream_path" log feature-branch -1 --pretty=%s)
if [[ "$last_msg" != "Local change 3" ]]; then
    fail "Expected 'Local change 3' on feature-branch, got '$last_msg'"
fi
popd >/dev/null
log_success "Test 3 passed: Push to named branch"

# ------------------------------------------------------------------
# Test 4: Force Push
# ------------------------------------------------------------------
log_header "Test 4: Force push after divergence..."
# Change history on upstream to cause conflict
pushd "$upstream_path" >/dev/null
git checkout "$default_branch" -q
echo "Conflict" >> docs/README.md
git add docs/README.md
git commit -m "Upstream conflict"
popd >/dev/null

# Local change that conflicts (divergent history)
echo "Change 4" >> vendor/docs/README.md
git add vendor/docs/README.md
git commit -m "Local change 4"

# Normal push should fail (non-fast-forward)
if REPO_DIR="$REPO_DIR" just --justfile "$JUSTFILE_CROSS" push vendor/docs "$default_branch" false true 2>/dev/null; then
  log_info "Push succeeded unexpectedly (auto-merge may have happened)"
else
  log_info "Push failed as expected (non-fast-forward)"
fi

# Now force push
REPO_DIR="$REPO_DIR" just --justfile "$JUSTFILE_CROSS" push vendor/docs "$default_branch" true true

pushd "$upstream_path" >/dev/null
git checkout "$default_branch" -q
git reset --hard HEAD
last_msg=$(git log -1 --pretty=%s)
if [[ "$last_msg" != "Local change 4" ]]; then
    fail "Expected 'Local change 4' after force push, got '$last_msg'"
fi
popd >/dev/null
log_success "Test 4 passed: Force push"

echo "Test 006 passed!"
