#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"

REPO_ROOT=$(pwd)
TEST_BASE=$(mktemp -d)

GO_BIN="$REPO_ROOT/src-go/git-cross-go"
RUST_BIN="$REPO_ROOT/src-rust/target/debug/git-cross-rust"

compute_crossdir() {
    local git_dir
    pushd "$REPO_ROOT" >/dev/null
        git_dir=$(git rev-parse --path-format=absolute --git-dir)
        if [ -f "$git_dir/commondir" ]; then
            local rel
            rel=$(cat "$git_dir/commondir")
            pushd "$git_dir" >/dev/null
                git_dir=$(cd "$rel" && pwd)
            popd >/dev/null
        fi
    popd >/dev/null
    printf "%s/cross" "$git_dir"
}

build_go_binary() {
    if [ ! -x "$GO_BIN" ]; then
        log_info "Building Go binary at $GO_BIN"
        (cd "$REPO_ROOT/src-go" && go build -o git-cross-go main.go)
    fi
}

build_rust_binary() {
    if [ ! -x "$RUST_BIN" ]; then
        log_info "Building Rust binary at $RUST_BIN"
        (cd "$REPO_ROOT/src-rust" && cargo build >/dev/null)
    fi
}

prepare_upstream_repo() {
    local repo_name=$1
    local fixture_text=$2

    local path
    path=$(create_upstream "$repo_name")

    pushd "$path" >/dev/null
        mkdir -p src/lib
        echo "$fixture_text" > src/lib/lib.txt
        git add src/lib/lib.txt
        git commit -m "Add worktree patch fixture" -q
    popd >/dev/null

    echo "$path"
}

assert_cross_metadata_present() {
    local description=$1
    local crossdir
    crossdir=$(compute_crossdir)

    if [ ! -f "$crossdir/metadata.json" ]; then
        log_error "$description: expected $crossdir/metadata.json to exist"
        exit 1
    fi
}

cleanup_worktree_dir() {
    local worktree_path=$1
    if [ -d "$worktree_path" ]; then
        git worktree remove -f "$worktree_path" >/dev/null 2>&1 || true
        rm -rf "$worktree_path"
    fi
}

run_just_patch_in_worktree() {
    log_header "Justfile implementation - patch inside independent git worktree"

    setup_sandbox "$TEST_BASE"
    cd "$SANDBOX"

    local upstream_path upstream_url worktree_path branch
    upstream_path=$(prepare_upstream_repo "worktree-just" "just worktree fixture")
    upstream_url="file://$upstream_path"
    branch="featA"

    if git show-ref --verify --quiet "refs/heads/$branch"; then
        git branch -f "$branch" >/dev/null
    else
        git branch "$branch" >/dev/null
    fi
    worktree_path="${SANDBOX}-${branch}"
    cleanup_worktree_dir "$worktree_path"
    git worktree add "$worktree_path" "$branch" >/dev/null

    pushd "$worktree_path" >/dev/null
        just cross use repo1 "$upstream_url"
        just cross patch repo1:src/lib vendor/worktree-lib

        if [ ! -f "vendor/worktree-lib/lib.txt" ]; then
            log_error "Just implementation: vendor/worktree-lib/lib.txt missing"
            exit 1
        fi

        if ! grep -q "just worktree fixture" "vendor/worktree-lib/lib.txt"; then
            log_error "Just implementation: lib.txt content mismatch"
            exit 1
        fi

        if ! grep -q "cross patch repo1:main:src/lib vendor/worktree-lib" Crossfile; then
            log_error "Just implementation: Crossfile missing patch entry"
            exit 1
        fi

        assert_cross_metadata_present "Just implementation"
    popd >/dev/null

    cleanup_worktree_dir "$worktree_path"
    log_success "Just implementation handled git worktree patch"
    cd "$REPO_ROOT"
}

