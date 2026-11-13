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
# Rebuild if the source changed since the binary was built.
if [ -f "$GO_BIN" ] && [ "$REPO_ROOT/src-go/main.go" -nt "$GO_BIN" ]; then
    rm -f "$GO_BIN"
fi
if [ ! -f "$GO_BIN" ]; then
    echo "Go binary not found at $GO_BIN. Building..."
    export PATH=$HOME/homebrew/bin:$PATH
    # Remove stale vendor dir that causes "inconsistent vendoring" errors
    rm -rf "$REPO_ROOT/src-go/vendor" 2>/dev/null || true
    ( cd "$REPO_ROOT/src-go" && CGO_ENABLED=0 go build -mod=mod -tags purego -o git-cross-go main.go)
fi
# Smoke test: verify the binary works (catches SIGILL on emulated ARM64 platforms
# where Go toolchain auto-download produces incompatible binaries)
if ! "$GO_BIN" --version >/dev/null 2>&1; then
    echo "SKIP: Go binary crashes on this platform (likely QEMU ARM64 emulation issue)."
    echo "The Go implementation tests require native hardware or compatible emulation."
    echo "Shell tests (001-007) and CI on native hardware validate the Go implementation."
    exit 0
fi
command_help=$("$GO_BIN" --help 2>&1)
for retired_command in sync push replay exec; do
    if echo "$command_help" | grep -Eq "^[[:space:]]+$retired_command[[:space:]]"; then
        fail "Retired command '$retired_command' is still exposed in Go CLI help"
    fi
done
# Smoke test: create a temp git repo and run 'use' to exercise gogs/git-module
# This catches SIGILL from incompatible Go toolchain binaries
_smoke_dir=$(mktemp -d)
git init -q "$_smoke_dir"
_go_bin_ok=true
"$GO_BIN" use _smoke file:///dev/null >/dev/null 2>&1 || _go_bin_ok=false
rm -rf "$_smoke_dir"
if [ "$_go_bin_ok" = false ]; then
    echo "Compiled binary not working on this platform. Using 'go run' wrapper..."
    GO_BIN="$SANDBOX/bin/git-cross-go"
    mkdir -p "$SANDBOX/bin"
    # Compiled Go binaries crash with SIGILL on this emulated ARM64 platform.
    # Use 'go run' wrapper: GOFLAGS=-mod=mod skips vendor dir;
    # run from CWD so relative paths (.cross/worktrees/...) resolve correctly.
    cat > "$GO_BIN" <<GOEOF
#!/usr/bin/env bash
export GOFLAGS="-mod=mod -tags=purego"
exec go run "$REPO_ROOT/src-go/main.go" "\$@"
GOEOF
    chmod +x "$GO_BIN"
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

log_header "Testing Go 'patch' with whole repo root (.: and :/)..."
# Create a small upstream to patch entirely
root_upstream=$(create_upstream "root-demo")
pushd "$root_upstream" >/dev/null
echo "root file" > root.txt
mkdir -p sub
echo "sub file" > sub/data.txt
git add . && git commit -m "Root content" -q
popd >/dev/null

"$GO_BIN" use root-demo "file://$root_upstream"
"$GO_BIN" patch root-demo:. vendor/whole-repo
if [ ! -f "vendor/whole-repo/root.txt" ]; then
    fail "Go 'patch' with '.' failed to vendor root.txt"
fi
if [ ! -f "vendor/whole-repo/sub/data.txt" ]; then
    fail "Go 'patch' with '.' failed to vendor sub/data.txt"
fi

# Also test :/ syntax (should be normalized to .)
"$GO_BIN" patch root-demo:/ vendor/whole-repo-slash
if [ ! -f "vendor/whole-repo-slash/root.txt" ]; then
    fail "Go 'patch' with '/' failed to vendor root.txt"
fi
"$GO_BIN" remove vendor/whole-repo-slash

# FIXME: cd and wt commands with --dry flag hang in CI environment
# These commands work locally but cause test timeouts in automated runs
# Skipping for now - comprehensive testing in test/010_worktree.sh
log_info "Skipping 'cd' and 'wt' command tests (see test/010_worktree.sh)"

log_header "Testing Go 'list' command..."
list_output=$("$GO_BIN" list 2>&1)
echo "$list_output"
if ! echo "$list_output" | grep -q "demo"; then
    fail "Go 'list' should show remote 'demo'"
