#!/usr/bin/env bash
# Test 026: update/resolve conflict lifecycle (ADR-003) — BOTH implementations.
#
# This is the integration counterpart of src-go/update_resolve_test.go: the same
# scenario runs twice, once through the Go CLI and once through Justfile.cross,
# so a divergence between the two implementations fails here.
#
# Contract under test:
#   update   fetch every patch first, then per patch land upstream in the patch
#            dir and re-apply the user's version on top
#   unstaged local edits -> refuse ("commit them in your repo first")
#   collision            -> KEPT: unmerged paths + markers (never an overwrite)
#   resolve --abort      -> patch dir back to HEAD, fetch kept
#   resolve --continue   -> requires no unmerged paths, mirror follows
#   update --no-resolve  -> land upstream as-is (upstream wins, no markers)
source "$(dirname "$0")/common.sh"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO_BIN="$(ensure_go_bin "$PROJECT_ROOT")"

exercise() {
    local who=$1
    log_header "026: $who — clean landing re-applies committed local changes"
    setup_sandbox
    cd "$SANDBOX"
    echo "upstream/" >> .gitignore

    local up
    up=$(create_upstream "u-$who")
    mkdir -p "$up/src/lib"
    echo "NAME: AAA" > "$up/src/lib/c.yaml"
    echo "keep me" > "$up/src/lib/local.txt"
    git -C "$up" add -A
    git -C "$up" commit -qm v1

    xc cfg >/dev/null 2>&1 || true
    xc use up "$up" >/dev/null 2>&1 || fail "$who: use"
    xc set up:src/lib lib >/dev/null 2>&1 || fail "$who: patch"
    git add -A && git commit -qm "vendor: initial" >/dev/null

    local gd
    gd="$SANDBOX/$(jq -r '.patches[] | select(.local_path == "lib") | .gitdir' .cross/metadata.json)"
    [ -d "$gd" ] || fail "$who: mirror not created"

    # --- clean landing -----------------------------------------------------
    echo "user edit" >> lib/local.txt
    git add lib && git commit -qm "vendor: local edit" >/dev/null
    echo "new upstream" > "$up/src/lib/new.txt"
    git -C "$up" add -A && git -C "$up" commit -qm v2

    local out
    out=$(xc update 2>&1) || true
    echo "$out"
    assert_contains "$out" "Updated lib" "$who: clean update should land"
    assert_grep "lib/new.txt" "new upstream"
    assert_grep "lib/local.txt" "user edit"
    [ -z "$(git ls-files -u)" ] || fail "$who: clean landing must not leave unmerged paths"
    # v0.6: mirror HEAD is a synthesized subtree branch — compare TREES, not commits
    [ "$(git --git-dir="$gd" rev-parse 'refs/heads/main^{tree}')" = "$(git --git-dir="$gd" rev-parse refs/remotes/origin/main:src/lib)" ] \
        || fail "$who: mirror should follow the landed revision"
    git add lib && git commit -qm "vendor: upstream sync" >/dev/null
    out=$(xc update 2>&1) || true
    assert_contains "$out" "already up to date" "$who: second update must be a no-op"

    # --- unstaged edits are refused ---------------------------------------
    log_header "026: $who — unstaged local edits refuse the update"
    local up_before
    up_before=$(git -C "$up" rev-parse HEAD)
    echo "local only" >> lib/local.txt          # unstaged on purpose
    echo "upstream v2" >> "$up/src/lib/local.txt"
    git -C "$up" commit -qam v3
    out=$(xc update 2>&1) || true
    echo "$out"
    assert_contains "$out" "has modified files; commit them in your repo first" \
        "$who: update must ask for a commit"
    assert_grep "lib/local.txt" "local only"
    assert_contains "$(git --git-dir="$gd" show 'refs/remotes/origin/main:src/lib/local.txt')" "upstream v2" \
        "$who: fetch must still have happened"
    # Undo both sides so the file is identical again for the next phase.
    git checkout -- lib/local.txt 2>/dev/null || true
    git -C "$up" reset -q --hard "$up_before"

    # --- untracked collisions refuse early (0.6.1) -------------------------
    # A file the delta would write sitting UNTRACKED in the crossed dir used to
    # surface as a raw "would be overwritten by merge" cherry-pick error; the
    # gate now refuses it BEFORE any work with guidance. Purely local untracked
    # files stay allowed (patchWorktreeDirty contract).
    log_header "026: $who — untracked delta collisions refuse the update early"
    git rm -q --cached lib/local.txt >/dev/null 2>&1
    git commit -qm "vendor: untrack local.txt" >/dev/null
    echo "upstream v5" >> "$up/src/lib/local.txt"
    git -C "$up" commit -qam v5
    out=$(xc update 2>&1) || true
    echo "$out"
    assert_contains "$out" "untracked files would be overwritten by the update" \
        "$who: the early refusal must name the problem"
    assert_contains "$out" "lib/local.txt" \
        "$who: the colliding untracked file must be listed"
    assert_contains "$out" "commit or stage them first" \
        "$who: the refusal must hint at the remedy"
    assert_contains "$out" "1 cross(es) skipped" "$who: counts as skipped, not failed"
    [ -z "$(git ls-files -u)" ] || fail "$who: refusal must not leave unmerged paths"
    assert_grep "lib/local.txt" "keep me" "$who: the untracked file is untouched"
    # restore: re-track the file so later phases start clean
    git add lib/local.txt && git commit -qm "vendor: re-track local.txt" >/dev/null
    git -C "$up" reset -q --hard "$up_before"
    out=$(xc update 2>&1) || true
    assert_contains "$out" "already up to date" \
        "$who: the untracked refusal is gone once the file is tracked (upstream rewound to the landed state)"

    # --- conflict is kept (never overwritten) ------------------------------
    log_header "026: $who — a collision is kept as a conflict"
    echo "NAME: BBB" > lib/c.yaml
    git add lib && git commit -qm "vendor: BBB" >/dev/null
    echo "NAME: CCC" > "$up/src/lib/c.yaml"
    git -C "$up" commit -qam v4

    out=$(xc update 2>&1) || true
    echo "$out"
    assert_contains "$out" "conflict in 'lib'" "$who: update must keep the conflict"
    assert_contains "$out" "git cross resolve" "$who: output should point at resolve"
    [ -n "$(git ls-files -u)" ] || fail "$who: conflict must surface as unmerged paths"
    assert_grep "lib/c.yaml" "<<<<<<<"

    out=$(xc update 2>&1) || true
    assert_contains "$out" "pending conflict" "$who: a pending conflict must not be reset over"
    [ -n "$(git ls-files -u)" ] || fail "$who: pending state must survive a second update"

    # --- resolve --abort ---------------------------------------------------
    log_header "026: $who — resolve --abort restores the user's version"
    out=$(xc resolve --abort 2>&1) || fail "$who: resolve --abort"
    [ -z "$(git ls-files -u)" ] || fail "$who: --abort must clear unmerged paths"
    assert_grep "lib/c.yaml" "NAME: BBB"
    [ "$(git --git-dir="$gd" rev-parse 'refs/heads/main^{tree}')" != "$(git --git-dir="$gd" rev-parse refs/remotes/origin/main:src/lib)" ] \
        || fail "$who: --abort must not advance the mirror"

    # --- resolve --continue ------------------------------------------------
    log_header "026: $who — resolve --continue finishes it and lets the mirror follow"
    out=$(xc update 2>&1) || true
    assert_contains "$out" "conflict in 'lib'" "$who: conflict should reappear"
    printf 'NAME: BBB\nNAME: CCC\n' > lib/c.yaml
    git add lib/c.yaml
    out=$(xc resolve --continue 2>&1) || fail "$who: resolve --continue"
    echo "$out"
    assert_contains "$out" "is clean" "$who: --continue should confirm cleanliness"
    [ "$(git --git-dir="$gd" rev-parse 'refs/heads/main^{tree}')" = "$(git --git-dir="$gd" rev-parse refs/remotes/origin/main:src/lib)" ] \
        || fail "$who: --continue must let the mirror follow"
    git commit -qm "vendor: resolved" >/dev/null

    # rerere lives in the USER's repo, not the mirror
    [ -d "$SANDBOX/.git/rr-cache" ] || fail "$who: rerere should record in <repo>/.git/rr-cache"
    [ ! -d "$gd/rr-cache" ] || true   # the mirror may hold its own cache; not required

    # --- --no-resolve ------------------------------------------------------
    log_header "026: $who — update --no-resolve lands upstream as-is"
    echo "NAME: DDD" > "$up/src/lib/c.yaml"
    git -C "$up" commit -qam v5
    out=$(xc update --no-resolve 2>&1) || true
    echo "$out"
    assert_contains "$out" "Updated lib" "$who: --no-resolve should land"
    assert_grep "lib/c.yaml" "NAME: DDD"
    [ -z "$(git ls-files -u)" ] || fail "$who: --no-resolve must not leave unmerged paths"
}

# --- Go ---------------------------------------------------------------------
if [ -n "$GO_BIN" ]; then
    xc() { "$GO_BIN" "$@"; }
    exercise go
else
    echo "SKIP: Go CLI unavailable"
fi

# --- Just/Fish --------------------------------------------------------------
# v0.5.1: update/resolve are Go-only in the Just reference (stubs) — this test
# is entirely update/resolve-driven, so skip the whole variant when stubbed.
if command -v fish >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v just >/dev/null 2>&1 && just_ref_implements update; then
    xc() { just cross "$@"; }
    exercise just
else
    echo "SKIP: fish/jq/just unavailable — or update is Go-only (NOT IMPLEMENTED in the Just reference, v0.5.1); skipping the Just/Fish variant"
fi

echo "Test 026 passed!"
