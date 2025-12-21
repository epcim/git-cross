#!/usr/bin/env bash
source $(dirname "$0")/common.sh

# Initialize sandbox
setup_sandbox
cd "$SANDBOX"

# Compile go binary
GO_BIN="$REPO_ROOT/src-go/git-cross-go"
if [ ! -f "$GO_BIN" ]; then
    echo "Go binary not found at $GO_BIN. Building..."
    export PATH=$HOME/homebrew/bin:$PATH
    (cd "$REPO_ROOT/src-go" && go build -o git-cross-go main.go)
fi

# Setup upstream
upstream_path=$(create_upstream "go-demo")
upstream_url="file://$upstream_path"

# Prepare some content in upstream
pushd "$upstream_path" >/dev/null
mkdir -p src
echo "Go logic" > src/logic.go
git add src/logic.go
git commit -m "Add go logic"
popd >/dev/null

log_header "Testing Go 'use' command..."
"$GO_BIN" use demo "$upstream_url"

# Verify remote
if ! git remote | grep -q "^demo$"; then
    fail "Go 'use' failed to add remote 'demo'"
fi

log_header "Testing Go 'patch' command..."
"$GO_BIN" patch demo:src vendor/go-src

# Verify files
if [ ! -f "vendor/go-src/logic.go" ]; then
    fail "Go 'patch' failed to vendor logic.go"
fi

log_header "Testing Go 'list' command..."
"$GO_BIN" list

log_header "Testing Go 'status' command..."
"$GO_BIN" status

log_header "Testing Go 'sync' command..."
# Mock upstream change
pushd "$upstream_path" >/dev/null
echo "Updated go logic" > src/logic.go
git add src/logic.go
git commit -m "Update go logic"
popd >/dev/null

"$GO_BIN" sync
if ! grep -q "Updated go logic" "vendor/go-src/logic.go"; then
    fail "Go 'sync' failed to pull updates"
fi

log_header "Testing Go 'replay' command..."
rm -rf vendor/go-src
"$GO_BIN" replay
if [ ! -f "vendor/go-src/logic.go" ]; then
    fail "Go 'replay' failed to restore vendor directory"
fi

echo "Go implementation tests passed!"
