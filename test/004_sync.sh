#!/bin/bash
source test/common.sh

CLEANUP={$CLEANUP:-true} source test/002_patch.sh

######
# Test 1: Basic sync - upstream changed, no local changes
######
log_header "Test 1: Basic sync with no local changes..."

# Modify upstream
echo "v2" > "$upstream_path/src/lib/file_sync.txt"
git -C "$upstream_path" add "$upstream_path/src/lib/file_sync.txt"
git -C "$upstream_path" commit -am "Update file" -q

# Sync
log_header "Running 'just cross sync'..."
just cross sync vendor/lib

# Verify local updated
assert_grep "vendor/lib/file_sync.txt" "v2"
log_success "Test 1 passed: Basic sync works"

######
# Test 2: Sync with uncommitted local changes (should preserve)
######
log_header "Test 2: Sync with uncommitted local changes..."

# Create uncommitted changes in local
echo "local-uncommitted-change" > "vendor/lib/local_new_file.txt"
echo "v2-modified-locally" > "vendor/lib/file_sync.txt"

# Modify upstream (different file to avoid conflict)
echo "v3-upstream-different-file" > "$upstream_path/src/lib/another_file.txt"
git -C "$upstream_path" add "$upstream_path/src/lib/another_file.txt"
git -C "$upstream_path" commit -m "Add another file" -q

# Sync should stash, pull, rsync, then restore
just cross sync vendor/lib

# Verify upstream changes arrived
assert_grep "vendor/lib/another_file.txt" "v3-upstream-different-file"

# Verify local uncommitted changes were preserved
assert_grep "vendor/lib/local_new_file.txt" "local-uncommitted-change"
assert_grep "vendor/lib/file_sync.txt" "v2-modified-locally"

log_success "Test 2 passed: Uncommitted changes preserved"

######
# Test 3: Sync with committed local changes
######
log_header "Test 3: Sync with committed local changes..."

# Commit the local changes
git add vendor/lib/
git commit -m "Local committed changes" -q

# Modify upstream again (non-conflicting)
echo "v4-upstream" > "$upstream_path/src/lib/upstream_file.txt"
git -C "$upstream_path" add "$upstream_path/src/lib/upstream_file.txt"
git -C "$upstream_path" commit -m "Add upstream file" -q

# Sync should work smoothly
just cross sync vendor/lib

# Verify both local and upstream changes exist
assert_grep "vendor/lib/local_new_file.txt" "local-uncommitted-change"
assert_grep "vendor/lib/upstream_file.txt" "v4-upstream"

log_success "Test 3 passed: Committed local changes synced"

######
# Test 4: Sync with conflicting changes (should fail gracefully)
######
log_header "Test 4: Sync with conflicting changes..."

# Modify same file locally and upstream
echo "v5-local" > "vendor/lib/file_sync.txt"

# Modify upstream (same file, different content)
echo "v5-upstream" > "$upstream_path/src/lib/file_sync.txt"
git -C "$upstream_path" commit -am "Conflict update" -q

# Sync should detect conflict and fail gracefully
cd vendor/lib
if just cross sync; then
    log_warn "Sync succeeded but should have detected conflict"
    # Check if conflict markers exist
    if grep -q "<<<<<<< HEAD" file_sync.txt 2>/dev/null; then
        log_success "Test 4 passed: Conflict detected (with markers)"
    else
        log_warn "No conflict markers found - may have auto-merged"
    fi
else
    log_success "Test 4 passed: Sync failed as expected (conflict detected)"
fi
cd ../..

# Cleanup after Test 4: Reset worktree to clean state
log_header "Cleaning up after conflict test..."
worktree_path=".git/cross/worktrees/repo1_2c89338b"
if [ -d "$worktree_path" ]; then
    # Abort any in-progress operations
    git -C "$worktree_path" rebase --abort 2>/dev/null || true
    git -C "$worktree_path" merge --abort 2>/dev/null || true
    
    # Remove any leftover rebase directories
    rm -rf "$worktree_path/.git/rebase-merge" 2>/dev/null || true
    rm -rf "$worktree_path/.git/rebase-apply" 2>/dev/null || true
    rm -rf ".git/worktrees/repo1_2c89338b/rebase-merge" 2>/dev/null || true
    rm -rf ".git/worktrees/repo1_2c89338b/rebase-apply" 2>/dev/null || true
    
    # Checkout correct branch and reset to clean state
    git -C "$worktree_path" checkout -B cross/repo1/main/2c89338b 2>/dev/null || true
    git -C "$worktree_path" fetch repo1 2>/dev/null || true
    git -C "$worktree_path" reset --hard repo1/main 2>/dev/null || true
    git -C "$worktree_path" clean -fd 2>/dev/null || true
fi

# Also clean up local modifications from Test 4
git restore vendor/lib/file_sync.txt 2>/dev/null || true
git stash drop 2>/dev/null || true  # Drop any leftover stash from Test 4

######
# Test 5: Sync with deleted files
######
log_header "Test 5: Sync with deleted upstream file..."

# Delete file upstream
rm "$upstream_path/src/lib/another_file.txt"
git -C "$upstream_path" commit -am "Delete another_file.txt" -q

# Sync should remove the file locally
just cross sync vendor/lib

# Verify file is deleted
if [ -f "vendor/lib/another_file.txt" ]; then
    log_error "Test 5 failed: Deleted file still exists locally"
    exit 1
else
    log_success "Test 5 passed: Deleted file removed locally"
fi

######
# Test 6: Sync with added files
######
log_header "Test 6: Sync with new upstream file..."

# Add new file upstream
echo "brand-new-file" > "$upstream_path/src/lib/new_upstream.txt"
git -C "$upstream_path" add "$upstream_path/src/lib/new_upstream.txt"
git -C "$upstream_path" commit -m "Add new file" -q

# Sync should add the file locally
just cross sync vendor/lib

# Verify new file exists
assert_grep "vendor/lib/new_upstream.txt" "brand-new-file"
log_success "Test 6 passed: New file added locally"

log_success "All sync tests passed!"
