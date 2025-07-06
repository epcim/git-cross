#!/bin/bash

# Test Suite for git-cross tool
# This script tests all major functions and edge cases

# Don't exit on errors - let individual tests fail
set +e

# Test configuration
TEST_DIR="/tmp/cross_test_$$"
REMOTE_REPO1="$TEST_DIR/remote1"
REMOTE_REPO2="$TEST_DIR/remote2"
LOCAL_REPO="$TEST_DIR/local"
CROSS_SCRIPT="$(realpath $(dirname "$0")/../cross_fixed.sh)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counter
TESTS_PASSED=0
TESTS_FAILED=0

# Test helper functions
log() {
    echo -e "${GREEN}[TEST]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

test_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((TESTS_PASSED++))
}

test_fail() {
    echo -e "${RED}✗${NC} $1"
    ((TESTS_FAILED++))
}

# Setup test environment
setup_test_env() {
    log "Setting up test environment..."
    
    # Clean up any existing test directory
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    
    # Create test remote repositories
    create_remote_repo "$REMOTE_REPO1" "remote1"
    create_remote_repo "$REMOTE_REPO2" "remote2"
    
    # Create local repository
    mkdir -p "$LOCAL_REPO"
    cd "$LOCAL_REPO"
    git init
    git config user.email "test@example.com"
    git config user.name "Test User"
    
    # Create initial commit
    echo "# Local Repo" > README.md
    git add README.md
    git commit -m "Initial commit"
    
    log "Test environment ready"
}

# Create a test remote repository
create_remote_repo() {
    local repo_dir="$1"
    local name="$2"
    
    mkdir -p "$repo_dir"
    cd "$repo_dir"
    git init --bare
    
    # Create working copy to populate the repo
    local work_dir="${repo_dir}_work"
    git clone "$repo_dir" "$work_dir"
    cd "$work_dir"
    
    git config user.email "test@example.com"
    git config user.name "Test User"
    
    # Create directory structure
    mkdir -p "configs/nginx"
    mkdir -p "scripts/deploy"
    mkdir -p "docs/api"
    
    # Create test files
    echo "server { listen 80; }" > "configs/nginx/default.conf"
    echo "#!/bin/bash\necho 'deploying...'" > "scripts/deploy/deploy.sh"
    echo "# API Documentation" > "docs/api/README.md"
    echo "# Root readme for $name" > "README.md"
    
    chmod +x "scripts/deploy/deploy.sh"
    
    git add .
    git commit -m "Initial structure for $name"
    # Use the current branch name instead of hardcoded master
    git push origin $(git branch --show-current)
    
    # Clean up working copy
    cd ..
    rm -rf "$work_dir"
}

# Test git version check
test_git_version() {
    log "Testing git version requirement..."
    
    local version=$(git --version | grep -o '[0-9]\+\.[0-9]\+' | head -1)
    local major=$(echo $version | cut -d. -f1)
    local minor=$(echo $version | cut -d. -f2)
    
    if [[ $major -gt 2 || ($major -eq 2 && $minor -ge 20) ]]; then
        test_pass "Git version $version meets minimum requirement (2.20)"
    else
        test_fail "Git version $version does not meet minimum requirement (2.20)"
    fi
}

# Test setup function
test_setup() {
    log "Testing setup function..."
    
    cd "$LOCAL_REPO"
    
    # Test setup function directly instead of sourcing (to avoid main execution block)
    if "$CROSS_SCRIPT" setup; then
        test_pass "Setup function executed successfully"
    else
        test_fail "Setup function failed"
    fi
    
    # Check if proper git config was set
    local advice_config=$(git config advice.addEmbeddedRepo 2>/dev/null || echo "not_set")
    local worktree_config=$(git config extensions.worktreeConfig 2>/dev/null || echo "not_set")
    
    if [[ "$advice_config" == "false" ]]; then
        test_pass "advice.addEmbeddedRepo set to false"
    else
        test_fail "advice.addEmbeddedRepo not properly configured"
    fi
    
    if [[ "$worktree_config" == "true" ]]; then
        test_pass "extensions.worktreeConfig set to true"
    else
        test_fail "extensions.worktreeConfig not properly configured"
    fi
}

