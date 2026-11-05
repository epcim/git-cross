#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

setup_sandbox
cd "$SANDBOX"

GO_BIN="$REPO_ROOT/src-go/git-cross-go"
if [ ! -f "$GO_BIN" ]; then
    if ! command -v go >/dev/null 2>&1; then
        echo "SKIP: Go not available"
        exit 0
    fi
    rm -rf "$REPO_ROOT/src-go/vendor" 2>/dev/null || true
    (cd "$REPO_ROOT/src-go" && CGO_ENABLED=0 go build -mod=mod -tags purego -o git-cross-go main.go)
fi

upstream_path=$(create_upstream "ai-project")
mkdir -p "$upstream_path/src"
echo "v1" > "$upstream_path/src/app.js"
git -C "$upstream_path" add src/app.js
git -C "$upstream_path" commit -m "Add app" -q

"$GO_BIN" use ai-project "file://$upstream_path"
"$GO_BIN" patch ai-project:src vendor/ai-src

# Simulate local/sandbox edits and a concurrent upstream update.
echo "local AI change" > vendor/ai-src/app.js
echo "upstream v2" > "$upstream_path/src/app.js"
echo "new upstream file" > "$upstream_path/src/new.js"
git -C "$upstream_path" add src
git -C "$upstream_path" commit -m "Upstream update" -q

output=$("$GO_BIN" update vendor/ai-src 2>&1)
echo "$output"
if ! grep -q "local AI change" vendor/ai-src/app.js; then
    fail "Update overwrote local changes"
fi
if ! echo "$output" | grep -q "Local edits detected"; then
    fail "Update did not report the conflict review workflow"
fi
if ! echo "$output" | grep -q "DirDiff"; then
    fail "Update did not show the default comparison tool command"
fi

wt=$(jq -r '.patches[0].worktree' .cross/metadata.json)
if ! git -C "$wt" show HEAD:src/app.js | grep -q "upstream v2"; then
    fail "Sparse worktree did not update from upstream"
fi
assert_file_exists "$wt/src/new.js"
echo "Update workflow test passed."
