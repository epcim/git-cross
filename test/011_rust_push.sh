#!/usr/bin/env bash
source $(dirname "$0")/common.sh

# Initialize sandbox
setup_sandbox
cd "$SANDBOX"

# Rust binary location
export PATH=$HOME/homebrew/bin:$PATH
RUST_CROSS="$REPO_ROOT/src-rust/target/debug/git-cross-rust"

if [ ! -f "$RUST_CROSS" ]; then
    (cd "$REPO_ROOT/src-rust" && cargo build)
fi

# Setup upstream
upstream_path=$(create_upstream "rust-push-demo")
upstream_url="file://$upstream_path"

# Ensure docs directory exists in upstream
pushd "$upstream_path" >/dev/null
mkdir -p docs
echo "Initial Docs" > docs/README.md
git add docs/README.md
git commit -m "Initial docs"
git config receive.denyCurrentBranch ignore
popd >/dev/null

# Use and Patch
$RUST_CROSS use demo "$upstream_url"
$RUST_CROSS patch demo:docs vendor/docs

# Verify initial state
test -f vendor/docs/README.md || fail "vendor/docs/README.md should exist"

echo "## Testing Rust 'push' - Basic..."
echo "Local Change" >> vendor/docs/README.md
git add vendor/docs/README.md
git commit -m "Real local change"

# Push using Rust (non-interactive)
$RUST_CROSS push vendor/docs --yes

# Verify upstream
pushd "$upstream_path" >/dev/null
last_msg=$(git log -1 --pretty=%s)
if [[ "$last_msg" != "Real local change" ]]; then
    fail "Expected upstream msg 'Real local change', got '$last_msg'"
fi
popd >/dev/null

echo "## Testing Rust 'push' - Custom message and branch..."
echo "Another Change" >> vendor/docs/README.md
git add vendor/docs/README.md
git commit -m "This should be overwritten"

$RUST_CROSS push vendor/docs --yes --message "Custom Push Msg" --branch "feature/rust-x"

pushd "$upstream_path" >/dev/null
if ! git rev-parse --verify feature/rust-x >/dev/null 2>&1; then
    fail "Branch 'feature/rust-x' not found on upstream"
fi
last_msg=$(git log -1 feature/rust-x --pretty=%s)
if [[ "$last_msg" != "Custom Push Msg" ]]; then
    fail "Expected 'Custom Push Msg' on feature/rust-x, got '$last_msg'"
fi
popd >/dev/null

echo "Rust push tests passed!"
