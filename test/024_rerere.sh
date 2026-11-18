#!/usr/bin/env bash
# Test 024: rerere (reuse recorded resolution) — conflict resolution memory.
#
# v0.5.0 rerere lives in TWO places:
#   - the primary repo config (for commits/rebases of the patched files)
#   - EVERY per-patch gitdir (standalone: it does not inherit the primary config,
#     and keeps its own rr-cache). Enabled at patch time, re-ensured by update.
#
# Flow used here (user-facing, no env plumbing):
#   cd <patch>  ->  git cross pull -r  ->  conflict  ->  git cross add
#                ->  git cross rebase --continue  ->  reset + pull -r again
#   The second pull must reuse the recorded resolution.
source "$(dirname "$0")/common.sh"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO_BIN="$(ensure_go_bin "$PROJECT_ROOT")"

if [ -z "$GO_BIN" ]; then
    echo "SKIP: Go CLI unavailable; skipping rerere Go assertions"
fi

has_fish() { command -v fish >/dev/null 2>&1; }

rerere_value() {
    git -C "$1" config --get rerere.enabled 2>/dev/null || true
}

# rr-cache inside a bare gitdir
rr_cache_of() {
    printf '%s/rr-cache\n' "$1"
}

# exercise <who> — uses xc(), $upstream_path, $PATCH (patch local path)
exercise() {
    local who=$1

    log_header "024: set/init enables rerere in the repo config ($who)"
    init_out=$(xc cfg 2>&1)
    assert_contains "$init_out" "Enabled rerere" "$who: set should announce rerere"
    test "$(rerere_value "$SANDBOX")" = true || fail "$who: rerere.enabled not set after set"

    init_out=$(xc cfg 2>&1)
    assert_contains "$init_out" "rerere already enabled" "$who: second set should say already enabled"

    log_header "024: patch enables rerere in the patch gitdir ($who)"
    git config --unset rerere.enabled || true
    xc use up "file://$upstream_path" >/dev/null 2>&1 || fail "$who: use failed"
    xc set "up:main:docs" "$PATCH" >/dev/null 2>&1 || fail "$who: patch failed"

    local gd
    gd=$(jq -r --arg lp "$PATCH" '.patches[] | select(.local_path == $lp) | .gitdir' .cross/metadata.json)
    [ -n "$gd" ] && [ "$gd" != "null" ] || fail "$who: metadata is missing the gitdir"
    [ "$(git --git-dir="$gd" config --get rerere.enabled)" = "true" ] \
        || fail "$who: patch did not enable rerere in the standalone gitdir"

    log_header "024: update self-heals rerere ($who)"
    git config --unset rerere.enabled || true
    git --git-dir="$gd" config --unset rerere.enabled || true
    update_out=$(xc update 2>&1)
    assert_contains "$update_out" "Enabled rerere" "$who: update should re-enable a missing rerere setting"
    test "$(rerere_value "$SANDBOX")" = true || fail "$who: update did not restore rerere.enabled in the repo"
    [ "$(git --git-dir="$gd" config --get rerere.enabled)" = "true" ] \
        || fail "$who: update did not restore rerere.enabled in the gitdir"

    # ------------------------------------------------- functional rerere ---
    log_header "024: a recorded conflict resolution is reused ($who)"
    local file="$PATCH/docs/a.md"
    [ -f "$file" ] || fail "$who: expected the nested patch file at $file"

    pushd "$PATCH" >/dev/null
        # the standalone gitdir needs an identity for commits
        xc config user.email test@example.com >/dev/null
        xc config user.name "Test User" >/dev/null

        # local divergence (committed: pull -r refuses to run on a dirty tree)
        printf 'line one\nlocal change\n' > docs/a.md
        xc add docs/a.md >/dev/null 2>&1 || fail "$who: git cross add failed"
        xc commit -qm "local edit" >/dev/null 2>&1 || fail "$who: git cross commit failed"
    popd >/dev/null

    # same hunk diverges upstream
    pushd "$upstream_path" >/dev/null
        printf 'line one\nupstream change\n' > docs/a.md
        git add docs/a.md
        git commit -m "upstream edit" -q
    popd >/dev/null

    pushd "$PATCH" >/dev/null
        pre_merge=$(xc rev-parse HEAD)

        set +e
        xc pull -r > /tmp/rr-first-$who.log 2>&1
        first_rc=$?
        set -e
        [ "$first_rc" -ne 0 ] || fail "$who: expected a conflict on the first pull -r"
        grep -q "<<<<<<<" docs/a.md || fail "$who: expected conflict markers in the patch file"

        local rr_cache
        rr_cache="$(rr_cache_of "$SANDBOX/$gd")"
        [ -d "$rr_cache" ] || fail "$who: rerere cache not created at $rr_cache"

        # Resolve manually: this is the step rerere must remember.
        printf 'line one\nresolved line\n' > docs/a.md
        xc add docs/a.md >/dev/null 2>&1 || fail "$who: git cross add (resolve) failed"
        GIT_EDITOR=true xc rebase --continue >/dev/null 2>&1 || fail "$who: rebase --continue failed"
        [ -n "$(find "$rr_cache" -type f -name preimage 2>/dev/null | head -1)" ] \
            || fail "$who: rerere preimage was not recorded"

        # Replay the identical conflict; rerere must reapply the resolution.
        xc reset --hard "$pre_merge" -q || fail "$who: reset --hard failed"
        set +e
        replay_out=$(GIT_EDITOR=true xc pull -r 2>&1)
        replay_rc=$?
        set -e
        # Without rerere.autoUpdate the rebase still stops, but the recorded
        # resolution is applied to the working tree.
        [ "$replay_rc" -ne 0 ] || fail "$who: the replay should still stop for a commit"
        assert_contains "$replay_out" "Resolved 'docs/a.md' using previous resolution" \
            "$who: rerere should reuse the recorded resolution on replay"
        if grep -q '^<<<<<<<' docs/a.md; then
            fail "$who: rerere did not reuse the resolution (conflict markers remain)"
        fi
        grep -qx 'resolved line' docs/a.md || fail "$who: rerere did not reapply the recorded resolution"

        xc add docs/a.md >/dev/null 2>&1 || fail "$who: git cross add failed on replay"
        GIT_EDITOR=true xc rebase --continue >/dev/null 2>&1 || fail "$who: replay rebase --continue failed"
    popd >/dev/null
}