run_go_patch_in_worktree() {
    log_header "Go implementation - patch inside independent git worktree"

    setup_sandbox "$TEST_BASE"
    cd "$SANDBOX"

    build_go_binary

    local upstream_path upstream_url worktree_path branch
    upstream_path=$(prepare_upstream_repo "worktree-go" "go worktree fixture")
    upstream_url="file://$upstream_path"
    branch="featA"

    if git show-ref --verify --quiet "refs/heads/$branch"; then
        git branch -f "$branch" >/dev/null
    else
        git branch "$branch" >/dev/null
    fi
    worktree_path="${SANDBOX}-${branch}"
    cleanup_worktree_dir "$worktree_path"
    git worktree add "$worktree_path" "$branch" >/dev/null

    pushd "$worktree_path" >/dev/null
        crossdir="$(compute_crossdir)"
        metadata="$crossdir/metadata.json"
        CROSSDIR="$crossdir" METADATA="$metadata" "$GO_BIN" use repo1 "$upstream_url"
        CROSSDIR="$crossdir" METADATA="$metadata" "$GO_BIN" patch repo1:src/lib vendor/worktree-lib

        if [ ! -f "vendor/worktree-lib/lib.txt" ]; then
            log_error "Go implementation: vendor/worktree-lib/lib.txt missing"
            exit 1
        fi

        if ! grep -q "go worktree fixture" "vendor/worktree-lib/lib.txt"; then
            log_error "Go implementation: lib.txt content mismatch"
            exit 1
        fi

        if ! grep -q "cross patch repo1:main:src/lib vendor/worktree-lib" Crossfile; then
            log_error "Go implementation: Crossfile missing patch entry"
            exit 1
        fi

        assert_cross_metadata_present "Go implementation"
    popd >/dev/null

    cleanup_worktree_dir "$worktree_path"
    log_success "Go implementation handled git worktree patch"
    cd "$REPO_ROOT"
}

run_rust_patch_in_worktree() {
    log_header "Rust implementation - patch inside independent git worktree"

    setup_sandbox "$TEST_BASE"
    cd "$SANDBOX"

    build_rust_binary

    local upstream_path upstream_url worktree_path branch
    upstream_path=$(prepare_upstream_repo "worktree-rust" "rust worktree fixture")
    upstream_url="file://$upstream_path"
    branch="featA"

    if git show-ref --verify --quiet "refs/heads/$branch"; then
        git branch -f "$branch" >/dev/null
    else
        git branch "$branch" >/dev/null
    fi
    worktree_path="${SANDBOX}-${branch}"
    cleanup_worktree_dir "$worktree_path"
    git worktree add "$worktree_path" "$branch" >/dev/null

    pushd "$worktree_path" >/dev/null
        crossdir="$(compute_crossdir)"
        metadata="$crossdir/metadata.json"
        CROSSDIR="$crossdir" METADATA="$metadata" "$RUST_BIN" use repo1 "$upstream_url"
        CROSSDIR="$crossdir" METADATA="$metadata" "$RUST_BIN" patch repo1:src/lib vendor/worktree-lib

        if [ ! -f "vendor/worktree-lib/lib.txt" ]; then
            log_error "Rust implementation: vendor/worktree-lib/lib.txt missing"
            exit 1
        fi

        if ! grep -q "rust worktree fixture" "vendor/worktree-lib/lib.txt"; then
            log_error "Rust implementation: lib.txt content mismatch"
            exit 1
        fi

        if ! grep -q "cross patch repo1:main:src/lib vendor/worktree-lib" Crossfile; then
            log_error "Rust implementation: Crossfile missing patch entry"
            exit 1
        fi

        assert_cross_metadata_present "Rust implementation"
    popd >/dev/null

    cleanup_worktree_dir "$worktree_path"
    log_success "Rust implementation handled git worktree patch"
    cd "$REPO_ROOT"
}

run_just_patch_in_worktree
run_go_patch_in_worktree
run_rust_patch_in_worktree

log_header "019_patch_worktree completed"
rm -rf "$TEST_BASE"
