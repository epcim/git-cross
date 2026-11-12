#!/usr/bin/env bash
# Test 021: fzf selection ladder for `diff` / `compare`.
#
# Contract:
#   inside a patched directory -> CWD auto-detect (fzf is never consulted)
#   outside, fzf available     -> interactive selection, then act on it
#   outside, fzf missing       -> rows + hint, exit 1
source "$(dirname "$0")/common.sh"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO_BIN="$(ensure_go_bin "$PROJECT_ROOT")"

# Scratch space for the PATH toy-boxes (kept outside the repo).
TEST_TMP=$(mktemp -d)

# Make sure the "no fzf" PATH is computed before any shim is added.
nofzf_path=$(make_path_without_fzf "$TEST_TMP/no-fzf-bin")

# An fzf stand-in: swallows the candidate list and prints FZF_SELECT
# (printf %b expands the \t used in the row payloads).
fzf_shim_dir="$TEST_TMP/fzf-shim-bin"
mkdir -p "$fzf_shim_dir"
cat > "$fzf_shim_dir/fzf" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
if [ -n "${FZF_SELECT:-}" ]; then
    printf '%b\n' "$FZF_SELECT"
    exit 0
fi
exit 130
EOF
chmod +x "$fzf_shim_dir/fzf"

# ---------------------------------------------------------------- Go section
if [ -n "$GO_BIN" ]; then
    cd "$PROJECT_ROOT"
    setup_sandbox
    cd "$SANDBOX"

    upstream_path=$(create_upstream "fzf-demo")
    pushd "$upstream_path" >/dev/null
    mkdir -p src/alpha src/beta
    echo "alpha v1" > src/alpha/alpha.txt
    echo "beta v1" > src/beta/beta.txt
    git add src
    git commit -m "Add alpha and beta" -q
    popd >/dev/null
    upstream_url="file://$upstream_path"

    "$GO_BIN" use upstream "$upstream_url" >/dev/null
    "$GO_BIN" patch upstream:src/alpha vendor/alpha >/dev/null
    "$GO_BIN" patch upstream:src/beta vendor/beta >/dev/null
    echo "local alpha change" >> vendor/alpha/alpha.txt
    echo "local beta change" >> vendor/beta/beta.txt

    # --- fzf absent: rows + hint, exit 1
    log_header "021: Go diff/compare without fzf print rows and exit 1"
    diff_rc=0
    diff_out=$(PATH="$nofzf_path" "$GO_BIN" diff 2>"$SANDBOX/diff.err") || diff_rc=$?
    echo "$diff_out"
    echo "--- stderr ---"
    cat "$SANDBOX/diff.err"
    [ "$diff_rc" -eq 1 ] || fail "Go diff without fzf should exit 1, got $diff_rc"
    assert_not_contains "$diff_out" "Usage:" "diff should print rows, not a Usage dump"
    printf '%s\n' "$diff_out" | cut -f1 | grep -qx "vendor/alpha" \
        || fail "diff rows missing 'vendor/alpha'"
    printf '%s\n' "$diff_out" | cut -f1 | grep -qx "vendor/beta" \
        || fail "diff rows missing 'vendor/beta'"
    assert_contains "$(cat "$SANDBOX/diff.err")" "fzf is not installed" \
        "diff should explain that fzf is missing"

    compare_rc=0
    compare_out=$(PATH="$nofzf_path" "$GO_BIN" compare 2>"$SANDBOX/compare.err") || compare_rc=$?
    echo "$compare_out"
    [ "$compare_rc" -eq 1 ] || fail "Go compare without fzf should exit 1, got $compare_rc"
    assert_not_contains "$compare_out" "Usage:" "compare should print rows, not a Usage dump"
    printf '%s\n' "$compare_out" | cut -f1 | grep -qx "vendor/alpha" \
        || fail "compare rows missing 'vendor/alpha'"
    assert_contains "$(cat "$SANDBOX/compare.err")" "fzf is not installed" \
        "compare should explain that fzf is missing"
    log_success "fzf-missing fallback verified"

    # --- fzf shim: selection drives diff/compare
    log_header "021: Go diff/compare operate on the fzf selection"
    sel_alpha='vendor/alpha    upstream:.\tvendor/alpha'
    sel_beta='vendor/beta    upstream:.\tvendor/beta'

    out=$(FZF_SELECT="$sel_alpha" PATH="$fzf_shim_dir:$PATH" "$GO_BIN" diff 2>&1) || true
    echo "$out"
    assert_contains "$out" "local alpha change" "diff should operate on the selected alpha patch"
    assert_not_contains "$out" "local beta change" "diff should not include the unselected beta patch"

    out=$(FZF_SELECT="$sel_beta" PATH="$fzf_shim_dir:$PATH" "$GO_BIN" diff 2>&1) || true
    echo "$out"
    assert_contains "$out" "local beta change" "diff should operate on the selected beta patch"
    assert_not_contains "$out" "local alpha change" "diff should not include the unselected alpha patch"

    git config cross.diffTool 'echo TOOL {left} {right}'
    out=$(FZF_SELECT="$sel_alpha" PATH="$fzf_shim_dir:$PATH" "$GO_BIN" compare 2>&1) || true
    echo "$out"
    assert_contains "$out" "TOOL .cross/worktrees/upstream_" "compare should run the tool on the selected worktree"
    assert_contains "$out" "vendor/alpha" "compare should run the tool on the selected local path"
    assert_not_contains "$out" "vendor/beta" "compare should not touch the unselected patch"

    out=$(FZF_SELECT="$sel_beta" PATH="$fzf_shim_dir:$PATH" "$GO_BIN" cmp 2>&1) || true
    echo "$out"
    assert_contains "$out" "vendor/beta" "the 'cmp' alias should use the fzf selection"
    assert_not_contains "$out" "vendor/alpha"
    git config --unset cross.diffTool || true
    log_success "fzf selection drives diff/compare"

    # --- default diff tool: nvim preferred, vim fallback
    log_header "021: default diffTool prefers nvim, falls back to vim"
    git config --unset cross.diffTool || true
    both_shims="$SANDBOX/editor-shims"
    vim_shims="$SANDBOX/vim-shims"
    mkdir -p "$both_shims" "$vim_shims"
    for ed in nvim vim; do
        cat > "$both_shims/$ed" <<SH
