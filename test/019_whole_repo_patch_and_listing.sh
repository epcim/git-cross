#!/usr/bin/env bash
# Test 019: whole-repo patches (remote path ".") + row-based patch listing.
#
# v0.5.0 contract:
#   - a whole-repo patch has NO sparse filter, so every upstream file lands in the
#     patch dir; the patch dir never contains a `.git` pointer (nothing to leak)
#   - `update` fast-forwards the work tree in place
#   - `stat` (renamed from status) reports Clean for a synced whole-repo patch
#   - `diff` inside the patch dir shows real content changes
#   - bare `git-cross` prints machine-parseable rows (`local_path<TAB>gitdir`)
#     instead of a Usage dump
#   - `compare`/`cmp` are retired (v0.5.0) and no longer resolve to a command
source "$(dirname "$0")/common.sh"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO_BIN="$(ensure_go_bin "$PROJECT_ROOT")"

if [ -z "$GO_BIN" ]; then
    echo "SKIP: Go CLI unavailable; skipping whole-repo Go assertions"
fi

# ---------------------------------------------------------------- Go section
if [ -n "$GO_BIN" ]; then
    cd "$PROJECT_ROOT"
    setup_sandbox
    cd "$SANDBOX"

    log_header "019: whole-repo patch via Go (remote path '.')"
    upstream_path=$(create_upstream "whole-repo")
    pushd "$upstream_path" >/dev/null
    mkdir -p docs
    echo "docs v1" > docs/guide.md
    git add docs/guide.md
    git commit -m "Add docs" -q
    popd >/dev/null
    upstream_url="file://$upstream_path"

    "$GO_BIN" use up "$upstream_url" >/dev/null
    "$GO_BIN" set "up:." ./sub >/dev/null
    assert_file_exists "sub/README.md"
    assert_file_exists "sub/docs/guide.md"
    # v2: no .git pointer exists in the patch dir at all
    [ ! -e sub/.git ] || fail "whole-repo patch dir must not contain a .git pointer"
    # whole-repo patches are not sparse
    gd=$(jq -r '.patches[] | select(.local_path == "sub") | .gitdir' .cross/metadata.json)
    [ ! -e "$gd/info/sparse-checkout" ] || fail "whole-repo patch must not write a sparse pattern"
    log_success "whole-repo patch created at sub/"

    # --- upstream commit + update must re-sync
    log_header "019: update re-syncs whole-repo patch"
    pushd "$upstream_path" >/dev/null
    echo "docs v2 upstream, longer content" > docs/guide.md
    echo "brand new" > new-file.txt
    git add -A
    git commit -m "Upstream v2" -q
    popd >/dev/null

    update_output=$("$GO_BIN" update 2>&1)
    echo "$update_output"
    assert_not_contains "$update_output" "differs from upstream" \
        "update falsely reported local edits for a whole-repo patch"
    assert_grep "sub/docs/guide.md" "docs v2"
    assert_file_exists "sub/new-file.txt"
    assert_grep "sub/new-file.txt" "brand new"
    log_success "update re-synced the whole-repo patch"

    # --- ls must report Clean (DIFF) for a synced whole-repo cross
    log_header "019: ls reports Clean for a synced whole-repo cross"
    stat_output=$("$GO_BIN" ls 2>&1)
    echo "$stat_output"
    sub_line=$(printf '%s\n' "$stat_output" | grep -E '(^|[[:space:]])sub([[:space:]]|$)' | head -n 1)
    [ -n "$sub_line" ] || fail "ls did not list the whole-repo cross 'sub'"
    assert_contains "$sub_line" "Clean" "ls reported a non-Clean DIFF for a synced whole-repo cross"
    assert_not_contains "$sub_line" "Modified" "ls falsely reported Modified"
    log_success "ls reports Clean"

    # --- diff inside the patch dir shows the real change
    log_header "019: diff inside the patch dir shows real content"
    echo "local docs tweak" >> sub/docs/guide.md
    diff_output=$(cd sub && "$GO_BIN" diff 2>&1 || true)
    echo "$diff_output"
    assert_contains "$diff_output" "local docs tweak"
    assert_not_contains "$diff_output" ".git" "diff must not mention a .git pointer"
    log_success "diff shows the change"

    # --- bare command prints rows; a retired subcommand does not dump Usage
    log_header "019: bare listing and retired 'compare'"
    nofzf_path=$(make_path_without_fzf "$SANDBOX/no-fzf-bin")

    bare_rc=0
    bare_stdout=$(PATH="$nofzf_path" "$GO_BIN" 2>"$SANDBOX/bare.err") || bare_rc=$?
    echo "$bare_stdout"
    [ "$bare_rc" -eq 0 ] || fail "bare 'git-cross' should exit 0, got $bare_rc"
    assert_not_contains "$bare_stdout" "Usage:" "bare 'git-cross' should not print a Usage dump"
    assert_not_contains "$bare_stdout" "Patches (" "bare 'git-cross' should not print a hint line"
    if ! printf '%s\n' "$bare_stdout" | grep -q "$(printf '\t')"; then
        fail "piped bare listing must stay TAB-separated"
    fi
    printf '%s\n' "$bare_stdout" | cut -f1 | grep -qx "sub" \
        || fail "bare listing missing local_path 'sub' in the first column"
    printf '%s\n' "$bare_stdout" | cut -f2 | grep -q '^\.cross/worktrees/up/' \
        || fail "bare listing missing the gitdir in the second column"
    log_success "bare 'git-cross' prints local_path<TAB>gitdir rows"

    # `compare` is gone in v0.5.0; an unknown subcommand must not dump Usage.
    unknown_rc=0
    unknown_out=$(PATH="$nofzf_path" "$GO_BIN" compare 2>"$SANDBOX/unknown.err") || unknown_rc=$?
    echo "$unknown_out"; echo "--- stderr ---"; cat "$SANDBOX/unknown.err"
    [ "$unknown_rc" -ne 0 ] || fail "'compare' must not resolve to a cross command any more"
    assert_not_contains "$unknown_out" "Usage:" "retired 'compare' should not print a Usage dump"
    log_success "retired 'compare' fails without a Usage dump"