# Test use function
test_use_function() {
    log "Testing use function..."
    
    cd "$LOCAL_REPO"
    
    # Test adding remote using CLI
    if "$CROSS_SCRIPT" use "testremote1" "$REMOTE_REPO1"; then
        test_pass "Remote 'testremote1' command executed"
    else
        test_fail "Remote 'testremote1' command failed"
    fi
    
    # Check if remote was added
    if git remote | grep -q "testremote1"; then
        test_pass "Remote 'testremote1' added successfully"
    else
        test_fail "Remote 'testremote1' not added"
    fi
    
    # Test adding second remote
    if "$CROSS_SCRIPT" use "testremote2" "$REMOTE_REPO2"; then
        test_pass "Remote 'testremote2' command executed"
    else
        test_fail "Remote 'testremote2' command failed"
    fi
    
    if git remote | grep -q "testremote2"; then
        test_pass "Remote 'testremote2' added successfully"
    else
        test_fail "Remote 'testremote2' not added"
    fi
    
    # Test error handling - missing arguments
    if "$CROSS_SCRIPT" use "incomplete" 2>/dev/null; then
        test_fail "use function should fail with missing URL argument"
    else
        test_pass "use function properly handles missing arguments"
    fi
}

# Test patch function basic functionality
test_patch_basic() {
    log "Testing patch function basic functionality..."
    
    cd "$LOCAL_REPO"
    
    # Setup and use remote via CLI
    "$CROSS_SCRIPT" setup
    "$CROSS_SCRIPT" use "testremote1" "$REMOTE_REPO1"
    
    # Test basic patch
    if "$CROSS_SCRIPT" patch "testremote1:configs/nginx" "local_configs"; then
        test_pass "Patch command executed successfully"
    else
        test_fail "Patch command failed"
    fi
    
    # Check if directory was created
    if [[ -d "local_configs" ]]; then
        test_pass "Patch directory 'local_configs' created"
    else
        test_fail "Patch directory 'local_configs' not created"
    fi
    
    # Check if file exists (sparse checkout preserves directory structure)
    if [[ -f "local_configs/configs/nginx/default.conf" ]]; then
        test_pass "Patch file successfully checked out"
    elif [[ -f "local_configs/default.conf" ]]; then
        test_pass "Patch file successfully checked out"
    else
        test_fail "Patch file not found"
        # Debug: show what's actually in the directory
        echo "Contents of local_configs:" >&2
        find local_configs -type f 2>/dev/null || echo "Directory not found" >&2
    fi
    
    # Check if worktree was created
    if git worktree list | grep -q "local_configs"; then
        test_pass "Git worktree created for patch"
    else
        test_fail "Git worktree not created for patch"
    fi
}

# Test patch function with default path
test_patch_default_path() {
    log "Testing patch function with default path..."
    
    cd "$LOCAL_REPO"
    
    # Setup and use remote via CLI
    "$CROSS_SCRIPT" setup
    "$CROSS_SCRIPT" use "testremote2" "$REMOTE_REPO2"
    
    # Test patch with default path (no local path specified)
    if "$CROSS_SCRIPT" patch "testremote2:scripts/deploy"; then
        test_pass "Patch with default path command executed"
    else
        test_fail "Patch with default path command failed"
    fi
    
    # Check if directory was created with default path
    if [[ -d "scripts/deploy" ]]; then
        test_pass "Patch with default path created correctly"
    else
        test_fail "Patch with default path not created"
    fi
}

# Test patch function error handling
test_patch_errors() {
    log "Testing patch function error handling..."
    
    cd "$LOCAL_REPO"
    
    # Test with non-existent remote
    if "$CROSS_SCRIPT" patch "nonexistent:some/path" 2>/dev/null; then
        test_fail "patch should fail with non-existent remote"
    else
        test_pass "patch properly handles non-existent remote"
    fi
    
    # Test with invalid path format
    if "$CROSS_SCRIPT" patch "invalid_format" 2>/dev/null; then
        test_fail "patch should fail with invalid path format"
    else
        test_pass "patch properly handles invalid path format"
    fi
}

