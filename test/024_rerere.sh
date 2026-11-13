#!/usr/bin/env bash
# Test 024: rerere (reuse recorded resolution) — conflict resolution memory.
#
# Covers:
#   - `init` enables rerere.enabled and reports it (and says "already enabled"
#     on a second run)
#   - `patch` enables it silently in the shared repo config, so the setting is
#     also visible from inside every cross worktree
#   - `update` re-enables it (self-heal for repositories patched before the
#     feature existed)
#   - functionally: a conflict resolved once inside a cross worktree is
#     replayed automatically when the same conflict reappears
source "$(dirname "$0")/common.sh"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO_BIN="$(ensure_go_bin "$PROJECT_ROOT")"

if [ -z "$GO_BIN" ]; then
    echo "SKIP: Go CLI unavailable; skipping rerere Go assertions"
fi

has_fish() { command -v fish >/dev/null 2>&1; }

# Enable rerere straight from a repo/worktree and print the effective value.
rerere_value() {
    git -C "$1" config --get rerere.enabled 2>/dev/null || true
}

# ---------------------------------------------------------------- Go section
if [ -n "$GO_BIN" ]; then
    cd "$PROJECT_ROOT"
    setup_sandbox
    cd "$SANDBOX"

    log_header "024: init enables rerere (Go)"
    init_out=$("$GO_BIN" init 2>&1)
    assert_contains "$init_out" "Enabled rerere" "init should announce rerere"
    test "$(rerere_value "$SANDBOX")" = true || fail "rerere.enabled not set after init"

    log_header "024: second init reports rerere already enabled (Go)"
    init_out=$("$GO_BIN" init 2>&1)
    assert_contains "$init_out" "rerere already enabled" "second init should say already enabled"

    log_header "024: patch enables rerere for worktrees (Go)"
    upstream_path=$(create_upstream "rerere-go")
    pushd "$upstream_path" >/dev/null
    mkdir -p docs
    printf 'line one\n' > docs/a.md
    git add docs/a.md
    git commit -m "Add docs" -q
    popd >/dev/null
    upstream_url="file://$upstream_path"

    git config --unset rerere.enabled || true
    "$GO_BIN" use up "$upstream_url" >/dev/null 2>&1 || fail "git-cross use failed"
    "$GO_BIN" patch up:main:docs docs >/dev/null 2>&1 || fail "git-cross patch failed"

    test "$(rerere_value "$SANDBOX")" = true || fail "patch did not enable rerere in the shared config"
    wt=$(find .cross/worktrees -maxdepth 1 -mindepth 1 -type d | head -1)
    [ -n "$wt" ] || fail "no worktree under .cross/worktrees"
    test "$(rerere_value "$wt")" = true || fail "rerere.enabled not visible from inside the worktree"

    log_header "024: update self-heals rerere (Go)"
    git config --unset rerere.enabled || true
    update_out=$("$GO_BIN" update 2>&1)
    assert_contains "$update_out" "Enabled rerere" "update should re-enable a missing rerere setting"
    test "$(rerere_value "$SANDBOX")" = true || fail "update did not restore rerere.enabled"

    # ------------------------------------------------- functional rerere ---
    log_header "024: a recorded conflict resolution is reused (Go worktree)"
    wt_abs="$SANDBOX/$wt"

    # Local divergence inside the worktree (this is the "local overlay" edit).
    printf 'line one\nlocal change\n' > "$wt_abs/docs/a.md"
    git -C "$wt_abs" add docs/a.md
    git -C "$wt_abs" commit -m "local edit" -q || fail "could not commit local edit in worktree"

    # Same hunk diverges upstream.
    pushd "$upstream_path" >/dev/null
    printf 'line one\nupstream change\n' > docs/a.md
    git add docs/a.md
    git commit -m "upstream edit" -q
    popd >/dev/null

    git -C "$wt_abs" fetch up main -q || fail "could not fetch upstream into worktree"
    pre_merge=$(git -C "$wt_abs" rev-parse HEAD)

    set +e
    git -C "$wt_abs" merge up/main >/dev/null 2>&1
    merge_rc=$?
    set -e
    [ "$merge_rc" -ne 0 ] || fail "expected a conflict on the first merge"

    rr_cache=$(git -C "$wt_abs" rev-parse --git-path rr-cache)
    [ -d "$rr_cache" ] || fail "rerere cache not created at $rr_cache"

    # Resolve manually: this is the step rerere must remember.
    printf 'line one\nresolved line\n' > "$wt_abs/docs/a.md"
    git -C "$wt_abs" add docs/a.md
    git -C "$wt_abs" commit -m "merge upstream with resolution" -q || fail "could not commit resolution"
    preimage_present=$(find "$rr_cache" -type f -name preimage 2>/dev/null | head -1)
    [ -n "$preimage_present" ] || fail "rerere preimage was not recorded"

    # Replay the identical conflict; rerere must reapply the resolution.
    git -C "$wt_abs" reset --hard "$pre_merge" -q || fail "could not reset to pre-merge state"
    set +e
    replay_out=$(git -C "$wt_abs" merge up/main 2>&1)
    replay_rc=$?
    set -e
    # Without rerere.autoUpdate the merge still stops and the index stays
    # unmerged; what matters is the working-tree file being pre-resolved.
    [ "$replay_rc" -ne 0 ] || fail "merge should still require a commit without rerere.autoUpdate"
    assert_contains "$replay_out" "Resolved 'docs/a.md' using previous resolution" \
        "rerere should reuse the recorded resolution on replay"

    if grep -q '^<<<<<<<' "$wt_abs/docs/a.md"; then
        fail "rerere did not reuse the recorded resolution (conflict markers remain)"
    fi
    grep -qx 'resolved line' "$wt_abs/docs/a.md" || fail "rerere did not reapply the recorded resolution"

    git -C "$wt_abs" add docs/a.md
    git -C "$wt_abs" commit -m "second merge with reused resolution" -q || fail "could not commit replayed merge"
