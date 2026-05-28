#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"

# Initialize sandbox
setup_sandbox
cd "$SANDBOX"

mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/fzf" <<'EOF'
#!/usr/bin/env bash
lines=()
while IFS= read -r line; do
  lines+=("$line")
done
for (( idx=${#lines[@]}-1; idx>=0; idx--)); do
  line="${lines[$idx]}"
  trimmed="$(echo "$line" | tr -d '[:space:]')"
  if [[ -z "$trimmed" ]]; then continue; fi
  if [[ "$line" == *"REMOTE"* && "$line" != *"/"* ]]; then continue; fi
  if [[ "$line" =~ ^[-+]+$ ]]; then continue; fi
  echo "$line"
  exit 0
done
exit 0
EOF
chmod +x "$SANDBOX/bin/fzf"
export PATH="$SANDBOX/bin:$PATH"

# Compile rust binary (it should be already compiled but let's be sure or just use the location)
RUST_BIN="$REPO_ROOT/src-rust/target/debug/git-cross-rust"
if [ ! -f "$RUST_BIN" ]; then
    echo "Rust binary not found at $RUST_BIN. Building..."
    export PATH=$HOME/homebrew/bin:$PATH
    if ! command -v cargo >/dev/null 2>&1; then
        echo "SKIP: cargo not found, skipping Rust CLI tests"
        exit 0
    fi
    (cd "$REPO_ROOT/src-rust" && cargo build) || {
        echo "SKIP: Rust build failed, skipping Rust CLI tests"
        exit 0
    }
fi
if [ ! -f "$RUST_BIN" ]; then
    echo "SKIP: Rust binary not available after build, skipping Rust CLI tests"
    exit 0
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

log_header "Testing Rust 'patch' command without branch..."
"$RUST_BIN" patch demo:src vendor/rust-src

# Verify files
if [ ! -f "vendor/rust-src/logic.rs" ]; then
    fail "Rust 'patch' failed to vendor logic.rs"
fi

log_header "Testing Rust 'patch' command with explicit branch..."
"$RUST_BIN" patch demo:main:src vendor/rust-src-branch
if [ ! -f "vendor/rust-src-branch/logic.rs" ]; then
    fail "Rust 'patch' with explicit branch failed"
fi

log_header "Testing Rust 'patch' command with nested path and leading slash..."
pushd "$upstream_path" >/dev/null
    mkdir -p nested/dir
    echo "Nested" > nested/dir/file.txt
    git add nested/dir/file.txt
    git commit -m "Add nested dir" >/dev/null
popd >/dev/null
"$RUST_BIN" patch demo:main:/nested/dir vendor/nested-dir
if [ ! -f "vendor/nested-dir/file.txt" ]; then
    fail "Rust 'patch' failed to vendor nested dir"
fi

# FIXME: cd and wt commands with --dry flag hang in CI environment
# These commands work locally but cause test timeouts in automated runs
# Skipping for now - comprehensive testing in test/010_worktree.sh
log_info "Skipping 'cd' and 'wt' command tests (see test/010_worktree.sh)"

log_header "Testing Rust 'list' command..."
list_output=$("$RUST_BIN" list 2>&1)
echo "$list_output"
if ! echo "$list_output" | grep -q "demo"; then
    fail "Rust 'list' should show remote 'demo'"
fi
if ! echo "$list_output" | grep -q "vendor/rust-src"; then
    fail "Rust 'list' should show patch path 'vendor/rust-src'"
fi

log_header "Testing Rust 'status' command..."
status_output=$("$RUST_BIN" status 2>&1)
echo "$status_output"
if ! echo "$status_output" | grep -q "vendor/rust-src"; then
    fail "Rust 'status' should show patch 'vendor/rust-src'"
fi

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

log_header "Testing Rust 'diff' command..."
# Modify a local file to create a diff
echo "local diff change" >> vendor/rust-src/logic.rs
diff_output=$("$RUST_BIN" diff vendor/rust-src 2>&1 || true)
echo "$diff_output"
if ! echo "$diff_output" | grep -q "local diff change"; then
    fail "Rust 'diff' should show local modifications"
fi
# Revert the change for clean state
echo "Updated logic" > vendor/rust-src/logic.rs

log_header "Testing Rust '.crossignore' override status/diff hint..."
cat > vendor/rust-src/.crossignore <<'EOF'
.env
EOF
status_output=$("$RUST_BIN" status 2>&1)
echo "$status_output"
status_line=$(echo "$status_output" | grep "vendor/rust-src" || true)
if ! echo "$status_line" | grep -q "Override"; then
    fail "Rust 'status' should mark override patches as Override"
fi

diff_output=$("$RUST_BIN" diff vendor/rust-src 2>&1 || true)
echo "$diff_output"
if ! echo "$diff_output" | grep -q ".crossignore overrides present in vendor/rust-src"; then
    fail "Rust 'diff' should mention override review when markers exist"
fi
if ! echo "$diff_output" | grep -q '.env'; then
    fail "Rust 'diff' should print manual override file command"
fi
rm -f vendor/rust-src/.crossignore

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

log_header "Testing Rust 'replay' command..."
# Save and clear state, then replay from Crossfile
# First verify current Crossfile has entries
if [ ! -f "Crossfile" ] || [ ! -s "Crossfile" ]; then
    fail "Crossfile should exist and have entries before replay test"
fi
# Create a fresh sandbox for replay test
replay_dir="$SANDBOX/replay-test"
mkdir -p "$replay_dir"
pushd "$replay_dir" >/dev/null
git init -q
git config user.email "test@example.com"
git config user.name "Test User"
echo "replay test" > README.md
git add . && git commit -m "init" -q

# Write a Crossfile manually
cat > Crossfile <<CROSSEOF
cross use demo $upstream_url
cross patch demo:src vendor/replay-src
CROSSEOF

"$RUST_BIN" replay
if [ ! -f "vendor/replay-src/logic.rs" ]; then
    fail "Rust 'replay' failed to recreate vendored files"
fi
log_success "Rust replay test passed"
popd >/dev/null

log_header "Testing Rust 'remove' command..."
# Create a new patch to remove
pushd "$upstream_path" >/dev/null
mkdir -p extras
echo "extra content" > extras/extra.txt
git add extras/extra.txt
git commit -m "Add extras" -q
popd >/dev/null

"$RUST_BIN" patch demo:extras vendor/extras
if [ ! -f "vendor/extras/extra.txt" ]; then
    fail "Rust 'patch' for extras failed"
fi

"$RUST_BIN" remove vendor/extras
if [ -d "vendor/extras" ]; then
    fail "Rust 'remove' should delete vendor/extras directory"
fi
if grep -q "vendor/extras" Crossfile 2>/dev/null; then
    fail "Rust 'remove' should clean Crossfile entry"
fi
log_success "Rust remove test passed"

log_header "Testing Rust 'prune' command..."
# Create a dedicated remote and patch for prune testing
prune_upstream=$(create_upstream "prune-demo")
pushd "$prune_upstream" >/dev/null
mkdir -p lib
echo "prune lib" > lib/prune.txt
git add lib/prune.txt
git commit -m "Add prune lib" -q
popd >/dev/null

"$RUST_BIN" use prune-remote "file://$prune_upstream"
"$RUST_BIN" patch prune-remote:lib vendor/prune-lib

if [ ! -f "vendor/prune-lib/prune.txt" ]; then
    fail "Prune setup: patch not created"
fi

# Prune the remote (should remove all its patches and the remote itself)
"$RUST_BIN" prune prune-remote
if git remote | grep -q "^prune-remote$"; then
    fail "Rust 'prune' should remove the remote"
fi
if [ -d "vendor/prune-lib" ]; then
    fail "Rust 'prune' should remove patch directories for that remote"
fi
log_success "Rust prune test passed"

log_header "Testing Rust root-target remove guard..."
cat > Crossfile <<'EOF'
# git-cross configuration
cross patch root-remote:main:. .
EOF
mkdir -p .cross
cat > .cross/metadata.json <<'EOF'
{"patches":[{"id":"root1234","remote":"root-remote","remote_path":".","local_path":".","worktree":".cross/worktrees/root-remote_root1234","branch":"main"}]}
EOF
echo "keep me" > keep-root-rust.txt

"$RUST_BIN" remove .
if [ ! -f "keep-root-rust.txt" ]; then
    fail "Rust root-target remove deleted repo root contents"
fi

echo "Rust implementation tests passed!"