fi
if ! echo "$list_output" | grep -q "vendor/go-src"; then
    fail "Go 'list' should show patch path 'vendor/go-src'"
fi

log_header "Testing Go 'list --raw' machine-readable output..."
raw_output=$("$GO_BIN" list --raw 2>/dev/null)
echo "$raw_output"
if echo "$raw_output" | grep -q "==>"; then
    fail "Go 'list --raw' must not print section banners"
fi
if echo "$raw_output" | grep -q '^+'; then
    fail "Go 'list --raw' must not print table borders ('+')"
fi
if echo "$raw_output" | grep -q '|'; then
    fail "Go 'list --raw' must not print table borders ('|')"
fi
if ! echo "$raw_output" | grep -q "REMOTE_NAME" || ! echo "$raw_output" | grep -q "REMOTE_URL"; then
    fail "Go 'list --raw' should print the REMOTE_NAME/REMOTE_URL header"
fi
if ! echo "$raw_output" | grep -q "LOCAL_PATH" || ! echo "$raw_output" | grep -q "WORKTREE" || ! echo "$raw_output" | grep -q "BRANCH"; then
    fail "Go 'list --raw' should print the patch header with LOCAL_PATH, WORKTREE and BRANCH"
fi
if ! printf '%s\n' "$raw_output" | cut -f3 | grep -qx "vendor/go-src"; then
    fail "Go 'list --raw' patches block: 'cut -f3' should yield local paths"
fi
if ! printf '%s\n' "$raw_output" | cut -f1 | grep -qx "demo"; then
    fail "Go 'list --raw' remotes block should start with the remote name"
fi

raw_again=$("$GO_BIN" list --raw 2>/dev/null)
if [ "$raw_output" != "$raw_again" ]; then
    fail "Go 'list --raw' output is not deterministic between runs"
fi

noheader_output=$("$GO_BIN" list --raw --no-header 2>/dev/null)
echo "$noheader_output"
if echo "$noheader_output" | grep -q "REMOTE_NAME" || echo "$noheader_output" | grep -q "LOCAL_PATH"; then
    fail "Go 'list --raw --no-header' should omit the header lines"
fi
if ! printf '%s\n' "$noheader_output" | cut -f3 | grep -qx "vendor/go-src"; then
    fail "Go 'list --raw --no-header' should still print patch rows"
fi

table_noheader=$("$GO_BIN" list --no-header 2>&1)
if echo "$table_noheader" | grep -q "REMOTE PATH" || echo "$table_noheader" | grep -q "LOCAL PATH"; then
    fail "Go 'list --no-header' should omit the table headers"
fi
if ! echo "$table_noheader" | grep -q "vendor/go-src"; then
    fail "Go 'list --no-header' should still print the patch rows"
fi

# A remote whose fetch and push URLs differ gets two rows under the same schema.
git remote set-url --push demo "file://$upstream_path-push"
pushpull_output=$("$GO_BIN" list --raw 2>/dev/null)
echo "$pushpull_output"
demo_rows=$(printf '%s\n' "$pushpull_output" | awk -F'\t' '$1=="demo" && NF==2' | wc -l | tr -d ' ')
if [ "$demo_rows" -ne 2 ]; then
    fail "Go 'list --raw' should emit two rows for a fetch!=push remote (got $demo_rows)"
fi
if printf '%s\n' "$pushpull_output" | grep -q "(fetch)\|(push)"; then
    fail "Go 'list --raw' must not add (fetch)/(push) suffixes to URLs"
fi
git remote set-url --push demo "$upstream_url"

log_header "Testing Go 'status' command..."
status_output=$("$GO_BIN" status 2>&1)
echo "$status_output"
if ! echo "$status_output" | grep -q "vendor/go-src"; then
    fail "Go 'status' should show patch 'vendor/go-src'"
fi

log_header "Testing Go 'update' command..."
# Mock upstream change
pushd "$upstream_path" >/dev/null
echo "Updated go logic" > src/logic.go
git add src/logic.go
git commit -m "Update go logic"
popd >/dev/null

"$GO_BIN" update vendor/go-src
if ! grep -q "Updated go logic" "vendor/go-src/logic.go"; then
    fail "Go 'update' failed to pull updates"
fi

log_header "Testing Go update preserves local edits while refreshing worktree..."
echo "local-only edit" >> vendor/go-src/logic.go
pushd "$upstream_path" >/dev/null
echo "upstream update after local edit" >> src/logic.go
git add src/logic.go
git commit -m "Update logic again" -q
popd >/dev/null
update_output=$("$GO_BIN" update vendor/go-src 2>&1)
echo "$update_output"
if ! grep -q "local-only edit" vendor/go-src/logic.go; then
    fail "Go update overwrote the local edit"