fi

# -------------------------------------------------------------- Just section
if has_fish; then
    cd "$PROJECT_ROOT"
    setup_sandbox
    cd "$SANDBOX"

    log_header "024: init enables rerere (Just/Fish)"
    init_out=$(just cross init 2>&1)
    assert_contains "$init_out" "Enabled rerere" "Just init should announce rerere"
    test "$(rerere_value "$SANDBOX")" = true || fail "Just init did not set rerere.enabled"

    init_out=$(just cross init 2>&1)
    assert_contains "$init_out" "rerere already enabled" "second Just init should say already enabled"

    log_header "024: patch enables rerere (Just/Fish)"
    upstream_path=$(create_upstream "rerere-just")
    pushd "$upstream_path" >/dev/null
    mkdir -p docs
    printf 'just line\n' > docs/a.md
    git add docs/a.md
    git commit -m "Add docs" -q
    popd >/dev/null

    git config --unset rerere.enabled || true
    just cross use up "file://$upstream_path" >/dev/null 2>&1 || fail "just cross use failed"
    just cross patch up:main:docs docs >/dev/null 2>&1 || fail "just cross patch failed"

    test "$(rerere_value "$SANDBOX")" = true || fail "Just patch did not enable rerere"
    wt=$(find .cross/worktrees -maxdepth 1 -mindepth 1 -type d | head -1)
    [ -n "$wt" ] || fail "no worktree after Just patch"
    test "$(rerere_value "$wt")" = true || fail "Just patch: rerere not visible from the worktree"

    log_header "024: update self-heals rerere (Just/Fish)"
    git config --unset rerere.enabled || true
    update_out=$(just cross update 2>&1)
    assert_contains "$update_out" "Enabled rerere" "Just update should re-enable rerere"
    test "$(rerere_value "$SANDBOX")" = true || fail "Just update did not restore rerere.enabled"
else
    echo "SKIP: fish unavailable; skipping Just/Fish rerere assertions"
fi

log_success "024: rerere configuration and resolution reuse verified"
