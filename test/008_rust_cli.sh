#!/usr/bin/env bash
source $(dirname "$0")/common.sh

# Initialize sandbox
setup_sandbox
cd "$SANDBOX"

# Compile rust binary (it should be already compiled but let's be sure or just use the location)
RUST_BIN="$REPO_ROOT/src-rust/target/debug/git-cross-rust"
if [ ! -f "$RUST_BIN" ]; then
    echo "Rust binary not found at $RUST_BIN. Building..."
    export PATH=$HOME/homebrew/bin:$PATH
    (cd "$REPO_ROOT/src-rust" && cargo build)
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

log_header "Testing Rust 'push' command..."
# Allow pushing to current branch in mock upstream
pushd "$upstream_path" >/dev/null
git config receive.denyCurrentBranch ignore
popd >/dev/null

echo "Local modification" >> vendor/rust-src/logic.rs
git add vendor/rust-src/logic.rs
git commit -m "Local rust change"

"$RUST_BIN" push vendor/rust-src --yes
last_msg=$(git -C "$upstream_path" log -1 --pretty=%s)
if [[ "$last_msg" != "Local rust change" ]]; then
    fail "Rust 'push' failed. Expected 'Local rust change', got '$last_msg'"
fi

log_header "Testing Rust 'init' command..."
mkdir -p init-test
pushd init-test >/dev/null
"$RUST_BIN" init
if [ ! -f "Crossfile" ]; then
    fail "Rust 'init' failed to create Crossfile"
fi
popd >/dev/null

echo "Rust implementation tests passed!"
