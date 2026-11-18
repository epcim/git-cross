#!/usr/bin/env bash
# Test 019: whole-repo patches (remote path ".") + row-based patch listing.
#
# Covers the UX refresh contract:
#   - the worktree's `.git` pointer must not count as a local change, so
#     `update` re-syncs and `status` reports Clean for whole-repo patches
#   - `diff` shows real changes and never the `.git` pointer
#   - bare `git-cross` and an unresolved `compare` print machine-parseable
#     rows (`local_path<TAB>worktree`) instead of a Usage dump
#   - `cross.dirdifftool` template placeholders receive repo-relative paths
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
    "$GO_BIN" patch "up:." ./sub >/dev/null
    assert_file_exists "sub/README.md"
    assert_file_exists "sub/docs/guide.md"
    log_success "whole-repo patch created at sub/"

    # --- upstream commit + update must re-sync without a .git false positive
    log_header "019: update re-syncs whole-repo patch (no .git false positive)"
    pushd "$upstream_path" >/dev/null
    echo "docs v2 upstream, longer content" > docs/guide.md
    echo "brand new" > new-file.txt
    git add -A
    git commit -m "Upstream v2" -q
    popd >/dev/null

    update_output=$("$GO_BIN" update 2>&1)
    echo "$update_output"
    assert_not_contains "$update_output" "differs from upstream" \
        "update falsely reported local edits for a whole-repo patch (.git leak)"
    assert_grep "sub/docs/guide.md" "docs v2"
    assert_file_exists "sub/new-file.txt"
    assert_grep "sub/new-file.txt" "brand new"
    log_success "update re-synced the whole-repo patch"

    # --- status must not report Modified just because of the .git pointer
    log_header "019: status reports Clean for a synced whole-repo patch"
    status_output=$("$GO_BIN" status 2>&1)
    echo "$status_output"
    sub_line=$(printf '%s\n' "$status_output" | grep -E '(^|[[:space:]])sub([[:space:]]|$)' | head -n 1)
    [ -n "$sub_line" ] || fail "status did not list the whole-repo patch 'sub'"
    assert_contains "$sub_line" "Clean" "status reported a non-Clean diff for a synced whole-repo patch"
    assert_not_contains "$sub_line" "Modified" "status falsely reported Modified (worktree .git leak)"
    log_success "status reports Clean"

    # --- diff shows the real change, never the .git pointer
    log_header "019: diff shows real content and excludes .git"
    echo "local docs tweak" >> sub/docs/guide.md
    diff_output=$("$GO_BIN" diff sub 2>&1 || true)
    echo "$diff_output"
    assert_contains "$diff_output" "local docs tweak"
    assert_not_contains "$diff_output" ".git" "diff must not include the worktree .git pointer file"
    log_success "diff excludes .git"

    # --- bare command + unresolved compare print rows (fzf absent)
    log_header "019: bare listing and unresolved compare print rows"
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
    printf '%s\n' "$bare_stdout" | cut -f2 | grep -q '^\.cross/worktrees/up_' \
        || fail "bare listing missing worktree path in the second column"
    log_success "bare 'git-cross' prints local_path<TAB>worktree rows"

    compare_rc=0
    compare_stdout=$(PATH="$nofzf_path" "$GO_BIN" compare 2>"$SANDBOX/compare.err") || compare_rc=$?
    echo "$compare_stdout"
    echo "--- stderr ---"
    cat "$SANDBOX/compare.err"
    [ "$compare_rc" -eq 1 ] || fail "unresolved 'compare' should exit 1, got $compare_rc"
    assert_not_contains "$compare_stdout" "Usage:" "unresolved 'compare' should not print a Usage dump"
    printf '%s\n' "$compare_stdout" | cut -f1 | grep -qx "sub" \
        || fail "unresolved 'compare' should list 'sub' in the first column"
    if ! grep -Eq "fzf is not installed|No patch detected" "$SANDBOX/compare.err"; then
        fail "unresolved 'compare' should explain why it could not pick a patch"
    fi
    log_success "unresolved 'compare' prints rows and exits 1"

    # --- diffTool template substitution uses repo-relative paths
    log_header "019: cross.dirdifftool {left}/{right} template substitution"
    git config cross.dirdifftool 'echo TOOL {left} {right}'

    tool_out=$("$GO_BIN" compare sub 2>&1 || true)
    echo "$tool_out"
    printf '%s\n' "$tool_out" | grep -Eq "TOOL \.cross/worktrees/up_[0-9a-f]+ sub" \
        || fail "expected 'TOOL .cross/worktrees/up_<hash> sub', got: $tool_out"
    assert_not_contains "$tool_out" "$SANDBOX" \
        "template placeholders must be substituted with repo-relative paths"

    alias_out=$("$GO_BIN" cmp sub 2>&1 || true)
    echo "$alias_out"
    assert_contains "$alias_out" "TOOL .cross/worktrees/up_" "the 'cmp' alias should behave like 'compare'"
    git config --unset cross.dirdifftool || true
    log_success "diffTool template substitution verified"
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
    just cross patch "up:." ./sub >/dev/null
    assert_file_exists "sub/README.md"

    pushd "$upstream_path" >/dev/null
    echo "docs v2 upstream, longer content" > docs/guide.md
    echo "brand new" > new-file.txt
    git add -A
    git commit -m "Upstream v2" -q
    popd >/dev/null

    update_output=$(just cross update 2>&1)
    echo "$update_output"
    assert_not_contains "$update_output" "differs from upstream" \
        "Just update falsely reported local edits for a whole-repo patch (.git leak)"
    assert_grep "sub/docs/guide.md" "docs v2"
    assert_file_exists "sub/new-file.txt"

    status_output=$(just cross status 2>&1)
    echo "$status_output"
    sub_line=$(printf '%s\n' "$status_output" | grep -E '(^|[[:space:]])sub([[:space:]]|$)' | head -n 1)
    [ -n "$sub_line" ] || fail "Just status did not list the whole-repo patch 'sub'"
    assert_contains "$sub_line" "Clean" "Just status reported a non-Clean diff for a synced whole-repo patch"

    echo "local docs tweak" >> sub/docs/guide.md
    diff_output=$(just cross diff sub 2>&1 || true)
    echo "$diff_output"
    assert_contains "$diff_output" "local docs tweak"
    assert_not_contains "$diff_output" ".git" "Just diff must not include the worktree .git pointer file"

    nofzf_path=$(make_path_without_fzf "$SANDBOX/no-fzf-bin")
    compare_rc=0
    compare_output=$(PATH="$nofzf_path" just cross compare 2>&1) || compare_rc=$?
    echo "$compare_output"
    [ "$compare_rc" -eq 1 ] || fail "Just unresolved 'compare' should exit 1, got $compare_rc"
    assert_not_contains "$compare_output" "Usage:" "Just unresolved 'compare' should not print a Usage dump"
    if ! printf '%s\n' "$compare_output" | awk -F'\t' '$1=="sub"{found=1} END{exit found?0:1}'; then
        fail "Just unresolved 'compare' should print local_path<TAB>worktree rows"
    fi
    if ! printf '%s\n' "$compare_output" | grep -Eq "fzf is not installed|No patch detected"; then
        fail "Just unresolved 'compare' should explain why it could not pick a patch"
    fi
    log_success "Just whole-repo patch behavior verified"
else
    echo "SKIP: fish and/or jq/just unavailable; skipping Just whole-repo assertions"
fi

echo "Test 019 passed!"
