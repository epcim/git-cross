#!/usr/bin/env bash
# Test 016: Context-aware cross diff
# Verifies that `diff` without a path argument auto-detects the current patch
# from CWD (when inside a patched directory), and shows all patches otherwise.
source "$(dirname "$0")/common.sh"

setup_sandbox

# --- Setup upstream with two separate source trees ---
upstream_path=$(create_upstream "diff-context-upstream")
pushd "$upstream_path" >/dev/null
mkdir -p src/alpha src/beta
echo "alpha v1" > src/alpha/alpha.txt
echo "beta v1"  > src/beta/beta.txt
git add src/
git commit -m "Add alpha and beta" -q
popd >/dev/null
upstream_url="file://$upstream_path"

just cross use upstream "$upstream_url"
just cross patch upstream:src/alpha vendor/alpha
just cross patch upstream:src/beta  vendor/beta

# Locally modify both patches
echo "local alpha change" >> vendor/alpha/alpha.txt
echo "local beta change"  >> vendor/beta/beta.txt

# --- Test 1: diff with explicit path → shows only that patch ---
log_header "Test 1: diff with explicit path shows only that patch..."
output=$(just cross diff vendor/alpha 2>&1 || true)
echo "$output"
if ! echo "$output" | grep -q "alpha"; then
    fail "Test 1: diff vendor/alpha should show alpha diff"
fi
if echo "$output" | grep -q "beta"; then
    fail "Test 1: diff vendor/alpha should NOT show beta diff"
fi
log_success "Test 1 passed: explicit path filters correctly"

# --- Test 2: diff from inside patch dir (no arg) → auto-detects patch ---
log_header "Test 2: diff from inside patch dir auto-detects patch..."
pushd vendor/alpha >/dev/null
output=$(just cross diff 2>&1 || true)
echo "$output"
if ! echo "$output" | grep -q "alpha"; then
    fail "Test 2: diff from vendor/alpha should show alpha diff"
fi
if echo "$output" | grep -q "beta"; then
    fail "Test 2: diff from inside vendor/alpha should NOT show beta diff"
fi
popd >/dev/null
log_success "Test 2 passed: auto-detected patch from CWD"

# --- Test 3: diff from subdirectory inside patch → still auto-detects ---
log_header "Test 3: diff from subdirectory inside patch auto-detects..."
mkdir -p vendor/beta/subdir
pushd vendor/beta/subdir >/dev/null
output=$(just cross diff 2>&1 || true)
echo "$output"
if ! echo "$output" | grep -q "beta"; then
    fail "Test 3: diff from vendor/beta/subdir should show beta diff"
fi
if echo "$output" | grep -q "alpha"; then
    fail "Test 3: diff from inside vendor/beta should NOT show alpha diff"
fi
popd >/dev/null
log_success "Test 3 passed: subdirectory resolves to parent patch"

# --- Test 4: diff with explicit '.' from inside patch ---
log_header "Test 4: diff with '.' from inside patch..."
pushd vendor/alpha >/dev/null
output=$(just cross diff . 2>&1 || true)
echo "$output"
if ! echo "$output" | grep -q "alpha"; then
    fail "Test 4: diff . from vendor/alpha should show alpha diff"
fi
popd >/dev/null
log_success "Test 4 passed: diff . works from inside patch"

# --- Test 4b: diff from repo root without a path, fzf absent → rows + hint ---
log_header "Test 4b: diff from repo root (no path, no fzf) prints rows and exits 1..."
nofzf_path=$(make_path_without_fzf "$SANDBOX/no-fzf-bin")
diff_rc=0
output=$(PATH="$nofzf_path" just cross diff 2>&1) || diff_rc=$?
echo "$output"
if [ "$diff_rc" -eq 0 ]; then
    fail "Test 4b: diff without a path outside a patch should exit non-zero"
fi
if ! printf '%s\n' "$output" | awk -F'\t' '$1=="vendor/alpha"{found=1} END{exit found?0:1}'; then
    fail "Test 4b: diff should list patch rows (local_path<TAB>worktree)"
fi
if echo "$output" | grep -q "Usage:"; then
    fail "Test 4b: diff should not dump a Usage message"
fi
if ! echo "$output" | grep -q "fzf is not installed"; then
    fail "Test 4b: diff should explain that fzf is missing"
fi
log_success "Test 4b passed: Just diff falls back to rows+hint"

