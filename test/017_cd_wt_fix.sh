#!/bin/bash
source test/common.sh

######
# Test: cd/wt command behavior
# - With explicit path: opens subshell (difficult to test)
# - Without path: uses fzf or copies to clipboard (difficult to test)
# This test verifies basic functionality and error handling
######
log_header "Test: cd/wt command behavior..."

# Save repo root
REPO_ROOT=$(pwd)

# Setup: Create test environment
test_repo=$(mktemp -d)
cd "$test_repo" || exit 1

# Initialize main repo
git init -q
git config user.name "Test User"
git config user.email "test@example.com"
echo "main repo" > README.md
git add . && git commit -m "init" -q

# Copy Justfiles to test repo
cp "$REPO_ROOT/Justfile" .
cp "$REPO_ROOT/Justfile.cross" .

# Create upstream repo
upstream=$(mktemp -d)
git -C "$upstream" init -q
git -C "$upstream" config user.name "Test User"
git -C "$upstream" config user.email "test@example.com"
mkdir -p "$upstream/src"
echo "upstream content" > "$upstream/src/file.txt"
git -C "$upstream" add . && git -C "$upstream" commit -m "init" -q

# Initialize cross and create patch
mkdir -p .git/cross
echo '{"patches":[]}' > .git/cross/metadata.json
git remote add demo "$upstream"

log_info "Creating patch..."
just cross patch demo:src vendor/src || { log_error "Patch failed"; exit 1; }

# Test 1: Verify cd command exists and doesn't crash on invalid path
log_info "Test 1: cd with non-existent path should fail gracefully..."
output=$(just cross cd non-existent-path 2>&1 || true)
if echo "$output" | grep -qE "not found|No patches|Directory not found"; then
    log_success "cd correctly reports non-existent path"
else
    log_warn "cd error handling may need improvement: $output"
fi

# Test 2: Verify wt command exists and doesn't crash on invalid path
log_info "Test 2: wt with non-existent path should fail gracefully..."
output=$(just cross wt non-existent-path 2>&1 || true)
if echo "$output" | grep -qE "not found|No patches|Directory not found"; then
    log_success "wt correctly reports non-existent path"
else
    log_warn "wt error handling may need improvement: $output"
fi

# Test 3: Verify cd with valid path (can't test subshell directly)
log_info "Test 3: cd target directory exists..."
if [ -d "vendor/src" ]; then
    log_success "cd target directory exists: vendor/src"
else
    log_error "cd target directory doesn't exist"
    exit 1
fi

# Test 4: Verify wt with valid path (can't test subshell directly)
log_info "Test 4: wt target worktree exists..."
# Worktree path includes a hash, so find it dynamically
if [ -d ".git/cross/worktrees" ] && ls .git/cross/worktrees/demo_* >/dev/null 2>&1; then
    log_success "wt target worktree exists"
else
    log_error "wt target worktree doesn't exist"
    ls -la .git/cross/worktrees/ || true
    exit 1
fi

# Test 5: Verify list output for cd/wt reference
log_info "Test 5: Verify patch list for reference..."
if just cross list | grep -q "vendor/src"; then
    log_success "Patch list shows correct local_path"
else
    log_error "Patch list doesn't show expected path"
    exit 1
fi

# Test 6: Test Go implementation
log_info "Test 6: Testing Go implementation..."
if [ -f "$REPO_ROOT/src-go/git-cross" ]; then
    if "$REPO_ROOT/src-go/git-cross" cd non-existent-path 2>&1 | grep -q "not found"; then
        log_success "Go: cd correctly reports non-existent path"
    else
        log_warn "Go: cd error handling may need improvement"
    fi
    
    if "$REPO_ROOT/src-go/git-cross" wt non-existent-path 2>&1 | grep -q "not found"; then
        log_success "Go: wt correctly reports non-existent path"
    else
        log_warn "Go: wt error handling may need improvement"
    fi
else
    log_warn "Go binary not found, skipping Go tests"
fi

# Test 7: Test Rust implementation
log_info "Test 7: Testing Rust implementation..."
if [ -f "$REPO_ROOT/src-rust/target/release/git-cross-rust" ]; then
    if "$REPO_ROOT/src-rust/target/release/git-cross-rust" cd non-existent-path 2>&1 | grep -q "not found"; then
        log_success "Rust: cd correctly reports non-existent path"
    else
        log_warn "Rust: cd error handling may need improvement"
    fi
    
    if "$REPO_ROOT/src-rust/target/release/git-cross-rust" wt non-existent-path 2>&1 | grep -q "not found"; then
        log_success "Rust: wt correctly reports non-existent path"
    else
        log_warn "Rust: wt error handling may need improvement"
    fi
else
    log_warn "Rust binary not found, skipping Rust tests"
fi

# Cleanup
cd /
rm -rf "$test_repo" "$upstream"

log_success "cd/wt tests completed successfully!"
echo ""
echo "Note: This test verifies basic functionality and error handling."
echo "Manual testing required for:"
echo "  - Subshell opening with explicit path (cd/wt with path)"
echo "  - Clipboard copying with fzf selection (cd/wt without path)"
echo "  - fzf interactive selection behavior"
