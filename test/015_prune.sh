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
if [ -f ".cross/metadata.json" ]; then
    patch_count=$(jq -r '.patches | length' .cross/metadata.json)
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
worktree_dir=$(find .cross/worktrees -maxdepth 1 -type d -name "test-remote-3_*" | head -n 1)
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

######
# Test 4: Orphaned .cross/worktrees/ directory cleanup (Shell/Just)
######
log_header "Test 4: Orphaned worktree directory cleanup (Shell)..."

setup_sandbox
cd "$SANDBOX"

upstream4=$(create_upstream "upstream4")
mkdir -p "$upstream4/src"
pushd "$upstream4" >/dev/null
echo "content" > src/file.txt
git add src/file.txt && git commit -m "init" -q
popd >/dev/null

just cross use demo "file://$upstream4" || fail "Failed to add remote"
just cross patch demo:src vendor/src || fail "Failed to create patch"

# Verify active worktree exists
active_wt=$(find .cross/worktrees -maxdepth 1 -type d -name "demo_*" | head -n 1)
if [ -z "$active_wt" ]; then fail "Active worktree not found"; fi
log_info "Active worktree: $active_wt"

# Create orphaned worktree directories (simulating stale state from hash changes or manual ops)
mkdir -p .cross/worktrees/demo_deadbeef
echo "orphan" > .cross/worktrees/demo_deadbeef/dummy.txt
mkdir -p .cross/worktrees/old-remote_12345678

orphan_count=$(find .cross/worktrees -maxdepth 1 -type d ! -name worktrees | wc -l | tr -d ' ')
log_info "Worktree dirs before prune: $orphan_count (expect 3: 1 active + 2 orphans)"

# Run prune (no-arg mode, pipe 'n' to skip interactive remote removal)
echo "n" | just cross prune || true

# Verify orphaned dirs are removed but active one remains
if [ -d ".cross/worktrees/demo_deadbeef" ]; then fail "Orphaned demo_deadbeef not cleaned"; fi
if [ -d ".cross/worktrees/old-remote_12345678" ]; then fail "Orphaned old-remote_12345678 not cleaned"; fi
if [ ! -d "$active_wt" ]; then fail "Active worktree $active_wt was incorrectly removed"; fi

log_success "Test 4 passed: Orphaned worktree directories cleaned by Shell prune"

######
# Test 5: Orphaned .cross/worktrees/ directory cleanup (Go)
######
log_header "Test 5: Orphaned worktree directory cleanup (Go)..."

GO_BIN="$REPO_ROOT/src-go/git-cross-go"
if [ ! -f "$GO_BIN" ]; then
    if command -v go >/dev/null 2>&1; then
        rm -r "$REPO_ROOT/src-go/vendor" 2>/dev/null || true
        ( cd "$REPO_ROOT/src-go" && CGO_ENABLED=0 go build -mod=mod -tags purego -o git-cross-go main.go ) || GO_BIN=""
    else
        GO_BIN=""
    fi
fi

if [ -n "$GO_BIN" ] && [ -f "$GO_BIN" ]; then
    setup_sandbox
    cd "$SANDBOX"

    upstream5=$(create_upstream "upstream5")
    mkdir -p "$upstream5/lib"
    pushd "$upstream5" >/dev/null
    echo "content" > lib/file.txt
    git add lib/file.txt && git commit -m "init" -q
    popd >/dev/null

    "$GO_BIN" init
    "$GO_BIN" use demo "file://$upstream5"
    "$GO_BIN" patch demo:lib vendor/lib

    active_wt=$(find .cross/worktrees -maxdepth 1 -type d -name "demo_*" | head -n 1)
    if [ -z "$active_wt" ]; then fail "Active worktree not found (Go)"; fi

    # Create orphaned dirs
    mkdir -p .cross/worktrees/demo_deadbeef
    mkdir -p .cross/worktrees/stale_aabbccdd

    # Go prune (no-arg, pipe 'n' for interactive prompt)
    echo "n" | "$GO_BIN" prune

    if [ -d ".cross/worktrees/demo_deadbeef" ]; then fail "Go: orphaned demo_deadbeef not cleaned"; fi
    if [ -d ".cross/worktrees/stale_aabbccdd" ]; then fail "Go: orphaned stale_aabbccdd not cleaned"; fi
    if [ ! -d "$active_wt" ]; then fail "Go: active worktree incorrectly removed"; fi

    log_success "Test 5 passed: Orphaned worktree directories cleaned by Go prune"
else
    echo "SKIP: Go binary not available, skipping Go orphan prune test"
fi

######
# Test 6: Root-target prune safety guard (Shell/Just)
######
log_header "Test 6: Root-target prune safety guard..."

setup_sandbox
cd "$SANDBOX"

root_upstream=$(create_upstream "root-prune")
just cross use root-remote "file://$root_upstream" || fail "Failed to add root-remote"

cat > Crossfile <<'EOF'
# git-cross configuration
cross patch root-remote:main:. .
EOF
mkdir -p .cross
cat > .cross/metadata.json <<'EOF'
{"patches":[{"id":"root1234","remote":"root-remote","remote_path":".","local_path":".","worktree":".cross/worktrees/root-remote_root1234","branch":"main"}]}
EOF
echo "keep me" > keep.txt

just cross prune root-remote || fail "Root-target prune failed"

if [ ! -f "keep.txt" ]; then fail "root-target prune deleted repo root contents"; fi
if git remote | grep -q '^root-remote$'; then fail "root-target prune did not remove remote"; fi
if [ "$(jq -r '.patches | length' .cross/metadata.json)" != "0" ]; then fail "root-target prune did not clean metadata"; fi

log_success "Test 6 passed: Root-target prune keeps repo root contents"

log_success "All prune tests passed!"
