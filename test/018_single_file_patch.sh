#!/usr/bin/env bash

source "$(dirname "$0")/common.sh"

set -euo pipefail

REPO_ROOT=$(pwd)
TEST_BASE=$(mktemp -d)

GO_BIN="$REPO_ROOT/src-go/git-cross-go"
RUST_BIN="$REPO_ROOT/src-rust/target/debug/git-cross-rust"

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

prepare_upstream_file() {
    local path="$1"
    pushd "$path" >/dev/null
        mkdir -p src/lib
        echo "single file v1" > src/lib/lib.txt
        git add src/lib/lib.txt
        git commit -m "Add single file fixture" -q
    popd >/dev/null
}

prepare_second_file() {
    local path="$1"
    local filename="$2"
    local contents="$3"
    pushd "$path" >/dev/null
        mkdir -p src/lib
        echo "$contents" > "src/lib/$filename"
        git add "src/lib/$filename"
        git commit -m "Add $filename" -q
    popd >/dev/null
}

verify_file_absent() {
    local label="$1"
    local file_path="$2"
    if [ -f "$file_path" ]; then
        log_error "$label unexpectedly produced file at $file_path"
        exit 1
    fi
    if [ -d "$file_path" ] && [ -f "$file_path/lib.txt" ]; then
        log_error "$label unexpectedly produced lib.txt inside $file_path"
        exit 1
    fi
    log_success "$label did not create single-file output (unsupported as expected)"
}

run_just_check() {
    log_header "Justfile implementation - single file patch"
    cd "$REPO_ROOT"
    setup_sandbox "$TEST_BASE"
    cd "$SANDBOX"

    upstream_path=$(create_upstream "just-single")
    prepare_upstream_file "$upstream_path"
    upstream_url="file://$upstream_path"

    just cross use repo1 "$upstream_url"
    just cross patch repo1:src/lib/lib.txt vendor/just-single/lib.txt

    if [ ! -f "vendor/just-single/lib.txt" ]; then
        log_error "just cross patch failed to create file"
        exit 1
    fi
    if ! grep -q "single file v1" "vendor/just-single/lib.txt"; then
        log_error "just cross patch wrote unexpected content"
        exit 1
    fi
    assert_grep "Crossfile" "cross patch repo1:main:src/lib/lib.txt vendor/just-single/lib.txt"
    log_success "just cross patch successfully vendored single file"

    prepare_second_file "$upstream_path" "lib2.txt" "single file v2"
    just cross patch repo1:src/lib/lib2.txt vendor/just-single/lib2.txt
    if [ ! -f "vendor/just-single/lib2.txt" ]; then
        log_error "just cross patch failed to create second file"
        exit 1
    fi
    if ! grep -q "single file v2" "vendor/just-single/lib2.txt"; then
        log_error "just cross patch wrote unexpected content for second file"
        exit 1
    fi
    assert_grep "Crossfile" "cross patch repo1:main:src/lib/lib2.txt vendor/just-single/lib2.txt"

    wt_count=$(find .git/cross/worktrees -maxdepth 1 -type d -name 'repo1_*' | wc -l | tr -d ' ')
    if [ "$wt_count" != "1" ]; then
        log_error "Expected single shared worktree for repo1, found $wt_count"
        exit 1
    fi
    log_success "just cross patch reused single worktree for multiple files"
}

run_go_check() {
    log_header "Go CLI implementation - single file patch"
    cd "$REPO_ROOT"
    setup_sandbox "$TEST_BASE"
    cd "$SANDBOX"

    build_go_binary

    upstream_path=$(create_upstream "go-single")
    prepare_upstream_file "$upstream_path"
    upstream_url="file://$upstream_path"

    "$GO_BIN" use repo1 "$upstream_url"
    "$GO_BIN" patch repo1:src/lib/lib.txt vendor/go-single/lib.txt || true

    verify_file_absent "git-cross (Go) patch" "vendor/go-single/lib.txt"
}

run_rust_check() {
    log_header "Rust CLI implementation - single file patch"
    cd "$REPO_ROOT"
    setup_sandbox "$TEST_BASE"
    cd "$SANDBOX"

    build_rust_binary

    upstream_path=$(create_upstream "rust-single")
    prepare_upstream_file "$upstream_path"
    upstream_url="file://$upstream_path"

    "$RUST_BIN" use repo1 "$upstream_url"
    "$RUST_BIN" patch repo1:src/lib/lib.txt vendor/rust-single/lib.txt || true

    verify_file_absent "git-cross-rust patch" "vendor/rust-single/lib.txt"

    upstream_path2=$(create_upstream "rust-single-2")
    prepare_upstream_file "$upstream_path2"
    upstream_url2="file://$upstream_path2"

    "$RUST_BIN" use repo2 "$upstream_url2"
    "$RUST_BIN" patch repo2:src/lib/lib.txt vendor/rust-single/lib2.txt || true

    verify_file_absent "git-cross-rust patch (second repo)" "vendor/rust-single/lib2.txt"
}

run_just_check
run_go_check
run_rust_check

log_header "Summary"
echo "Just implementation supports multi-file patch reuse; Go/Rust pending."

rm -rf "$TEST_BASE"