fi

# -------------------------------------------------------------- Just section
if command -v fish >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v just >/dev/null 2>&1; then
    cd "$PROJECT_ROOT"
    setup_sandbox
    cd "$SANDBOX"

    log_header "019: whole-repo patch via Just/Fish"
    upstream_path=$(create_upstream "whole-repo-just")
    pushd "$upstream_path" >/dev/null
    mkdir -p docs
    echo "docs v1" > docs/guide.md
    git add docs/guide.md
    git commit -m "Add docs" -q
    popd >/dev/null
    upstream_url="file://$upstream_path"

    just cross use up "$upstream_url" >/dev/null
    just cross set "up:." ./sub >/dev/null
    assert_file_exists "sub/README.md"
    [ ! -e sub/.git ] || fail "Just: whole-repo patch dir must not contain a .git pointer"

    pushd "$upstream_path" >/dev/null
    echo "docs v2 upstream, longer content" > docs/guide.md
    echo "brand new" > new-file.txt
    git add -A
    git commit -m "Upstream v2" -q
    popd >/dev/null

    # v0.5.1: update is Go-only in the Just reference (stub) — the landing flow is
    # covered by the Go variant above; here the stub contract is what is left.
    update_output=$(just cross update 2>&1); update_rc=$?
    echo "$update_output"
    assert_contains "$update_output" "NOT IMPLEMENTED" "Just update must be a Go-only stub (v0.5.1)"
    [ "$update_rc" -ne 0 ] || fail "Just update stub must exit 1"

    stat_output=$(just cross ls 2>&1)
    echo "$stat_output"
    sub_line=$(printf '%s\n' "$stat_output" | grep -E '(^|[[:space:]])sub([[:space:]]|$)' | head -n 1)
    [ -n "$sub_line" ] || fail "Just ls did not list the whole-repo cross 'sub'"
    assert_contains "$sub_line" "Clean" "Just ls reported a non-Clean DIFF for a synced whole-repo cross"

    echo "local docs tweak" >> sub/docs/guide.md
    diff_output=$(cd sub && just cross diff 2>&1 || true)
    echo "$diff_output"
    assert_contains "$diff_output" "local docs tweak"
    assert_not_contains "$diff_output" ".git" "Just diff must not mention a .git pointer"

    # `compare` is retired: the Justfile has no such recipe, so it is not a cross
    # command any more (the root wrapper falls through / errors).
    compare_rc=0
    compare_output=$(just cross compare 2>&1) || compare_rc=$?
    echo "$compare_output"
    [ "$compare_rc" -ne 0 ] || fail "Just 'compare' must not be a recipe any more"
    log_success "Just whole-repo patch behavior verified"
else
    echo "SKIP: fish and/or jq/just unavailable; skipping Just whole-repo assertions"
fi

echo "Test 019 passed!"