#!/bin/sh
printf 'EDITOR:$ed\n'
printf 'ARG:%s\n' "\$@"
SH
        chmod +x "$both_shims/$ed"
    done
    cat > "$vim_shims/vim" <<'SH'
#!/bin/sh
printf 'EDITOR:vim\n'
printf 'ARG:%s\n' "$@"
SH
    chmod +x "$vim_shims/vim"

    out=$(PATH="$both_shims:$PATH" "$GO_BIN" compare vendor/alpha 2>/dev/null)
    echo "$out"
    assert_contains "$out" "EDITOR:nvim" "default tool should prefer nvim when installed"
    assert_contains "$out" "let g:DirDiffExcludes = '.git'" "default tool should set DirDiffExcludes for .git"
    assert_contains "$out" "DirDiff .cross/worktrees/" "both paths should be inside the DirDiff command"

    no_nvim_path=$(make_path_without "$SANDBOX/no-nvim-bin" nvim)
    out=$(PATH="$vim_shims:$no_nvim_path" "$GO_BIN" compare vendor/alpha 2>/dev/null)
    echo "$out"
    assert_contains "$out" "EDITOR:vim" "default tool should fall back to vim when nvim is absent"

    # environment-driven extras (only when cross.diffTool is unset)
    out=$(env -u DIRDIFF_IGNORE -u DIRDIFF_EXCLUDES PATH="$both_shims:$PATH" "$GO_BIN" compare vendor/alpha 2>/dev/null)
    assert_contains "$out" "let g:DirDiffExcludes = '.git'" "minimal default keeps .git excluded"
    assert_not_contains "$out" "DirDiffIgnore" "no ignore argument should be emitted without DIRDIFF_IGNORE"

    out=$(env -u DIRDIFF_IGNORE DIRDIFF_EXCLUDES="vendor,node_modules" PATH="$both_shims:$PATH" "$GO_BIN" compare vendor/alpha 2>/dev/null)
    echo "$out"
    assert_contains "$out" "let g:DirDiffExcludes = '.git,vendor,node_modules'" "DIRDIFF_EXCLUDES should append to the permanent .git"

    out=$(env -u DIRDIFF_EXCLUDES DIRDIFF_IGNORE="github.com,gitlab.com" PATH="$both_shims:$PATH" "$GO_BIN" compare vendor/alpha 2>/dev/null)
    echo "$out"
    assert_contains "$out" "let g:DirDiffIgnore" "DIRDIFF_IGNORE should add an ignore argument"
    assert_contains "$out" "github.com" "ignore regexp should include the first keyword"
    assert_contains "$out" "gitlab.com" "ignore regexp should include the second keyword"
    if ! printf '%s\n' "$out" | grep -qF '\V'; then
        fail "DIRDIFF_IGNORE should use a very-nomagic \\V regexp"
    fi
    log_success "editor selection + env extras verified (nvim preferred, vim fallback)"

    # --- inside a patched dir: CWD auto-detect, no fzf needed
    log_header "021: CWD auto-detect still wins inside a patch directory"
    pushd vendor/alpha >/dev/null
    out=$(PATH="$nofzf_path" "$GO_BIN" diff 2>&1) || true
    echo "$out"
    assert_contains "$out" "local alpha change" "diff inside vendor/alpha should auto-detect"
    assert_not_contains "$out" "local beta change"
    assert_not_contains "$out" "fzf is not installed" "auto-detect must not consult fzf"

    git config cross.diffTool 'echo TOOL {left} {right}'
    out=$(PATH="$nofzf_path" "$GO_BIN" compare 2>&1) || true
    echo "$out"
    assert_contains "$out" "TOOL .cross/worktrees/upstream_" "compare inside vendor/alpha should auto-detect"
    assert_contains "$out" "vendor/alpha"
    git config --unset cross.diffTool || true
    popd >/dev/null
    log_success "auto-detect verified"