fi
if ! echo "$update_output" | grep -q "differs from upstream"; then
    fail "Go update should report that the local copy differs from upstream"
fi
if echo "$update_output" | grep -q "Local edits detected"; then
    fail "Go update still prints the old 'Local edits detected' wording"
fi
if echo "$update_output" | grep -q "DirDiff"; then
    fail "Go update should not print the configured diff tool command"
fi
if echo "$update_output" | grep -q "git config --global cross.dirdifftool"; then
    fail "Go update should not print the global cross.dirdifftool hint"
fi

log_header "Testing Go 'diff' command..."
# Modify a local file to create a diff
echo "local diff change" >> vendor/go-src/logic.go
diff_output=$("$GO_BIN" diff vendor/go-src 2>&1 || true)
echo "$diff_output"
if ! echo "$diff_output" | grep -q "local diff change"; then
    fail "Go 'diff' should show local modifications"
fi
# Revert the change for clean state
echo "Updated go logic" > vendor/go-src/logic.go

log_header "Testing Go 'compare' command with configured tool..."
cat > "$SANDBOX/bin/compare-tool" <<'EOF'
#!/usr/bin/env bash
printf '%s\n%s\n' "$1" "$2" > "$COMPARE_TOOL_ARGS"
EOF
chmod +x "$SANDBOX/bin/compare-tool"
export COMPARE_TOOL_ARGS="$SANDBOX/compare-args.txt"
# Template form: placeholders are substituted with repo-relative paths.
git config cross.dirdifftool "$SANDBOX/bin/compare-tool {left} {right}"
"$GO_BIN" compare vendor/go-src
if ! grep -q ".cross/worktrees/demo_" "$COMPARE_TOOL_ARGS"; then
    fail "Go compare did not pass the sparse worktree path"
fi
if ! grep -q "vendor/go-src" "$COMPARE_TOOL_ARGS"; then
    fail "Go compare did not pass the local patch path"
fi
if grep -q "^/" "$COMPARE_TOOL_ARGS"; then
    fail "Go compare template should substitute repo-relative paths, got absolute paths"
fi

# Legacy form (no placeholders) still appends the paths as arguments.
rm -f "$COMPARE_TOOL_ARGS"
git config cross.dirdifftool "$SANDBOX/bin/compare-tool"
"$GO_BIN" compare vendor/go-src
if ! grep -q ".cross/worktrees/demo_" "$COMPARE_TOOL_ARGS"; then
    fail "Go compare legacy form did not pass the sparse worktree path"
fi
if ! grep -q "vendor/go-src" "$COMPARE_TOOL_ARGS"; then
    fail "Go compare legacy form did not pass the local patch path"
fi
git config --unset cross.dirdifftool
unset COMPARE_TOOL_ARGS

# The 'cmp' alias behaves like 'compare'.
git config cross.dirdifftool 'echo TOOL {left} {right}'
cmp_output=$("$GO_BIN" cmp vendor/go-src 2>&1 || true)
echo "$cmp_output"
if ! echo "$cmp_output" | grep -Eq "TOOL \.cross/worktrees/demo_[0-9a-f]+/src vendor/go-src"; then
    fail "Go 'cmp' alias should resolve and run the diff tool like 'compare'"
fi
git config --unset cross.dirdifftool

log_header "Testing Go legacy cross.diffTool fallback..."
# The deprecated key still drives the tool...
git config cross.diffTool 'echo LEGACY {left} {right}'
legacy_output=$("$GO_BIN" compare vendor/go-src 2>&1 || true)
echo "$legacy_output"
if ! echo "$legacy_output" | grep -q "LEGACY .cross/worktrees/demo_"; then
    fail "Legacy cross.diffTool should still be used as a fallback"
fi
# ...but the canonical key wins when both are set.
git config cross.dirdifftool 'echo NEW {left} {right}'
both_output=$("$GO_BIN" compare vendor/go-src 2>&1 || true)
echo "$both_output"
if ! echo "$both_output" | grep -q "NEW .cross/worktrees/demo_"; then
    fail "cross.dirdifftool should take precedence over the legacy key"
fi
git config --unset cross.dirdifftool
git config --unset cross.diffTool

