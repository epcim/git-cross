#!/bin/bash
# Test helper functions for git-cross tests

# Setup test environment
setup_test_env() {
    export PATH="$HOME/bin:$HOME/homebrew/bin:$PATH"
    TEST_DIR="$(pwd)/test_run_$(date +%s)"
    mkdir -p "$TEST_DIR"
    
    if [ -z "$TEST_DIR" ] || [ "$TEST_DIR" = "$HOME" ]; then
        echo "Error: Unsafe TEST_DIR: $TEST_DIR"
        exit 1
    fi
    
    echo "Running test in $TEST_DIR"
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
}

# Create a mock remote repository
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

# Update mock remote with new content
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

# Setup main test repo
setup_main_repo() {
    mkdir main-repo
    cd main-repo
    git init > /dev/null
    cp ../../Justfile .
}

# Cleanup test environment
cleanup_test_env() {
    if [ -n "$TEST_DIR" ] && [ "$TEST_DIR" != "$HOME" ]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# Assert file contains string
assert_file_contains() {
    local file="$1"
    local content="$2"
    
    if ! grep -qF "$content" "$file"; then
        echo "❌ File '$file' missing content: '$content'"
        echo "File content:"
        cat "$file"
        return 1
    fi
}