# --- Go implementation tests (when binary is available) ---
GO_BIN="$REPO_ROOT/src-go/git-cross-go"
if [ -f "$GO_BIN" ] && [ "$REPO_ROOT/src-go/main.go" -nt "$GO_BIN" ]; then
    rm -f "$GO_BIN"
fi
if [ ! -f "$GO_BIN" ]; then
    (cd "$REPO_ROOT/src-go" && CGO_ENABLED=0 go build -o git-cross-go main.go 2>/dev/null)
fi
_go_ok=false
_smoke_dir=$(mktemp -d)
git init -q "$_smoke_dir"
"$GO_BIN" use _smoke file:///dev/null >/dev/null 2>&1 && _go_ok=true
if [ "$_go_ok" = false ]; then
    log_warn "Go binary not working on this platform, skipping Go-specific diff context tests"
else
    # Without a path and outside a patch dir the new contract is: fzf selection,
    # or rows + hint + exit 1 when fzf is missing. (It used to dump all patches.)
    log_header "Test 5 (Go): diff from repo root without fzf prints rows and exits 1..."
    nofzf_path=$(make_path_without_fzf "$SANDBOX/no-fzf-bin")
    diff_rc=0
    output=$(PATH="$nofzf_path" "$GO_BIN" diff 2>&1) || diff_rc=$?
    echo "$output"
    [ "$diff_rc" -eq 1 ] || fail "Test 5 (Go): diff without fzf should exit 1, got $diff_rc"
    if ! printf '%s\n' "$output" | cut -f1 | grep -qx "vendor/alpha" \
        || ! printf '%s\n' "$output" | cut -f1 | grep -qx "vendor/beta"; then
        fail "Test 5 (Go): diff should list all patches as rows"
    fi
    if ! echo "$output" | grep -q "fzf is not installed"; then
        fail "Test 5 (Go): diff should explain that fzf is missing"
    fi
    log_success "Test 5 passed: Go diff falls back to rows+hint"

    log_header "Test 6 (Go): diff from inside patch auto-detects..."
    pushd vendor/alpha >/dev/null
    output=$(PATH="$nofzf_path" "$GO_BIN" diff 2>&1 || true)
    echo "$output"
    if ! echo "$output" | grep -q "alpha"; then
        fail "Test 6 (Go): auto-detect should show alpha diff"
    fi
    if echo "$output" | grep -q "beta"; then
        fail "Test 6 (Go): auto-detect should NOT show beta diff"
    fi
    popd >/dev/null
    log_success "Test 6 passed: Go auto-detects patch from CWD"

    log_header "Test 7 (Go): diff honours the fzf selection..."
    shim_dir="$SANDBOX/fzf-shim-bin"
    mkdir -p "$shim_dir"
    cat > "$shim_dir/fzf" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
if [ -n "${FZF_SELECT:-}" ]; then
    printf '%b\n' "$FZF_SELECT"
    exit 0
fi
exit 130
EOF
    chmod +x "$shim_dir/fzf"
    output=$(FZF_SELECT='upstream\t.\tvendor/beta' PATH="$shim_dir:$PATH" "$GO_BIN" diff 2>&1 || true)
    echo "$output"
    if ! echo "$output" | grep -q "beta"; then
        fail "Test 7 (Go): fzf selection should show the beta diff"
    fi
    if echo "$output" | grep -q "alpha"; then
        fail "Test 7 (Go): fzf selection should NOT show the alpha diff"
    fi
    log_success "Test 7 passed: Go diff uses the fzf selection"
fi

# --- Test 8: override markers print manual diff commands ---
log_header "Test 8: override markers print manual diff commands..."
mkdir -p vendor/alpha/config
mkdir -p vendor/alpha/subdir
touch vendor/alpha/subdir/.env vendor/alpha/config/private.yml
cat > vendor/alpha/.crossignore <<'EOF'
.env
config/
EOF
output=$(just cross diff vendor/alpha 2>&1 || true)
echo "$output"
if ! echo "$output" | grep -q 'subdir/.env'; then
    fail "Test 8: diff should print basename override file command from nested directory"
fi
if ! echo "$output" | grep -q 'config'; then
    fail "Test 8: diff should print directory override command"
fi
rm -f vendor/alpha/.crossignore
rm -f vendor/alpha/subdir/.env vendor/alpha/config/private.yml
rmdir vendor/alpha/subdir 2>/dev/null || true
rmdir vendor/alpha/config 2>/dev/null || true

echo ""
echo "All context-aware diff tests passed!"
