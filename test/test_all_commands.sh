#!/bin/bash
set -e
export PATH="$HOME/bin:$HOME/homebrew/bin:$PATH"

# Setup test environment
set -e
TEST_DIR="$(pwd)/test_run_$(date +%s)"
mkdir -p "$TEST_DIR"
if [ -z "$TEST_DIR" ] || [ "$TEST_DIR" = "$HOME" ]; then
    echo "Error: Unsafe TEST_DIR: $TEST_DIR"
    exit 1
fi
echo "Running tests in $TEST_DIR"
cd "$TEST_DIR"

# Mock git config
export GIT_CONFIG_GLOBAL=$(pwd)/gitconfig
cat <<EOF > gitconfig
[user]
    name = Test User
    email = test@example.com
[commit]
    gpgsign = false
[init]
    defaultBranch = master
EOF

# Function to create a mock remote
create_mock_remote() {
    local name="$1"
    local path="$2"
    
    mkdir -p "remotes/$name"
    pushd "remotes/$name" > /dev/null
    git init --bare > /dev/null
    
    # Create a temp clone to push content
    local tmp_clone="../../tmp_clone_$name"
    git clone . "$tmp_clone" > /dev/null 2>&1
    pushd "$tmp_clone" > /dev/null
    
    # Create content
    mkdir -p "$path"
    echo "Content for $name:$path" > "$path/file.txt"
    git add .
    git commit -m "Initial content for $path" > /dev/null 2>&1
    git push origin master > /dev/null 2>&1
    
    popd > /dev/null
    rm -rf "$tmp_clone"
    popd > /dev/null
    
    echo "$(pwd)/remotes/$name"
}

# Function to update mock remote
update_mock_remote() {
    local name="$1"
    local path="$2"
    local message="$3"
    
    local tmp_clone="tmp_update_$name"
    git clone "remotes/$name" "$tmp_clone" > /dev/null 2>&1
    pushd "$tmp_clone" > /dev/null
    
    echo "$message" >> "$path/file.txt"
    git add .
    git commit -m "$message" > /dev/null 2>&1
    git push origin master > /dev/null 2>&1
    
    popd > /dev/null
    rm -rf "$tmp_clone"
}

# Setup mock remotes
echo "Setting up mock remotes..."
DEMO_URL=$(create_mock_remote "demo" "docs")

# Setup main repo
mkdir main-repo
cd main-repo
git init > /dev/null
cp ../../Justfile .

echo "---------------------------------------------------"
echo "Test 1: Basic patch"
just use demo "$DEMO_URL"
just patch demo:docs vendor/docs

# Define helper since this script doesn't source test_helpers.sh fully or we want to use the one we added?
# Actually test_all_commands.sh does NOT source test_helpers.sh. It has its own setup.
# So I should add assert_file_contains to it or just use grep.
if ! grep -qF "cross use demo $DEMO_URL" Crossfile; then echo "Missing cross use"; exit 1; fi
if ! grep -qF "cross patch demo:docs vendor/docs" Crossfile; then echo "Missing cross patch"; exit 1; fi

if [ -f "vendor/docs/file.txt" ]; then
    echo "PASS: vendor/docs/file.txt exists"
else
    echo "FAIL: vendor/docs/file.txt missing"
    exit 1
fi

echo "---------------------------------------------------"
echo "Test 2: Sync updates from upstream"

# Update the remote
cd ..
update_mock_remote "demo" "docs" "Updated content"
cd main-repo

# Record current content
BEFORE=$(cat vendor/docs/file.txt)

# Sync pulls updates into hidden worktree
just sync > /dev/null 2>&1 || echo "Sync completed (may have warnings)"

# Verify the hidden worktree was updated
HASH=$(echo "docs" | md5sum | cut -d' ' -f1)
WT=".git/cross/worktrees/demo_$HASH"

if grep -q "Updated content" "$WT/docs/file.txt"; then
    echo "PASS: Sync updated hidden worktree"
else
    echo "FAIL: Sync did not update hidden worktree"
    exit 1
fi

# Re-run patch to update visible files from updated worktree
just patch demo:docs vendor/docs > /dev/null

