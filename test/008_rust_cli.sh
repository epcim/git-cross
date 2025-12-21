#!/usr/bin/env bash
source $(dirname "$0")/common.sh

# Initialize sandbox
setup_sandbox
cd "$SANDBOX"

# Compile rust binary (it should be already compiled but let's be sure or just use the location)
RUST_BIN="$REPO_ROOT/target/debug/git-cross"
if [ ! -f "$RUST_BIN" ]; then
    echo "Rust binary not found at $RUST_BIN. Building..."
    export PATH=$HOME/homebrew/bin:$PATH
    (cd "$REPO_ROOT" && cargo build)
fi

# Setup upstream
upstream_path=$(create_upstream "rust-demo")
upstream_url="file://$upstream_path"

# Prepare some content in upstream
pushd "$upstream_path" >/dev/null
mkdir -p src
echo "Rust logic" > src/logic.rs
git add src/logic.rs
git commit -m "Add rust logic"
popd >/dev/null

log_header "Testing Rust 'use' command..."
"$RUST_BIN" use demo "$upstream_url"

# Verify remote
if ! git remote | grep -q "^demo$"; then
    fail "Rust 'use' failed to add remote 'demo'"
fi

log_header "Testing Rust 'patch' command..."
"$RUST_BIN" patch demo:src vendor/rust-src

# Verify files
if [ ! -f "vendor/rust-src/logic.rs" ]; then
    fail "Rust 'patch' failed to vendor logic.rs"
fi

log_header "Testing Rust 'list' command..."
"$RUST_BIN" list

log_header "Testing Rust 'status' command..."
"$RUST_BIN" status

log_header "Testing Rust 'sync' command..."
# Mock upstream change
pushd "$upstream_path" >/dev/null
echo "Updated logic" > src/logic.rs
git add src/logic.rs
git commit -m "Update rust logic"
popd >/dev/null

"$RUST_BIN" sync
if ! grep -q "Updated logic" "vendor/rust-src/logic.rs"; then
    fail "Rust 'sync' failed to pull updates"
fi

log_header "Testing Rust 'replay' command..."
rm -rf vendor/rust-src
# We need to clean up worktree metadata or just rely on replay to find it
# Replay should recreate it if missing.
"$RUST_BIN" replay
if [ ! -f "vendor/rust-src/logic.rs" ]; then
    fail "Rust 'replay' failed to restore vendor directory"
fi

echo "Rust implementation tests passed!"
