#!/usr/bin/env bash
set -euo pipefail

# Source 002 to setup environment and run 'patch' tests
# Use CLEANUP=false to keep the sandbox for our tests
CLEANUP=false source test/002_patch.sh

echo "## Testing 'remove' command..."

# 1. Test removal in Shell/Just implementation
# '002' created vendor/lib
echo "## Testing removal in Shell/Just..."
just cross remove vendor/lib

if [ -d "vendor/lib" ]; then fail "vendor/lib still exists after remove"; fi
if grep -q "vendor/lib" Crossfile; then fail "Crossfile still contains patch entry"; fi
if grep -q "vendor/lib" .git/cross/metadata.json; then fail "Metadata still contains patch entry"; fi
if git worktree list | grep -q "vendor/lib"; then fail "Worktree still exists"; fi

# 2. Test removal in Go implementation
echo "## Testing removal in Go..."
just cross patch repo1:src/lib vendor/app-go
cd "$REPO_ROOT/src-go" && go build -o git-cross-go main.go
cd "$SANDBOX"
"$REPO_ROOT/src-go/git-cross-go" remove vendor/app-go

if [ -d "vendor/app-go" ]; then fail "vendor/app-go still exists after remove"; fi
if grep -q "vendor/app-go" Crossfile; then fail "Crossfile still contains patch entry"; fi
if grep -q "vendor/app-go" .git/cross/metadata.json; then fail "Metadata still contains patch entry"; fi

# 3. Test removal in Rust implementation
echo "## Testing removal in Rust..."
just cross patch repo1:src/lib vendor/app-rust
cd "$REPO_ROOT/src-rust" && cargo build -q
cd "$SANDBOX"
"$REPO_ROOT/src-rust/target/debug/git-cross-rust" remove vendor/app-rust

if [ -d "vendor/app-rust" ]; then fail "vendor/app-rust still exists after remove"; fi
if grep -q "vendor/app-rust" Crossfile; then fail "Crossfile still contains patch entry"; fi
if grep -q "vendor/app-rust" .git/cross/metadata.json; then fail "Metadata still contains patch entry"; fi

# 4. Test list command (Go) - need active patch for remotes to show
echo "## Testing 'list' command (Go)..."
just cross patch repo1:src/lib vendor/list-test
list_output=$("$REPO_ROOT/src-go/git-cross-go" list)
if ! echo "$list_output" | grep -q "Configured Remotes"; then fail "Go list missing Remotes section"; fi
if ! echo "$list_output" | grep -q "repo1"; then fail "Go list missing repo1 remote"; fi
just cross remove vendor/list-test

# 5. Test Crossfile deduplication (Go)
echo "## Testing Crossfile deduplication (Go)..."
# Add a duplicate with different spacing or already present
# Current Crossfile has: cross patch repo1:main:src/lib vendor/app-rust (added in step 3 but removed? wait 014 removes them)
# Let's add one and then try to re-add
just cross patch repo1:src/lib vendor/dedup-test
count_before=$(grep -c "vendor/dedup-test" Crossfile)
# Try to add again with Go
"$REPO_ROOT/src-go/git-cross-go" patch repo1:main:src/lib vendor/dedup-test
count_after=$(grep -c "vendor/dedup-test" Crossfile)
if [ "$count_after" -ne "$count_before" ]; then fail "Crossfile duplication occurred (Go)"; fi

# 6. Test Crossfile deduplication (Rust)
echo "## Testing Crossfile deduplication (Rust)..."
# Try to add again with Rust
"$REPO_ROOT/src-rust/target/debug/git-cross-rust" patch repo1:main:src/lib vendor/dedup-test
count_after_rust=$(grep -c "vendor/dedup-test" Crossfile)
if [ "$count_after_rust" -ne "$count_before" ]; then fail "Crossfile duplication occurred (Rust)"; fi

# 7. Test list command (Rust)
echo "## Testing 'list' command (Rust)..."
list_output_rust=$("$REPO_ROOT/src-rust/target/debug/git-cross-rust" list)
if ! echo "$list_output_rust" | grep -q "Configured Remotes"; then fail "Rust list missing Remotes section"; fi

echo "Phase 2 validation passed!"
