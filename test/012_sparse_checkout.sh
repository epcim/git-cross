#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

setup_sandbox
cd "$SANDBOX"

# Create upstream with a root file and a sub-folder
upstream_path=$(create_upstream "sparse-upstream")
upstream_url="file://$upstream_path"

pushd "$upstream_path" >/dev/null
echo "root-file" > root.txt
mkdir -p apps/app1
echo "app1-file" > apps/app1/data.txt
git add .
git commit -m "Initial commit" >/dev/null
popd >/dev/null

# Test using Just/Fish implementation
log_header "Testing sparse checkout in Just/Fish"
just cross use demo "$upstream_url"
just cross patch demo:apps/app1 vendor/app1

wt_path=$(find .cross/worktrees -maxdepth 1 -name "demo_*" | head -n 1)
if [ -z "$wt_path" ]; then
    fail "Worktree not found"
fi

echo "Checking files in worktree: $wt_path"
# root.txt should NOT be present if sparse-checkout is working
if [ -f "$wt_path/root.txt" ]; then
    fail "root.txt found in worktree! Sparse checkout failed for Just/Fish."
fi

# Clean up for next implementation
rm -rf vendor/app1 .cross/worktrees/* .git/worktrees/* Crossfile

# Test using Go implementation
log_header "Testing sparse checkout in Go"
GO_BIN="$REPO_ROOT/src-go/git-cross-go"
if [ ! -f "$GO_BIN" ]; then
    (cd "$REPO_ROOT/src-go" && CGO_ENABLED=0 go build -o "$GO_BIN" main.go)
fi
if ! "$GO_BIN" --version >/dev/null 2>&1; then
    log_warn "Go binary not working on this platform, skipping Go sparse checkout test"
else
    "$GO_BIN" init
    "$GO_BIN" use demo "$upstream_url"
    "$GO_BIN" patch demo:apps/app1 vendor/app1

    wt_path=$(find .cross/worktrees -maxdepth 1 -name "demo_*" | head -n 1)
    if [ -f "$wt_path/root.txt" ]; then
        fail "root.txt found in worktree! Sparse checkout failed for Go."
    fi
fi

# Clean up
rm -rf vendor/app1 .cross/worktrees/* .git/worktrees/* Crossfile

# Test using Rust implementation
log_header "Testing sparse checkout in Rust"
RUST_BIN="$REPO_ROOT/src-rust/target/debug/git-cross-rust"
if [ ! -f "$RUST_BIN" ]; then
    if command -v cargo >/dev/null 2>&1; then
        cargo build --manifest-path "$REPO_ROOT/src-rust/Cargo.toml" || true
    fi
fi
if [ -f "$RUST_BIN" ]; then
    "$RUST_BIN" init
    "$RUST_BIN" use demo "$upstream_url"
    "$RUST_BIN" patch demo:apps/app1 vendor/app1

    wt_path=$(find .cross/worktrees -maxdepth 1 -name "demo_*" | head -n 1)
    if [ -f "$wt_path/root.txt" ]; then
        fail "root.txt found in worktree! Sparse checkout failed for Rust."
    fi
else
    log_warn "Rust binary not available, skipping Rust sparse checkout test"
fi

echo "Sparse checkout validation passed!"