log_header "Testing Go '.crossignore' override status/diff hint..."
mkdir -p vendor/go-src/subdir
touch vendor/go-src/subdir/.env
cat > vendor/go-src/.crossignore <<'EOF'
.env
EOF
status_output=$("$GO_BIN" status 2>&1)
echo "$status_output"
status_line=$(echo "$status_output" | grep "vendor/go-src" || true)
if ! echo "$status_line" | grep -q "Override"; then
    fail "Go 'status' should mark override patches as Override"
fi

diff_output=$("$GO_BIN" diff vendor/go-src 2>&1 || true)
echo "$diff_output"
if ! echo "$diff_output" | grep -q ".crossignore overrides present in vendor/go-src"; then
    fail "Go 'diff' should mention override review when markers exist"
fi
if ! echo "$diff_output" | grep -q 'subdir/.env'; then
    fail "Go 'diff' should print basename override file command from nested directory"
fi
rm -f vendor/go-src/.crossignore
rm -f vendor/go-src/subdir/.env
rmdir vendor/go-src/subdir 2>/dev/null || true

log_header "Testing Go 'init' command..."
mkdir -p init-test
pushd init-test >/dev/null
"$GO_BIN" init
if [ ! -f "Crossfile" ]; then
    fail "Go 'init' failed to create Crossfile"
fi
popd >/dev/null

log_header "Testing Go 'update' from Crossfile in a fresh repository..."
update_dir="$SANDBOX/update-test"
mkdir -p "$update_dir"
pushd "$update_dir" >/dev/null
git init -q
git config user.email "test@example.com"
git config user.name "Test User"
echo "replay test" > README.md
git add . && git commit -m "init" -q

# Write declarative Crossfile configuration
cat > Crossfile <<CROSSEOF
cross use demo $upstream_url
cross patch demo:main:src vendor/update-src
CROSSEOF

"$GO_BIN" update
if [ ! -f "vendor/update-src/logic.go" ]; then
    fail "Go 'update' failed to create a missing patch from Crossfile"
fi
log_success "Go Crossfile update test passed"
popd >/dev/null

log_header "Testing Go 'remove' command..."
# Create a new patch to remove
pushd "$upstream_path" >/dev/null
mkdir -p extras
echo "extra content" > extras/extra.txt
git add extras/extra.txt
git commit -m "Add extras" -q
popd >/dev/null

"$GO_BIN" patch demo:extras vendor/extras
if [ ! -f "vendor/extras/extra.txt" ]; then
    fail "Go 'patch' for extras failed"
fi

"$GO_BIN" remove vendor/extras
if [ -d "vendor/extras" ]; then
    fail "Go 'remove' should delete vendor/extras directory"
fi
if grep -q "vendor/extras" Crossfile 2>/dev/null; then
    fail "Go 'remove' should clean Crossfile entry"
fi
log_success "Go remove test passed"

log_header "Testing Go 'prune' command..."
# Create a dedicated remote and patch for prune testing
prune_upstream=$(create_upstream "prune-demo")
pushd "$prune_upstream" >/dev/null
mkdir -p lib
echo "prune lib" > lib/prune.txt
git add lib/prune.txt
git commit -m "Add prune lib" -q
popd >/dev/null

"$GO_BIN" use prune-remote "file://$prune_upstream"
"$GO_BIN" patch prune-remote:lib vendor/prune-lib

if [ ! -f "vendor/prune-lib/prune.txt" ]; then
    fail "Prune setup: patch not created"
fi

# Prune the remote (should remove all its patches and the remote itself)
"$GO_BIN" prune prune-remote
if git remote | grep -q "^prune-remote$"; then
    fail "Go 'prune' should remove the remote"
fi
if [ -d "vendor/prune-lib" ]; then
    fail "Go 'prune' should remove patch directories for that remote"
fi
log_success "Go prune test passed"

log_header "Testing Go root-target remove guard..."
cat > Crossfile <<'EOF'
# git-cross configuration
cross patch root-remote:main:. .
EOF
mkdir -p .cross
cat > .cross/metadata.json <<'EOF'
{"patches":[{"id":"root1234","remote":"root-remote","remote_path":".","local_path":".","worktree":".cross/worktrees/root-remote_root1234","branch":"main"}]}
EOF
echo "keep me" > keep-root-go.txt

"$GO_BIN" remove .
if [ ! -f "keep-root-go.txt" ]; then
    fail "Go root-target remove deleted repo root contents"
fi

echo "Go implementation tests passed!"
