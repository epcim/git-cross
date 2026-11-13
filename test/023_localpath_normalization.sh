#!/usr/bin/env bash
# Test 023: local_path normalization (`./sub` must behave like `sub`).
#
# Regression: `patch <remote>:./sub` stored "./sub" in metadata, so CWD
# auto-detection, compare/diff/cd/status and `remove ./sub` failed to match.
source "$(dirname "$0")/common.sh"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO_BIN="$(ensure_go_bin "$PROJECT_ROOT")"

assert_metadata_normalized() {
    local meta=".cross/metadata.json"
    jq -r '.patches[].local_path' "$meta" | grep -qx "sub" || fail "metadata missing normalized local_path 'sub'"
    jq -r '.patches[].local_path' "$meta" | grep -qx "sub2" || fail "metadata missing normalized local_path 'sub2'"
    if jq -e '.patches[] | select(.local_path | startswith("./"))' "$meta" >/dev/null 2>&1; then
        fail "metadata still contains a './' prefixed local_path"
        jq -r '.patches[].local_path' "$meta" | sed 's/^/  /' >&2
    fi
}

assert_one_abs_path() {
    local label=$1
    local output=$2
    local expected=$3
    local line_count
    line_count=$(printf '%s\n' "$output" | sed '/^$/d' | wc -l | tr -d ' ')
    [ "$line_count" -eq 1 ] || fail "$label: expected exactly one line of output, got $line_count: $output"
    case "$output" in
        /*) ;;
        *) fail "$label: expected an absolute path, got: $output" ;;
    esac
    assert_not_contains "$output" "Opening shell" "$label: must not mention opening a shell"
    assert_not_contains "$output" "clipboard" "$label: must not copy to the clipboard"
    [ "$output" = "$expected" ] || fail "$label: expected '$expected', got '$output'"
}

# ---------------------------------------------------------------- Go section
if [ -n "$GO_BIN" ]; then
    cd "$PROJECT_ROOT"
    setup_sandbox
    cd "$SANDBOX"

    upstream_path=$(create_upstream "normalize-demo")
    pushd "$upstream_path" >/dev/null
    mkdir -p pkg
    echo "root v1" > root.txt
    echo "pkg v1" > pkg/pkg.txt
    git add root.txt pkg/pkg.txt
    git commit -m "Add content" -q
    popd >/dev/null
    upstream_url="file://$upstream_path"

    log_header "023: patch with './' prefixed local paths (Go)"
    "$GO_BIN" use up "$upstream_url" >/dev/null
    "$GO_BIN" patch "up:main:." ./sub >/dev/null
    "$GO_BIN" patch "up:main:pkg" ./sub2 >/dev/null
    assert_dir_exists "sub"
    assert_dir_exists "sub2"
    assert_metadata_normalized
    log_success "metadata stores local_path without './'"

    log_header "023: one upstream source patched into two local dirs (Go)"
    "$GO_BIN" patch "up:main:pkg" vendor/a >/dev/null
    "$GO_BIN" patch "up:main:pkg" vendor/b >/dev/null
    assert_dir_exists "vendor/a"
    assert_dir_exists "vendor/b"
    [ -f vendor/a/pkg.txt ] || fail "vendor/a was not synced"
    [ -f vendor/b/pkg.txt ] || fail "vendor/b was not synced"
    wt_a=$(jq -r '.patches[] | select(.local_path == "vendor/a") | .worktree' .cross/metadata.json)
    wt_b=$(jq -r '.patches[] | select(.local_path == "vendor/b") | .worktree' .cross/metadata.json)
    [ -n "$wt_a" ] || fail "metadata lost the vendor/a entry for a shared upstream source"
    [ -n "$wt_b" ] || fail "metadata lost the vendor/b entry"
    [ "$wt_a" = "$wt_b" ] || fail "both local dirs should share one worktree (got '$wt_a' vs '$wt_b')"
    grep -q "vendor/a" Crossfile || fail "Crossfile missing the vendor/a declaration"
    grep -q "vendor/b" Crossfile || fail "Crossfile missing the vendor/b declaration"
    log_success "two local dirs share one worktree and two metadata entries"

    log_header "023: removing one local dir keeps the shared worktree (Go)"
    "$GO_BIN" remove vendor/a >/dev/null 2>&1 || fail "remove vendor/a failed"
    [ ! -d vendor/a ] || fail "remove vendor/a left the local directory behind"
    [ -d "$wt_a" ] || fail "removing vendor/a deleted a worktree still used by vendor/b"
    git -C "$wt_a" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || fail "the shared worktree is no longer a valid worktree after remove"
    [ "$(jq -r '.patches[] | select(.local_path == "vendor/b") | .worktree' .cross/metadata.json)" = "$wt_a" ] \
        || fail "vendor/b lost its worktree entry"
    log_success "shared worktree survives removing one of its local dirs"

    git config cross.dirdifftool 'echo TOOL {left} {right}'
    nofzf_path=$(make_path_without_fzf "$SANDBOX/no-fzf-bin")
    wt_sub=$(jq -r '.patches[] | select(.local_path == "sub") | .worktree' .cross/metadata.json)
    wt_sub_abs=$(cd "$wt_sub" && pwd -P)

    log_header "023: compare/diff/cd/status resolve from inside ./sub"
    pushd sub >/dev/null
    out=$("$GO_BIN" compare 2>&1) || fail "compare inside a './sub' patch should resolve"
    echo "$out"
    assert_contains "$out" "TOOL .cross/worktrees/up_" "compare inside ./sub should run the diff tool"
    assert_not_contains "$out" "patch not found"

    echo "local sub change" >> root.txt
    out=$("$GO_BIN" diff 2>&1) || true
    echo "$out"
    assert_contains "$out" "local sub change" "diff inside ./sub should auto-detect the patch"
    assert_not_contains "$out" "patch not found"

    expected=$(pwd -P)
    out=$("$GO_BIN" cd sub 2>/dev/null) || fail "cd sub inside a './sub' patch should resolve"
    assert_one_abs_path "cd sub inside ./sub" "$out" "$expected"

    # No path at all: CWD auto-detect must win before fzf is consulted.
    out=$(PATH="$nofzf_path" "$GO_BIN" cd 2>/dev/null) \
        || fail "cd without a path inside ./sub should auto-detect from CWD"
    assert_one_abs_path "cd (CWD auto-detect) inside ./sub" "$out" "$expected"
    out=$(PATH="$nofzf_path" "$GO_BIN" wt 2>/dev/null) \
        || fail "wt without a path inside ./sub should auto-detect from CWD"
    assert_one_abs_path "wt (CWD auto-detect) inside ./sub" "$out" "$wt_sub_abs"

    out=$("$GO_BIN" status 2>&1) || true
    echo "$out"
    assert_contains "$out" "sub" "status should list the normalized local_path"
    popd >/dev/null

    log_header "023: compare/diff/cd resolve from inside ./sub2"
    pushd sub2 >/dev/null
    out=$("$GO_BIN" compare 2>&1) || fail "compare inside a './sub2' patch should resolve"
    assert_contains "$out" "TOOL .cross/worktrees/up_"
    assert_not_contains "$out" "patch not found"
    echo "local sub2 change" >> pkg.txt
    out=$("$GO_BIN" diff 2>&1) || true
    assert_contains "$out" "local sub2 change"
    expected=$(pwd -P)
    out=$("$GO_BIN" cd sub2 2>/dev/null) || fail "cd sub2 inside a './sub2' patch should resolve"
    assert_one_abs_path "cd sub2 inside ./sub2" "$out" "$expected"
    out=$(PATH="$nofzf_path" "$GO_BIN" cd 2>/dev/null) \
        || fail "cd without a path inside ./sub2 should auto-detect from CWD"
    assert_one_abs_path "cd (CWD auto-detect) inside ./sub2" "$out" "$expected"
    popd >/dev/null

    log_header "023: explicit './' path arguments resolve (Go)"
    out=$("$GO_BIN" compare ./sub 2>&1) || fail "compare ./sub from the repo root should resolve"
    assert_contains "$out" "TOOL .cross/worktrees/up_"

    out=$("$GO_BIN" diff ./sub 2>&1) || true
    assert_contains "$out" "local sub change"

    git config --unset cross.dirdifftool || true

    log_header "023: remove ./sub2 resolves the normalized entry"
    "$GO_BIN" remove ./sub2 >/dev/null 2>&1 || fail "remove ./sub2 should resolve the stored 'sub2' path"
    if [ -d "sub2" ]; then
        fail "remove ./sub2 left the sub2 directory behind"
    fi
    if jq -e '.patches[] | select(.local_path == "sub2")' .cross/metadata.json >/dev/null 2>&1; then
        fail "remove ./sub2 left the entry in metadata"
    fi
    if grep -q "sub2" Crossfile 2>/dev/null; then
        fail "remove ./sub2 left the entry in Crossfile"
    fi
    log_success "normalized './' arguments resolve"
fi

# -------------------------------------------------------------- Just section
if command -v fish >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v just >/dev/null 2>&1; then
    cd "$PROJECT_ROOT"
    setup_sandbox
    cd "$SANDBOX"

    upstream_path=$(create_upstream "normalize-demo-just")
    pushd "$upstream_path" >/dev/null
    mkdir -p pkg
    echo "root v1" > root.txt
    echo "pkg v1" > pkg/pkg.txt
    git add root.txt pkg/pkg.txt
    git commit -m "Add content" -q
    popd >/dev/null
    upstream_url="file://$upstream_path"

    log_header "023: patch with './' prefixed local paths (Just/Fish)"
    just cross use up "$upstream_url" >/dev/null
    just cross patch "up:main:." ./sub >/dev/null
    just cross patch "up:main:pkg" ./sub2 >/dev/null
    assert_metadata_normalized
    log_success "Just metadata stores local_path without './'"

    log_header "023: one upstream source patched into two local dirs (Just/Fish)"
    just cross patch "up:main:pkg" vendor/a >/dev/null
    just cross patch "up:main:pkg" vendor/b >/dev/null
    assert_dir_exists "vendor/a"
    assert_dir_exists "vendor/b"
    [ -f vendor/a/pkg.txt ] || fail "Just vendor/a was not synced"
    [ -f vendor/b/pkg.txt ] || fail "Just vendor/b was not synced"
    wt_a=$(jq -r '.patches[] | select(.local_path == "vendor/a") | .worktree' .cross/metadata.json)
    wt_b=$(jq -r '.patches[] | select(.local_path == "vendor/b") | .worktree' .cross/metadata.json)
    [ -n "$wt_a" ] || fail "Just metadata lost the vendor/a entry for a shared upstream source"
    [ -n "$wt_b" ] || fail "Just metadata lost the vendor/b entry"
    [ "$wt_a" = "$wt_b" ] || fail "Just: both local dirs should share one worktree (got '$wt_a' vs '$wt_b')"
    grep -q "vendor/a" Crossfile || fail "Just Crossfile missing the vendor/a declaration"
    grep -q "vendor/b" Crossfile || fail "Just Crossfile missing the vendor/b declaration"
    log_success "Just: two local dirs share one worktree and two metadata entries"

    log_header "023: Just removing one local dir keeps the shared worktree"
    remove_out=$(just cross remove vendor/a 2>&1) || fail "just cross remove vendor/a failed"
    echo "$remove_out"
    assert_contains "$remove_out" "Keeping worktree" "remove should report that the worktree is still used"
    [ ! -d vendor/a ] || fail "Just remove vendor/a left the local directory behind"
    [ -d "$wt_a" ] || fail "Just remove vendor/a deleted a worktree still used by vendor/b"
    git -C "$wt_a" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || fail "the shared worktree is no longer a valid worktree after Just remove"
    [ "$(jq -r '.patches[] | select(.local_path == "vendor/b") | .worktree' .cross/metadata.json)" = "$wt_a" ] \
        || fail "Just vendor/b lost its worktree entry"
    log_success "Just: shared worktree survives removing one of its local dirs"

    log_header "023: Just compare/diff/cd resolve from inside ./sub"
    git config cross.dirdifftool 'echo TOOL {left} {right}'
    pushd sub >/dev/null
    echo "local sub change" >> root.txt
    out=$(just cross compare 2>&1) || fail "Just compare inside './sub' should resolve"
    echo "$out"
    assert_contains "$out" "TOOL .cross/worktrees/up_" "Just compare inside ./sub should run the diff tool"
    assert_not_contains "$out" "patch not found"

    out=$(just cross diff 2>&1) || true
    echo "$out"
    assert_contains "$out" "local sub change" "Just diff inside ./sub should auto-detect the patch"
    assert_not_contains "$out" "patch not found"

    expected=$(pwd -P)
    out=$(just cross cd sub 2>/dev/null) || fail "Just cd sub inside './sub' should resolve"
    assert_one_abs_path "Just cd sub inside ./sub" "$out" "$expected"
    popd >/dev/null

    pushd sub2 >/dev/null
    echo "local sub2 change" >> pkg.txt
    out=$(just cross compare 2>&1) || fail "Just compare inside './sub2' should resolve"
    assert_contains "$out" "TOOL .cross/worktrees/up_"
    assert_not_contains "$out" "patch not found"
    out=$(just cross diff 2>&1) || true
    assert_contains "$out" "local sub2 change"
    popd >/dev/null
    git config --unset cross.dirdifftool || true

    log_header "023: Just remove ./sub2 resolves the normalized entry"
    just cross remove ./sub2 >/dev/null 2>&1 || fail "Just remove ./sub2 should resolve the stored 'sub2' path"
    if [ -d "sub2" ]; then
        fail "Just remove ./sub2 left the sub2 directory behind"
    fi
    if jq -e '.patches[] | select(.local_path == "sub2")' .cross/metadata.json >/dev/null 2>&1; then
        fail "Just remove ./sub2 left the entry in metadata"
    fi
    log_success "Just normalization verified"
else
    echo "SKIP: fish and/or jq/just unavailable; skipping Just normalization assertions"
fi

echo "Test 023 passed!"
