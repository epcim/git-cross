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

log_success() {
    # Green
    if [ -t 1 ]; then
        printf "\033[0;32m✓ %s\033[0m\n" "$1"
    else
        printf "✓ %s\n" "$1"
    fi
}

log_error() {
    # Red
    if [ -t 1 ]; then
        printf "\033[0;31m✗ %s\033[0m\n" "$1" >&2
    else
        printf "✗ %s\n" "$1" >&2
    fi
}

log_warn() {
    # Yellow
    if [ -t 1 ]; then
        printf "\033[0;33m⚠ %s\033[0m\n" "$1"
    else
        printf "⚠ %s\n" "$1"
    fi
}

log_info() {
    # Cyan
    if [ -t 1 ]; then
        printf "\033[0;36m→ %s\033[0m\n" "$1"
    else
        printf "→ %s\n" "$1"
    fi
}

# Ensure just is in PATH
fail() {
    echo -e "\033[0;31mFAIL: $1\033[0m"
    exit 1
}

if ! command -v just >/dev/null; then # PATH adjustment for development environments
    for p in "$HOME/.cargo/bin" "$HOME/homebrew/bin" "/opt/homebrew/bin" "/usr/local/bin"; do
        if [ -d "$p" ]; then
            export PATH="$p:$PATH"
        fi
    done
fi

# Justfile.cross requires SHELL; direct `bash test/NNN.sh` invocations may not
# inherit it (run-all.sh is normally launched from a login shell or `just`).
export SHELL="${SHELL:-/bin/bash}"

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

# Assert that a string (usually captured command output) contains a literal
# substring. Keeps multiline output out of grep's argument parsing.
assert_contains() {
    local haystack=$1
    local needle=$2
    local message=${3:-"expected output to contain: $needle"}
    if ! printf '%s' "$haystack" | grep -qF -- "$needle"; then
        log_error "$message"
        printf '%s\n' "$haystack" >&2
        exit 1
    fi
}

# Assert that a string does NOT contain a literal substring.
assert_not_contains() {
    local haystack=$1
    local needle=$2
    local message=${3:-"expected output to NOT contain: $needle"}
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        log_error "$message"
        printf '%s\n' "$haystack" >&2
        exit 1
    fi
}

# Build (or reuse) the Go CLI and print its path on stdout.
# Prints nothing when Go is unavailable or the binary cannot run, so callers
# can skip Go-specific assertions (same pattern as test/009_go_cli.sh).
ensure_go_bin() {
    local repo_root=${1:-${REPO_ROOT:-$(pwd)}}
    local go_bin="$repo_root/src-go/git-cross-go"
    # Rebuild when the source is newer than the cached binary.
    if [ -f "$go_bin" ] && [ "$repo_root/src-go/main.go" -nt "$go_bin" ]; then
        rm -f "$go_bin"
    fi
    if [ ! -f "$go_bin" ]; then
        if ! command -v go >/dev/null 2>&1; then
            return 0
        fi
        # A stale vendor dir breaks `go build -mod=mod` (inconsistent vendoring).
        rm -rf "$repo_root/src-go/vendor" 2>/dev/null || true
        ( cd "$repo_root/src-go" && CGO_ENABLED=0 go build -mod=mod -tags purego -o git-cross-go main.go ) >/dev/null 2>&1 || return 0
    fi
    if ! "$go_bin" --version >/dev/null 2>&1 && ! "$go_bin" --help >/dev/null 2>&1; then
        return 0
    fi
    printf '%s\n' "$go_bin"
}

# Print a PATH equivalent to the current one with no `fzf` resolvable.
#
# A symlink farm is used because a directory cannot "hide" a binary that lives
# in another PATH entry. This makes the "fzf is not installed" fallbacks
# testable deterministically, even on hosts/CI images that ship fzf.
make_path_without_fzf() {
    local farm=$1
    local IFS=:
    local dir entry base
    if [ -z "$farm" ]; then
        return 1
    fi
    mkdir -p "$farm"
    for dir in $PATH; do
        [ -d "$dir" ] || continue
        [ "$dir" = "$farm" ] && continue
        for entry in "$dir"/*; do
            [ -f "$entry" ] && [ -x "$entry" ] || continue
            base=${entry##*/}
            [ "$base" = "fzf" ] && continue
            [ -e "$farm/$base" ] && continue
            ln -s "$entry" "$farm/$base" 2>/dev/null || true
        done
    done
    printf '%s\n' "$farm"
}

cleanup() {
    if [ "${CLEANUP:-true}" = true ] && [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
        rm -rf "$SANDBOX"
    fi
}
# Trap cleanup on exit
trap cleanup EXIT
