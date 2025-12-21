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

log_header "Testing Go 'push' command..."
# Allow pushing to current branch in mock upstream
pushd "$upstream_path" >/dev/null
git config receive.denyCurrentBranch ignore
popd >/dev/null

echo "Local modification" >> vendor/go-src/logic.go
git add vendor/go-src/logic.go
git commit -m "Local go change"

"$GO_BIN" push vendor/go-src --yes
last_msg=$(git -C "$upstream_path" log -1 --pretty=%s)
if [[ "$last_msg" != "Local go change" ]]; then
    fail "Go 'push' failed. Expected 'Local go change', got '$last_msg'"
fi

log_header "Testing Go 'init' command..."
mkdir -p init-test
pushd init-test >/dev/null
"$GO_BIN" init
if [ ! -f "Crossfile" ]; then
    fail "Go 'init' failed to create Crossfile"
fi
popd >/dev/null

echo "Go implementation tests passed!"
