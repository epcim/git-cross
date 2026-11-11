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
if grep -q "vendor/lib" .cross/metadata.json; then fail "Metadata still contains patch entry"; fi
if git worktree list | grep -q "vendor/lib"; then fail "Worktree still exists"; fi

# Build Go binary (reuse existing or build fresh)
GO_BIN="$REPO_ROOT/src-go/git-cross-go"
if [ -f "$GO_BIN" ] && [ "$REPO_ROOT/src-go/main.go" -nt "$GO_BIN" ]; then
    rm -f "$GO_BIN"
fi
if [ ! -f "$GO_BIN" ]; then
    if command -v go >/dev/null 2>&1; then
        # Remove stale vendor dir that causes "inconsistent vendoring" errors
        rm -rf "$REPO_ROOT/src-go/vendor" 2>/dev/null || true
        ( cd "$REPO_ROOT/src-go" && CGO_ENABLED=0 go build -mod=mod -tags purego -o git-cross-go main.go ) || {
            echo "WARN: Go build failed, skipping Go tests"
            GO_BIN=""
        }
    else
        echo "SKIP: Go not available, skipping Go tests"
        GO_BIN=""
    fi
fi

# 2. Test removal in Go implementation
if [ -n "$GO_BIN" ] && [ -f "$GO_BIN" ]; then
    echo "## Testing removal in Go..."
    just cross patch repo1:src/lib vendor/app-go
    "$GO_BIN" remove vendor/app-go

    if [ -d "vendor/app-go" ]; then fail "vendor/app-go still exists after remove"; fi
    if grep -q "vendor/app-go" Crossfile; then fail "Crossfile still contains patch entry"; fi
    if grep -q "vendor/app-go" .cross/metadata.json; then fail "Metadata still contains patch entry"; fi
else
    echo "SKIP: Go binary not available, skipping Go removal test"
fi

# 4. Test list command (Go) - need active patch for remotes to show
if [ -n "$GO_BIN" ] && [ -f "$GO_BIN" ]; then
    echo "## Testing 'list' command (Go)..."
    just cross patch repo1:src/lib vendor/list-test
    list_output=$("$GO_BIN" list)
    echo "$list_output"
    if ! echo "$list_output" | grep -q "Configured Remotes"; then fail "Go list missing Remotes section"; fi
    if ! echo "$list_output" | grep -q "repo1"; then fail "Go list missing repo1 remote"; fi
    if ! echo "$list_output" | grep -q "REMOTE URL"; then fail "Go list missing descriptive 'REMOTE URL' header"; fi
    if ! echo "$list_output" | grep -q "LOCAL PATH"; then fail "Go list missing 'LOCAL PATH' header"; fi

    echo "## Testing 'list --raw' (Go)..."
    raw_output=$("$GO_BIN" list --raw)
    echo "$raw_output"
    if echo "$raw_output" | grep -q "==>"; then fail "Go list --raw must not print banners"; fi
    if echo "$raw_output" | grep -q '^+' || echo "$raw_output" | grep -q '|'; then
        fail "Go list --raw must not print table borders"
    fi
    if ! echo "$raw_output" | grep -q "REMOTE_NAME"; then fail "Go list --raw missing REMOTE_NAME header"; fi
    if ! printf '%s\n' "$raw_output" | cut -f3 | grep -qx "vendor/list-test"; then
        fail "Go list --raw: cut -f3 should yield local paths"
    fi
    raw_again=$("$GO_BIN" list --raw)
    if [ "$raw_output" != "$raw_again" ]; then fail "Go list --raw is not deterministic"; fi
    noheader_output=$("$GO_BIN" list --raw --no-header)
    if echo "$noheader_output" | grep -q "REMOTE_NAME"; then
        fail "Go list --raw --no-header must omit headers"
    fi
    if ! printf '%s\n' "$noheader_output" | cut -f3 | grep -qx "vendor/list-test"; then
        fail "Go list --raw --no-header should still print patch rows"
    fi
    just cross remove vendor/list-test

    # 4b. Test list --raw for the Just/Fish implementation when fish is available
    if command -v fish >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        echo "## Testing 'list raw=1' (Just/Fish)..."
        just cross patch repo1:src/lib vendor/list-test
        raw_output=$(just cross list raw=1)
        echo "$raw_output"
        if echo "$raw_output" | grep -q "==>"; then fail "Just list raw=1 must not print banners"; fi
        if echo "$raw_output" | grep -q '^+' || echo "$raw_output" | grep -q '|'; then
            fail "Just list raw=1 must not print table borders"
        fi
        if ! echo "$raw_output" | grep -q "REMOTE_NAME"; then fail "Just list raw=1 missing REMOTE_NAME header"; fi
        if ! printf '%s\n' "$raw_output" | cut -f3 | grep -qx "vendor/list-test"; then
            fail "Just list raw=1: cut -f3 should yield local paths"
        fi
        raw_again=$(just cross list raw=1)
        if [ "$raw_output" != "$raw_again" ]; then fail "Just list raw=1 is not deterministic"; fi
        noheader_output=$(just cross list raw=1 no_header=1)
        if echo "$noheader_output" | grep -q "REMOTE_NAME"; then
            fail "Just list raw=1 no_header=1 must omit headers"
        fi
        just cross remove vendor/list-test
    fi

    # 5. Test Crossfile deduplication (Go)
    echo "## Testing Crossfile deduplication (Go)..."
    just cross patch repo1:src/lib vendor/dedup-test
    count_before=$(grep -c "vendor/dedup-test" Crossfile)
    # Try to add again with Go
    "$GO_BIN" patch repo1:main:src/lib vendor/dedup-test
    count_after=$(grep -c "vendor/dedup-test" Crossfile)
    if [ "$count_after" -ne "$count_before" ]; then fail "Crossfile duplication occurred (Go)"; fi
else
    echo "SKIP: Go binary not available, skipping Go list and dedup tests"
fi

# 8. Test root-target remove safety guard (Shell/Just)
echo "## Testing root-target remove safety guard (Shell/Just)..."
setup_sandbox
cd "$SANDBOX"

cat > Crossfile <<'EOF'
# git-cross configuration
cross patch root-remote:main:. .
EOF
mkdir -p .cross
cat > .cross/metadata.json <<'EOF'
{"patches":[{"id":"root1234","remote":"root-remote","remote_path":".","local_path":".","worktree":".cross/worktrees/root-remote_root1234","branch":"main"}]}
EOF
echo "keep me" > keep.txt

just cross remove .

if [ ! -f "keep.txt" ]; then fail "root-target remove deleted repo root contents"; fi
if grep -q 'root-remote:main:. \.$' Crossfile; then fail "root-target remove did not clean Crossfile"; fi
if [ "$(jq -r '.patches | length' .cross/metadata.json)" != "0" ]; then fail "root-target remove did not clean metadata"; fi

echo "Phase 2 validation passed!"