# Test remove function
test_remove_function() {
    log "Testing remove function..."
    
    cd "$LOCAL_REPO"
    
    # Setup and create a patch first via CLI
    "$CROSS_SCRIPT" setup
    "$CROSS_SCRIPT" use "testremote1" "$REMOTE_REPO1"
    "$CROSS_SCRIPT" patch "testremote1:docs/api" "docs_api"
    
    # Verify patch exists
    if [[ -d "docs_api" ]]; then
        test_pass "Patch created for removal test"
    else
        test_fail "Could not create patch for removal test"
        return
    fi
    
    # Test removal via CLI
    if "$CROSS_SCRIPT" remove "docs_api"; then
        test_pass "Remove command executed successfully"
    else
        test_fail "Remove command failed"
    fi
    
    # Check if directory was removed
    if [[ ! -d "docs_api" ]]; then
        test_pass "Patch directory removed successfully"
    else
        test_fail "Patch directory not removed"
    fi
    
    # Check if worktree was removed
    if ! git worktree list | grep -q "docs_api"; then
        test_pass "Git worktree removed successfully"
    else
        test_fail "Git worktree not removed"
    fi
}

# Test Cross file processing
test_cross_file() {
    log "Testing Cross file processing..."
    
    cd "$LOCAL_REPO"
    
    # Create a test Cross file
    cat > Cross << EOF
# Test Cross file
use remote1 $REMOTE_REPO1
use remote2 $REMOTE_REPO2

patch remote1:configs/nginx nginx_configs
patch remote2:scripts/deploy deploy_scripts
EOF
    
    # Execute cross with Cross file
    "$CROSS_SCRIPT" || true
    
    # Check if patches were created
    if [[ -d "nginx_configs" && -d "deploy_scripts" ]]; then
        test_pass "Cross file processed successfully"
    else
        test_fail "Cross file not processed correctly"
    fi
}

# Test utility functions
test_utility_functions() {
    log "Testing utility functions..."
    
    cd "$LOCAL_REPO"
    
    # Clean up any uncommitted worktree additions from previous tests
    git reset --hard HEAD >/dev/null 2>&1 || true
    git clean -fd >/dev/null 2>&1 || true
    
    # Test git status with clean repo (equivalent to repo_is_clean)
    if git diff-index --quiet HEAD --; then
        test_pass "Repository correctly identified as clean"
    else
        test_fail "Repository incorrectly identified as dirty"
    fi
    
    # Test git status with dirty repo
    echo "dirty" > temp_file.txt
    if ! git diff-index --quiet HEAD --; then
        test_pass "Repository correctly identified as dirty"
    else
        test_fail "Repository incorrectly identified as clean"
    fi
    
    # Clean up
    rm -f temp_file.txt
}

# Test edge cases
test_edge_cases() {
    log "Testing edge cases..."
    
    cd "$LOCAL_REPO"
    
    # Test patch with existing directory
    mkdir -p "existing_dir"
    echo "existing content" > "existing_dir/file.txt"
    
    "$CROSS_SCRIPT" setup
    "$CROSS_SCRIPT" use "testremote1" "$REMOTE_REPO1"
    "$CROSS_SCRIPT" patch "testremote1:configs/nginx" "existing_dir"
    
    # Check if original directory was backed up
    if [[ -d "existing_dir.crossed" ]]; then
        test_pass "Existing directory backed up correctly"
    else
        test_fail "Existing directory not backed up"
    fi
    
    # Test duplicate patch (should be skipped)
    local initial_count=$(git worktree list | wc -l)
    "$CROSS_SCRIPT" patch "testremote1:configs/nginx" "existing_dir"
    local final_count=$(git worktree list | wc -l)
    
    if [[ $initial_count -eq $final_count ]]; then
        test_pass "Duplicate patch correctly skipped"
    else
        test_fail "Duplicate patch not skipped"
    fi
}

# Run all tests
run_all_tests() {
    log "Starting git-cross test suite..."
    
    setup_test_env
    
    test_git_version
    test_setup
    test_use_function
    test_patch_basic
    test_patch_default_path
    test_patch_errors
    test_remove_function
    test_cross_file
    test_utility_functions
    test_edge_cases
    
    log "Test suite completed"
    log "Tests passed: $TESTS_PASSED"
    log "Tests failed: $TESTS_FAILED"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        log "All tests passed! ✓"
        return 0
    else
        error "Some tests failed! ✗"
        return 1
    fi
}

# Cleanup function
cleanup() {
    log "Cleaning up test environment..."
    rm -rf "$TEST_DIR"
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap cleanup EXIT
    run_all_tests
fi