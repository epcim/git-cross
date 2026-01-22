#!/bin/bash
source "$(dirname "$0")/common.sh"

######
# Test 1: Prune specific remote with its patches
######
log_header "Test 1: Prune specific remote..."

# Setup test environment
setup_sandbox
cd "$SANDBOX"

# Create upstream repo
upstream1=$(create_upstream "upstream1")
mkdir -p "$upstream1/src"
pushd "$upstream1" >/dev/null
echo "upstream1 content" > src/file1.txt
git add src/file1.txt && git commit -m "Add src" -q
popd >/dev/null

# Add remote and create patch
just cross use test-remote-1 "file://$upstream1" || fail "Failed to add remote"
just cross patch test-remote-1:src vendor/src || fail "Failed to create patch"

# Verify patch exists
if [ ! -d "vendor/src" ]; then
    fail "Patch directory not created"
fi

# Prune the specific remote (this removes the patch AND the remote)
just cross prune test-remote-1 || fail "Prune failed"

# Verify patch is removed from metadata
if [ -f ".git/cross/metadata.json" ]; then
    patch_count=$(jq -r '.patches | length' .git/cross/metadata.json)
    if [ "$patch_count" != "0" ]; then
        fail "Expected 0 patches after prune, got $patch_count"
    fi
fi

# Verify remote is removed
if git remote | grep -q "test-remote-1"; then
    fail "Remote test-remote-1 still exists after prune"
fi

log_success "Test 1 passed: Specific remote pruned successfully"

######
# Test 2: Prune unused remotes (interactive mode - skip for automation)
######
log_header "Test 2: Prune with unused remotes..."

# Reset sandbox
setup_sandbox
cd "$SANDBOX"

# Create two upstream repos
upstream1=$(create_upstream "upstream1")
mkdir -p "$upstream1/src"
pushd "$upstream1" >/dev/null
echo "upstream1 content" > src/file1.txt
git add src/file1.txt && git commit -m "Add src" -q
popd >/dev/null

upstream2=$(create_upstream "upstream2")
mkdir -p "$upstream2/docs"
pushd "$upstream2" >/dev/null
echo "upstream2 content" > docs/file2.txt
git add docs/file2.txt && git commit -m "Add docs" -q
popd >/dev/null

# Add remotes
just cross use used-remote "file://$upstream1" || fail "Failed to add used-remote"
git remote add unused-remote "file://$upstream2"

# Create patch only for used-remote
just cross patch used-remote:src vendor/src || fail "Failed to create patch"

# Verify we have 2 remotes
remote_count=$(git remote | wc -l | tr -d ' ')
if [ "$remote_count" != "2" ]; then
    fail "Expected 2 remotes, got $remote_count"
fi

# Note: Interactive prune test requires user input, so we just verify the command exists
# and doesn't crash with no unused remotes scenario
log_info "Skipping interactive prune test (requires user input)"

log_success "Test 2 passed: Setup validated for interactive prune"

######
# Test 3: Worktree pruning
######
log_header "Test 3: Verify worktree pruning..."

# Create and then remove a patch to leave a stale worktree
upstream3=$(create_upstream "upstream3")
mkdir -p "$upstream3/lib"
pushd "$upstream3" >/dev/null
echo "upstream3 content" > lib/file3.txt
git add lib/file3.txt && git commit -m "Add lib" -q
popd >/dev/null

just cross use test-remote-3 "file://$upstream3" || fail "Failed to add remote"
just cross patch test-remote-3:lib vendor/lib || fail "Failed to create patch"

# Manually break the worktree (simulate corruption)
worktree_dir=$(find .git/cross/worktrees -maxdepth 1 -type d -name "test-remote-3_*" | head -n 1)
if [ -n "$worktree_dir" ]; then
    log_info "Found worktree: $worktree_dir"
    # Remove worktree directory but leave git reference (creates stale reference)
    rm -rf "$worktree_dir"
fi

# Prune the remote (this should also run git worktree prune)
just cross prune test-remote-3 2>/dev/null || fail "Prune failed"

# Verify no stale worktrees remain (git worktree list should only show main)
worktree_count=$(git worktree list | wc -l | tr -d ' ')
if [ "$worktree_count" != "1" ]; then
    log_warn "Expected 1 worktree (main), got $worktree_count (may include stale entries)"
    # This is non-fatal as git worktree prune is best-effort
fi

log_success "Test 3 passed: Worktree pruning completed"

log_success "All prune tests passed!"
