#!/usr/bin/env bash
# Test 017: cd/wt path-printing contract.
#
# The command cannot change the caller's shell, so it prints exactly one
# absolute path to stdout (hints go to stderr). No subshell, no clipboard.
# Without a path and without fzf: rows + hint, exit 1.
source "$(dirname "$0")/common.sh"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO_BIN="$(ensure_go_bin "$PROJECT_ROOT")"

assert_one_abs_path() {
    local label=$1
    local output=$2
    local expected=$3
    local line_count
    line_count=$(printf '%s\n' "$output" | sed '/^$/d' | wc -l | tr -d ' ')
    [ "$line_count" -eq 1 ] || fail "$label: expected exactly one line, got $line_count: $output"
    case "$output" in
        /*) ;;
        *) fail "$label: expected an absolute path, got: $output" ;;
    esac
    assert_not_contains "$output" "Opening shell" "$label: must not open a subshell"
    assert_not_contains "$output" "clipboard" "$label: must not copy to the clipboard"
    [ "$output" = "$expected" ] || fail "$label: expected '$expected', got '$output'"
}

cd "$PROJECT_ROOT"
setup_sandbox
cd "$SANDBOX"

upstream_path=$(create_upstream "cd-wt-demo")
pushd "$upstream_path" >/dev/null
mkdir -p src
echo "upstream content" > src/file.txt
git add src/file.txt
git commit -m "Add src" -q
popd >/dev/null
upstream_url="file://$upstream_path"

# Create the patch with whichever implementation is available.
if [ -n "$GO_BIN" ]; then
    "$GO_BIN" use demo "$upstream_url" >/dev/null
    "$GO_BIN" patch demo:src vendor/src >/dev/null
else
    just cross use demo "$upstream_url" >/dev/null
    just cross patch demo:src vendor/src >/dev/null
fi

wt_path=$(jq -r '.patches[] | select(.local_path == "vendor/src") | .worktree' .cross/metadata.json)
[ -n "$wt_path" ] || fail "metadata missing the vendor/src worktree"
local_abs=$(cd vendor/src && pwd -P)
wt_abs=$(cd "$wt_path" && pwd -P)

# ---------------------------------------------------------------- Go section
if [ -n "$GO_BIN" ]; then
    log_header "017: Go cd/wt print one absolute path"
    out=$("$GO_BIN" cd vendor/src 2>/dev/null) || fail "Go cd with a path failed"
    assert_one_abs_path "Go cd vendor/src" "$out" "$local_abs"

    out=$("$GO_BIN" wt vendor/src 2>/dev/null) || fail "Go wt with a path failed"
    assert_one_abs_path "Go wt vendor/src" "$out" "$wt_abs"
    log_success "Go prints absolute paths"

    log_header "017: Go fzf-missing fallback prints rows and exits 1"
    nofzf_path=$(make_path_without_fzf "$SANDBOX/no-fzf-bin")

    cd_rc=0
    cd_out=$(PATH="$nofzf_path" "$GO_BIN" cd 2>"$SANDBOX/cd.err") || cd_rc=$?
    echo "$cd_out"
    echo "--- stderr ---"
    cat "$SANDBOX/cd.err"
    [ "$cd_rc" -eq 1 ] || fail "Go cd without fzf should exit 1, got $cd_rc"
    printf '%s\n' "$cd_out" | cut -f1 | grep -qx "vendor/src" \
        || fail "Go cd fallback should list local_path rows"
    printf '%s\n' "$cd_out" | cut -f2 | grep -q '^\.cross/worktrees/demo_' \
        || fail "Go cd fallback should list worktree rows"
    assert_contains "$(cat "$SANDBOX/cd.err")" "fzf is not installed" \
        "Go cd fallback should say fzf is missing"

    wt_rc=0
    wt_out=$(PATH="$nofzf_path" "$GO_BIN" wt 2>"$SANDBOX/wt.err") || wt_rc=$?
    echo "$wt_out"
    [ "$wt_rc" -eq 1 ] || fail "Go wt without fzf should exit 1, got $wt_rc"
    printf '%s\n' "$wt_out" | cut -f2 | grep -q '^\.cross/worktrees/demo_' \
        || fail "Go wt fallback should list worktree rows"
    assert_contains "$(cat "$SANDBOX/wt.err")" "fzf is not installed" \
        "Go wt fallback should say fzf is missing"
    log_success "Go fzf-missing fallback verified"

    log_header "017: Go no-path cd/wt auto-detect from CWD"
    pushd vendor/src >/dev/null
    out=$(PATH="$nofzf_path" "$GO_BIN" cd 2>/dev/null) \
        || fail "Go cd without a path inside a patch should auto-detect"
    assert_one_abs_path "Go cd (CWD auto-detect)" "$out" "$local_abs"

    out=$(PATH="$nofzf_path" "$GO_BIN" wt 2>/dev/null) \
        || fail "Go wt without a path inside a patch should auto-detect"
    assert_one_abs_path "Go wt (CWD auto-detect)" "$out" "$wt_abs"
    popd >/dev/null
    log_success "Go CWD auto-detect verified"

    log_header "017: Go fzf selection prints the selected path"
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
    selection="demo\tsrc\tvendor/src"

    out=$(FZF_SELECT="$selection" PATH="$shim_dir:$PATH" "$GO_BIN" cd 2>/dev/null) \
        || fail "Go cd with an fzf selection failed"
    assert_one_abs_path "Go cd (fzf)" "$out" "$local_abs"

    out=$(FZF_SELECT="$selection" PATH="$shim_dir:$PATH" "$GO_BIN" wt 2>/dev/null) \
        || fail "Go wt with an fzf selection failed"
    assert_one_abs_path "Go wt (fzf)" "$out" "$wt_abs"
    log_success "Go fzf selection verified"
else
    echo "SKIP: Go CLI unavailable; skipping Go cd/wt assertions"
fi

# -------------------------------------------------------------- Just section
if command -v fish >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v just >/dev/null 2>&1; then
    log_header "017: Just cd/wt print one absolute path"
    out=$(just cross cd vendor/src 2>/dev/null) || fail "Just cd with a path failed"
    assert_one_abs_path "Just cd vendor/src" "$out" "$local_abs"

    out=$(just cross wt vendor/src 2>/dev/null) || fail "Just wt with a path failed"
    assert_one_abs_path "Just wt vendor/src" "$out" "$wt_abs"
    log_success "Just prints absolute paths"

    log_header "017: Just fzf-missing fallback prints rows and exits 1"
    nofzf_path=$(make_path_without_fzf "$SANDBOX/no-fzf-bin")

    cd_rc=0
    cd_out=$(PATH="$nofzf_path" just cross cd 2>&1) || cd_rc=$?
    echo "$cd_out"
    [ "$cd_rc" -eq 1 ] || fail "Just cd without fzf should exit 1, got $cd_rc"
    if ! printf '%s\n' "$cd_out" | awk -F'\t' '$1=="vendor/src"{found=1} END{exit found?0:1}'; then
        fail "Just cd fallback should list local_path<TAB>worktree rows"
    fi
    assert_contains "$cd_out" "fzf is not installed" "Just cd fallback should say fzf is missing"

    wt_rc=0
    wt_out=$(PATH="$nofzf_path" just cross wt 2>&1) || wt_rc=$?
    echo "$wt_out"
    [ "$wt_rc" -eq 1 ] || fail "Just wt without fzf should exit 1, got $wt_rc"
    assert_contains "$wt_out" "fzf is not installed" "Just wt fallback should say fzf is missing"
    log_success "Just fzf-missing fallback verified"
else
    echo "SKIP: fish and/or jq/just unavailable; skipping Just cd/wt assertions"
fi

echo "Test 017 passed!"