fixture() {
    upstream_path=$(create_upstream "$1")
    pushd "$upstream_path" >/dev/null
    mkdir -p docs
    printf 'line one\n' > docs/a.md
    git add docs/a.md
    git commit -m "Add docs" -q
    popd >/dev/null
}

# ---------------------------------------------------------------- Go section
if [ -n "$GO_BIN" ]; then
    cd "$PROJECT_ROOT"
    setup_sandbox
    cd "$SANDBOX"
    xc() { "$GO_BIN" "$@"; }
    fixture "rerere-go"
    PATCH="go-docs"
    exercise "Go"
fi

# -------------------------------------------------------------- Just section
# v0.5.1: update is Go-only in the Just reference (stub) — the rerere-through-
# update flow cannot run there; skip the whole Just/Fish variant when stubbed.
if has_fish && just_ref_implements update; then
    cd "$PROJECT_ROOT"
    setup_sandbox
    cd "$SANDBOX"
    xc() { just cross "$@"; }
    fixture "rerere-just"
    PATCH="just-docs"
    exercise "Just"
else
    echo "SKIP: fish unavailable — or update is Go-only (NOT IMPLEMENTED in the Just reference, v0.5.1); skipping Just/Fish rerere assertions"
fi

log_success "024: rerere configuration and resolution reuse verified"