# Check if visible files were updated
if grep -q "Updated content" vendor/docs/file.txt; then
    echo "PASS: Patch synced updated files to visible directory"
else
    echo "FAIL: Visible files not updated after patch"
    exit 1
fi

echo "---------------------------------------------------"
echo "Test 3: Diff local vs upstream"

# Make a local change
echo "Local modification" >> vendor/docs/file.txt

# Diff should show the change
if just diff demo:docs vendor/docs 2>&1 | grep -q "Local modification"; then
    echo "PASS: Diff detected local changes"
else
    echo "FAIL: Diff did not detect changes"
    exit 1
fi

echo "---------------------------------------------------"
echo "Test 4: Push Upstream"
echo "---------------------------------------------------"

# Make a change in local vendor directory
echo "Another change" >> vendor/docs/file.txt

# Run push-upstream (simulate 'r' for Run)
# We need to simulate the interactive input and avoid editor blocking
export GIT_EDITOR="echo 'Test commit' >"
echo "r" | just push-upstream demo:docs vendor/docs
unset GIT_EDITOR

# Define paths
MAIN_REPO_DIR="$TEST_DIR/main-repo"
MOCK_REMOTE_DIR="$TEST_DIR/remotes/demo"

# Verify change was pushed to upstream
# We can check the mock remote (bare repo)
echo "Debug: MOCK_REMOTE_DIR='$MOCK_REMOTE_DIR'"
cd "$MOCK_REMOTE_DIR"
echo "Debug: In $(pwd)"
ls -F
if git --git-dir=. log master --oneline | grep -q "Test commit"; then
    echo "PASS: Push-upstream committed and pushed changes"
else
    echo "FAIL: Push-upstream failed to push changes"
    exit 1
fi
cd "$MAIN_REPO_DIR"

echo "---------------------------------------------------"
echo "Test 4b: Push Upstream (Inferred Arguments)"
echo "---------------------------------------------------"

# Make another change
echo "Inferred change" >> vendor/docs/file.txt

# Run push-upstream from within the directory
cd vendor/docs
export GIT_EDITOR="echo 'Inferred commit' >"
echo "r" | just push-upstream
unset GIT_EDITOR
cd ../..

# Verify
cd "$MOCK_REMOTE_DIR"
if git log master --oneline | grep -q "Inferred commit"; then
    echo "PASS: Push-upstream (inferred) succeeded"
else
    echo "FAIL: Push-upstream (inferred) failed"
    exit 1
fi
cd "$MAIN_REPO_DIR"

echo "---------------------------------------------------"
echo "Test 5: Sync with dirty worktree (Stash/Pop)"
echo "---------------------------------------------------"

# Create a dirty state in the hidden worktree
# We need to find the worktree path first
WT_PATH=$(find .git/cross/worktrees -maxdepth 1 -type d -name "demo_*" | head -n 1)
echo "Dirty" > "$WT_PATH/dirty_file.txt"

# Update upstream
cd "$MAIN_REPO_DIR/.."
update_mock_remote "demo" "docs" "Upstream update 2"
cd "$MAIN_REPO_DIR"

# Run sync
just sync > /dev/null 2>&1

# Verify sync succeeded and dirty file remains
if grep -q "Upstream update 2" "$WT_PATH/docs/file.txt"; then
    echo "PASS: Sync updated worktree"
else
    echo "FAIL: Sync failed to update worktree"
    exit 1
fi

if [ -f "$WT_PATH/dirty_file.txt" ]; then
    echo "PASS: Dirty file preserved (Stash/Pop worked)"
else
    echo "FAIL: Dirty file lost"
    exit 1
fi

echo "---------------------------------------------------"
echo "Test 6: List and Status commands"
echo "---------------------------------------------------"

# Run list command
echo "Testing 'list'..."
if just list | grep -q "demo"; then
    echo "PASS: List command output contains remote"
else
    echo "FAIL: List command failed"
    exit 1
fi

# Run status command
echo "Testing 'status'..."
# We expect "Clean" or "Modified" depending on previous tests
if just status | grep -q "vendor/docs"; then
    echo "PASS: Status command output contains local path"
else
    echo "FAIL: Status command failed"
    exit 1
fi

echo "---------------------------------------------------"
echo "All extended tests passed!"
exit 0
