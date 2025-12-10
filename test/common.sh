#!/bin/bash

# Common test helpers

log_header() {
    # Bold Blue
    if [ -t 1 ]; then
        printf "\n\033[1;34m## %s\033[0m\n" "$1"
    else
        printf "\n## %s\n" "$1"
    fi
}

# Ensure just is in PATH
if ! command -v just >/dev/null; then
    if [ -f "$HOME/.cargo/bin/just" ]; then
        export PATH="$HOME/.cargo/bin:$PATH"
    elif [ -f "/opt/homebrew/bin/just" ]; then
        export PATH="/opt/homebrew/bin:$PATH"
    elif [ -f "/usr/local/bin/just" ]; then
        export PATH="/usr/local/bin:$PATH"
    fi
fi

setup_sandbox() {
    basepth="${1:-$(mktemp -d)}"
    cleanup=${2:-true}
    # Create a temp directory
    # Use absolute path to avoid confusion
    export SANDBOX="${basepth}/sandbox"
    
    # Clean up previous run
    if [ "$cleanup" = true ] && [ -d "$SANDBOX" ]; then
        rm -rf "$SANDBOX"
    fi
    mkdir -p "$SANDBOX"
    
    # Copy Justfiles to sandbox
    # We assume we are running from the repo root or test/ directory
    # The run-all.sh runs from repo root.
    REPO_ROOT=$(pwd)
    export REPO_ROOT
    
    cp "$REPO_ROOT/Justfile" "$SANDBOX/"
    cp "$REPO_ROOT/Justfile.cross" "$SANDBOX/"
    
    # Enter sandbox
    cd "$SANDBOX" || exit 1
    
    # Initialize a git repo in sandbox (simulating the local repo)
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test User"
    
    # Commit Justfiles so the repo is clean
    # Commit Justfiles so the repo is clean
    git add Justfile Justfile.cross
    git commit -m "Initial commit" -q || true

    echo $SANDBOX path set.
}

create_upstream() {
    local name=$1
    local path="$SANDBOX/upstream/$name"
    test -d "$path" && { echo $path; return; } || mkdir -p "$path"
    pushd "$path" > /dev/null
        git init -q
        git config user.email "upstream@example.com"
        git config user.name "Upstream User"
        # Idempotent checkout
        if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
            git checkout -b main -q || git checkout -b master -q
        else
            git checkout main -q || git checkout master -q || true
        fi
        
        # Add some content
        echo "Content for $name" > "README.md"
        git add README.md
        git commit -m "Initial upstream commit" -q || true
    popd > /dev/null 

    echo "$path"
}

assert_file_exists() {
    if [ ! -f "$1" ]; then
        pwd
        echo $1
        echo "Assertion failed: File '$SANDBOX/$1' does not exist."
        exit 1
    fi
}

assert_dir_exists() {
    if [ ! -d "$1" ]; then
        echo "Assertion failed: Directory '$SANDBOX/$1' does not exist."
        exit 1
    fi
}

assert_grep() {
    local file=$SANDBOX/$1
    local pattern=$2
    if ! grep -q "$pattern" "$file"; then
        echo "Assertion failed: Pattern '$pattern' not found in '$file'."
        cat "$file"
        exit 1
    fi
}

cleanup() {
    if [ "$CLEANUP" = true ] && [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
        rm -rf "$SANDBOX"
    fi
}
# Trap cleanup on exit
trap cleanup EXIT
