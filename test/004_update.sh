#!/usr/bin/env bash
source test/common.sh

source test/002_patch.sh
# 002 leaves: patch repo1:src/lib at vendor/lib (gitdir .cross/worktrees/repo1/vendor_lib),
# upstream at $upstream_path with src/lib/lib.txt = "lib v1"; the crossed dir
# holds its CONTENT re-rooted (v0.6): vendor/lib/lib.txt. The cross is GO-CREATED
# (the Just reference refuses subdir crosses — asserted in 002).
GO_BIN=$(ensure_go_bin "$REPO_ROOT" || true)
if [ -z "$GO_BIN" ] || [ ! -x "$GO_BIN" ]; then
    fail "Go binary unavailable — subdir-cross pull -r coverage requires the Go CLI"
fi

# v0.6 (ADR-004): in a subdir cross, `pull`/`push` are INTERCEPTED by the Go CLI
# (fetch -> synthesis -> same-shape rebase / graft). The gitdir's pre-rebase hook
# guards the PLAIN passthrough forms (`just cross pull -r`), refusing them with
# a hint to use `git cross pull -r` instead. Go-side interception coverage: 026/030.

log_header "Reference plain-pull guard: 'just cross pull -r' refused by the pre-rebase hook..."
echo "upstream-v2" > "$upstream_path/src/lib/lib.txt"
git -C "$upstream_path" add src/lib/lib.txt
git -C "$upstream_path" commit -m "Update library" -q

pushd vendor/lib >/dev/null
    guard_output=$(just cross pull -r 2>&1)
    guard_status=$?
popd >/dev/null
echo "$guard_output"
if [ "$guard_status" -eq 0 ]; then
    fail "plain 'just cross pull -r' in a subdir cross must be refused by the pre-rebase hook"
fi
case "$guard_output" in
    *"git-cross: use: git cross pull -r"*) ;;
    *) fail "plain pull -r refusal must hint 'git-cross: use: git cross pull -r'" ;;
esac
if [ -f vendor/lib/lib.txt ]; then
    assert_grep "vendor/lib/lib.txt" "lib v1"
fi
log_success "Reference contract: plain pull -r in a subdir cross is hook-refused with the hint"

log_header "Clean update: upstream advance + 'git cross pull -r' (Go interception) in the patch dir..."
pushd vendor/lib >/dev/null
    pull_output=$("$GO_BIN" pull -r 2>&1)
    pull_status=$?
popd >/dev/null
echo "$pull_output"
if [ "$pull_status" -ne 0 ]; then
    fail "git cross pull -r must pass cleanly when there are no local commits"
fi
# v0.6 subtree-rooted: tracked files live at vendor/lib/
assert_grep "vendor/lib/lib.txt" "upstream-v2"

# ls reports the patch Clean (DIFF) after the successful pull
stat_output=$("$GO_BIN" ls)
echo "$stat_output"
echo "$stat_output" | grep -q "vendor/lib" || fail "ls output missing vendor/lib"
echo "$stat_output" | grep "vendor/lib" | grep -q "Clean" \
    || fail "ls DIFF should report vendor/lib as Clean after pull -r"
echo "$stat_output" | grep "vendor/lib" | grep -qE "[0-9a-f]{7,10}" \
    || fail "ls should show the short upstream SHA for vendor/lib after pull -r"
log_success "Clean patch updated via git cross pull -r (Go)"

log_header "Conflicting update: 'git cross pull -r' stops; user resolves..."
# The local change must be COMMITTED in the patch's upstream context for a
# rebase conflict (uncommitted changes make pull -r refuse to start).
pushd vendor/lib >/dev/null
    # The standalone gitdir is a fresh clone: it needs its own git identity.
    "$GO_BIN" config user.email test@example.com >/dev/null
    "$GO_BIN" config user.name "Test User" >/dev/null
    echo "local-edit" > lib.txt
    "$GO_BIN" add lib.txt >/dev/null 2>&1 || fail "git cross add failed in patch context"
    # multi-word commit message: exercises the wt passthrough argument handling
    "$GO_BIN" commit -qm "local change" >/dev/null 2>&1 || fail "git cross commit failed in patch context"
popd >/dev/null

echo "upstream-v3" > "$upstream_path/src/lib/lib.txt"
git -C "$upstream_path" add src/lib/lib.txt
git -C "$upstream_path" commit -m "Conflicting upstream update" -q

pushd vendor/lib >/dev/null
    "$GO_BIN" pull -r > /tmp/cross-pull-conflict.log 2>&1
    conflict_status=$?
popd >/dev/null
tail -5 /tmp/cross-pull-conflict.log
if [ "$conflict_status" -eq 0 ]; then
    fail "git cross pull -r must stop on a conflicting rebase (non-zero exit)"
fi
grep -q "CONFLICT" /tmp/cross-pull-conflict.log || fail "expected CONFLICT in pull -r output"
grep -q "<<<<<<<" vendor/lib/lib.txt || fail "conflict markers expected in lib.txt"

# User resolves the conflict and continues the rebase (Go CLI throughout).
pushd vendor/lib >/dev/null
    echo "resolved-merge" > lib.txt
    "$GO_BIN" add lib.txt >/dev/null 2>&1 || fail "git cross add (resolve) failed"
    GIT_EDITOR=true "$GO_BIN" rebase --continue >/dev/null 2>&1 || fail "rebase --continue failed"
    # the local commit (multi-word message) is part of the rebased history
    "$GO_BIN" log --oneline 2>/dev/null | grep -q "local change" || fail "local commit missing from patch history"
popd >/dev/null

assert_grep "vendor/lib/lib.txt" "resolved-merge"
# rerere recorded the resolution in the gitdir's own rr-cache (enabled at patch time)
assert_dir_exists ".cross/worktrees/repo1/vendor_lib/rr-cache"
log_success "Conflict resolved by user; rebase completed (rerere recorded)"
