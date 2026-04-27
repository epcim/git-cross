#!/usr/bin/env bash
set -euo pipefail

# Test: AI sandbox (sbx/docker sandbox) workflow with git-cross.
#
# Simulates the workflow where:
# 1. Host sets up git-cross patches
# 2. A sandbox/container only sees the vendor subfolder (no .git/)
# 3. AI tool modifies files inside the sandbox
# 4. Host pushes changes back upstream via git-cross
#
# Since we cannot run actual Docker/sbx containers in CI, this test
# simulates the sandbox boundary by copying the vendor subfolder to
# an isolated directory (simulating a container mount) and verifying
# the full round-trip works.

source "$(dirname "$0")/common.sh"

setup_sandbox
cd "$SANDBOX"

# Build or reuse Go binary
GO_BIN="$REPO_ROOT/src-go/git-cross-go"
if [ ! -f "$GO_BIN" ]; then
    if command -v go >/dev/null 2>&1; then
        rm -r "$REPO_ROOT/src-go/vendor" 2>/dev/null || true
        ( cd "$REPO_ROOT/src-go" && CGO_ENABLED=0 go build -mod=mod -tags purego -o git-cross-go main.go )
    else
        echo "SKIP: Go not available, skipping sbx sandbox test"
        exit 0
    fi
fi
if ! "$GO_BIN" --version >/dev/null 2>&1; then
    echo "SKIP: Go binary not working on this platform"
    exit 0
fi

# --- 1. Host: create upstream with realistic content ---
log_header "Setting up upstream repo with multi-file project..."
upstream_path=$(create_upstream "ai-project")
upstream_url="file://$upstream_path"

pushd "$upstream_path" >/dev/null
mkdir -p src/components
echo 'export function App() { return "Hello"; }' > src/components/App.js
echo 'export function utils() { return true; }' > src/components/utils.js
echo '{"name": "ai-project"}' > src/package.json
git add .
git commit -m "Initial project structure" -q
popd >/dev/null

# --- 2. Host: set up git-cross patches ---
log_header "Host: setting up git-cross vendor..."
"$GO_BIN" use ai-project "$upstream_url"
"$GO_BIN" patch ai-project:src vendor/ai-src

assert_file_exists "vendor/ai-src/components/App.js"
assert_file_exists "vendor/ai-src/components/utils.js"
assert_file_exists "vendor/ai-src/package.json"
log_success "Vendor directory populated"

# --- 3. Simulate sandbox: copy vendor subfolder to isolated directory ---
# This mimics what `sbx create --mount vendor/ai-src` does:
# the container only sees vendor/ai-src/, with NO .git/ directory.
log_header "Simulating sandbox mount (isolated copy, no .git)..."
SBX_DIR=$(mktemp -d)
# rsync just the vendor subfolder — sandbox doesn't get .git/ or .cross/
rsync -a vendor/ai-src/ "$SBX_DIR/"

# Verify sandbox isolation: no git metadata
if [ -d "$SBX_DIR/.git" ]; then
    fail "Sandbox should NOT contain .git directory"
fi
if [ -d "$SBX_DIR/.cross" ]; then
    fail "Sandbox should NOT contain .cross directory"
fi
assert_file_exists "$SBX_DIR/components/App.js"
log_success "Sandbox is isolated (no .git, no .cross)"

# --- 4. Simulate AI tool modifying files in the sandbox ---
log_header "AI tool modifying files in sandbox..."
# AI adds a new component
echo 'export function NewFeature() { return "AI-generated"; }' > "$SBX_DIR/components/NewFeature.js"
# AI modifies an existing file
echo 'export function App() { return "Hello from AI"; }' > "$SBX_DIR/components/App.js"
# AI adds a test file
mkdir -p "$SBX_DIR/tests"
echo 'test("App renders", () => { /* AI test */ });' > "$SBX_DIR/tests/App.test.js"
log_success "AI modifications applied in sandbox"

# --- 5. Host: copy sandbox changes back to vendor subfolder ---
# This mimics the sandbox unmount / file sync back to host
log_header "Syncing sandbox changes back to host vendor dir..."
rsync -a "$SBX_DIR/" vendor/ai-src/

# Verify host has the AI changes
assert_file_exists "vendor/ai-src/components/NewFeature.js"
assert_grep "vendor/ai-src/components/App.js" "Hello from AI"
assert_file_exists "vendor/ai-src/tests/App.test.js"
log_success "Host vendor dir updated with AI changes"

# --- 6. Host: use git-cross diff to review changes ---
log_header "Reviewing AI changes with git cross diff..."
diff_output=$("$GO_BIN" diff vendor/ai-src 2>&1 || true)
if ! echo "$diff_output" | grep -q "NewFeature"; then
    fail "diff should show new AI-generated file"
fi
if ! echo "$diff_output" | grep -q "Hello from AI"; then
    fail "diff should show AI modification"
fi
log_success "git cross diff shows AI changes correctly"

# --- 7. Host: push AI changes back upstream ---
log_header "Pushing AI changes upstream via git cross push..."
# Allow pushing to current branch in mock upstream
pushd "$upstream_path" >/dev/null
git config receive.denyCurrentBranch ignore
popd >/dev/null

# Commit the AI changes locally first
git add vendor/ai-src/
git commit -m "AI-generated improvements" -q

"$GO_BIN" push vendor/ai-src --yes

# Verify upstream received the changes
pushd "$upstream_path" >/dev/null
git checkout HEAD -- . 2>/dev/null || true
if [ ! -f "src/components/NewFeature.js" ]; then
    fail "Upstream should have AI-generated NewFeature.js"
fi
popd >/dev/null
log_success "AI changes pushed to upstream"

# --- 8. Simulate fresh sandbox setup via replay ---
log_header "Testing Crossfile replay (fresh sandbox setup)..."
replay_dir="$SANDBOX/replay-sbx"
mkdir -p "$replay_dir"
pushd "$replay_dir" >/dev/null
git init -q
git config user.email "test@example.com"
git config user.name "Test User"
echo "fresh" > README.md
git add . && git commit -m "init" -q

# Write Crossfile as if setting up a new dev environment
cat > Crossfile <<EOF
cross use ai-project $upstream_url
cross patch ai-project:src vendor/ai-src
EOF

"$GO_BIN" replay
assert_file_exists "vendor/ai-src/components/App.js"
log_success "Crossfile replay reconstructed vendor environment"
popd >/dev/null

# --- 9. Verify sync pulls latest upstream changes ---
log_header "Testing sync after upstream changes..."
pushd "$upstream_path" >/dev/null
echo 'export function Hotfix() { return "urgent"; }' > src/components/Hotfix.js
git add .
git commit -m "Upstream hotfix" -q
popd >/dev/null

"$GO_BIN" sync vendor/ai-src
assert_file_exists "vendor/ai-src/components/Hotfix.js"
log_success "Sync pulled upstream hotfix into vendor"

# Cleanup
rm -r "$SBX_DIR" 2>/dev/null || true

echo ""
echo "AI sandbox (sbx) workflow test passed!"
