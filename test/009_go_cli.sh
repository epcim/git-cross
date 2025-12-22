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

log_header "Testing Go 'patch' command without branch..."
"$GO_BIN" patch demo:src vendor/go-src

# Verify files
if [ ! -f "vendor/go-src/logic.go" ]; then
    fail "Go 'patch' failed to vendor logic.go"
fi

log_header "Testing Go 'patch' command with explicit branch..."
"$GO_BIN" patch demo:main:src vendor/go-src-branch
if [ ! -f "vendor/go-src-branch/logic.go" ]; then
    fail "Go 'patch' with explicit branch failed"
fi

log_header "Testing Go 'patch' command with nested path and leading slash..."
pushd "$upstream_path" >/dev/null
    mkdir -p nested/dir
    echo "Nested file" > nested/dir/file.txt
    git add nested/dir/file.txt
    git commit -m "Add nested file" >/dev/null
popd >/dev/null
"$GO_BIN" patch demo:main:/nested/dir vendor/nested-dir
if [ ! -f "vendor/nested-dir/file.txt" ]; then
    fail "Go 'patch' failed to vendor nested dir"
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