fi

# -------------------------------------------------------------- Just section
if command -v fish >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v just >/dev/null 2>&1; then
    cd "$PROJECT_ROOT"
    setup_sandbox
    cd "$SANDBOX"

    upstream_path=$(create_upstream "fzf-demo-just")
    pushd "$upstream_path" >/dev/null
    mkdir -p src/alpha src/beta
    echo "alpha v1" > src/alpha/alpha.txt
    echo "beta v1" > src/beta/beta.txt
    git add src
    git commit -m "Add alpha and beta" -q
    popd >/dev/null
    upstream_url="file://$upstream_path"

    just cross use upstream "$upstream_url" >/dev/null
    just cross patch upstream:src/alpha vendor/alpha >/dev/null
    just cross patch upstream:src/beta vendor/beta >/dev/null
    echo "local alpha change" >> vendor/alpha/alpha.txt
    echo "local beta change" >> vendor/beta/beta.txt

    log_header "021: Just diff/compare without fzf print rows and exit 1"
    nofzf_path=$(make_path_without_fzf "$SANDBOX/no-fzf-bin")
    diff_rc=0
    diff_out=$(PATH="$nofzf_path" just cross diff 2>&1) || diff_rc=$?
    echo "$diff_out"
    [ "$diff_rc" -eq 1 ] || fail "Just diff without fzf should exit 1, got $diff_rc"
    assert_not_contains "$diff_out" "Usage:" "Just diff should not print a Usage dump"
    if ! printf '%s\n' "$diff_out" | awk -F'\t' '$1=="vendor/alpha"{found=1} END{exit found?0:1}'; then
        fail "Just diff rows missing 'vendor/alpha'"
    fi
    assert_contains "$diff_out" "fzf is not installed" "Just diff should explain that fzf is missing"

    compare_rc=0
    compare_out=$(PATH="$nofzf_path" just cross compare 2>&1) || compare_rc=$?
    echo "$compare_out"
    [ "$compare_rc" -eq 1 ] || fail "Just compare without fzf should exit 1, got $compare_rc"
    assert_contains "$compare_out" "fzf is not installed" "Just compare should explain that fzf is missing"

    log_header "021: Just diff/compare operate on the fzf selection"
    git config cross.diffTool 'echo TOOL {left} {right}'
    wt_alpha=$(jq -r '.patches[] | select(.local_path == "vendor/alpha") | .worktree' .cross/metadata.json)
    sel_alpha="vendor/alpha    upstream:.\tvendor/alpha"
    out=$(FZF_SELECT="$sel_alpha" PATH="$fzf_shim_dir:$PATH" just cross diff 2>&1) || true
    echo "$out"
    assert_contains "$out" "local alpha change" "Just diff should operate on the selected alpha patch"
    assert_not_contains "$out" "local beta change" "Just diff should not include the unselected beta patch"

    out=$(FZF_SELECT="$sel_alpha" PATH="$fzf_shim_dir:$PATH" just cross compare 2>&1) || true
    echo "$out"
    assert_contains "$out" "vendor/alpha" "Just compare should resolve the selected local path"
    assert_contains "$out" "TOOL .cross/worktrees/upstream_" "Just compare should run the tool on the selected worktree"
    git config --unset cross.diffTool || true

    log_header "021: Just default diffTool prefers nvim"
    just_shims="$SANDBOX/editor-shims-just"
    mkdir -p "$just_shims"
    for ed in nvim vim; do
        printf '#!/bin/sh\nprintf "EDITOR:%s\\n"\nprintf "ARG:%%s\\n" "$@"\n' "$ed" > "$just_shims/$ed"
        chmod +x "$just_shims/$ed"
    done
    out=$(PATH="$just_shims:$PATH" just cross compare vendor/alpha 2>/dev/null)
    echo "$out"
    assert_contains "$out" "EDITOR:nvim" "Just default tool should prefer nvim when installed"
    assert_contains "$out" "let g:DirDiffExcludes = '.git'" "Just default tool should set DirDiffExcludes"
    out=$(env -u DIRDIFF_EXCLUDES DIRDIFF_IGNORE="github.com,gitlab.com" PATH="$just_shims:$PATH" just cross compare vendor/alpha 2>/dev/null)
    echo "$out"
    assert_contains "$out" "let g:DirDiffIgnore" "Just DIRDIFF_IGNORE should add an ignore argument"
    assert_contains "$out" "github.com" "Just ignore regexp should include the keyword"
    log_success "Just editor selection verified"

    log_header "021: Just CWD auto-detect inside a patch directory"
    pushd vendor/alpha >/dev/null
    out=$(PATH="$nofzf_path" just cross diff 2>&1) || true
    echo "$out"
    assert_contains "$out" "local alpha change"
    assert_not_contains "$out" "local beta change"
    assert_not_contains "$out" "fzf is not installed"
    popd >/dev/null
    log_success "Just fzf ladder verified"
else
    echo "SKIP: fish and/or jq/just unavailable; skipping Just fzf assertions"
fi

rm -rf "$TEST_TMP" 2>/dev/null || true
echo "Test 021 passed!"
