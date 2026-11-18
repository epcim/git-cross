#!/usr/bin/env bash
source test/common.sh

source test/002_patch.sh
# 002 leaves: patch repo1:src/lib at vendor/lib (gitdir .cross/worktrees/repo1/vendor_lib),
# upstream at $upstream_path with src/lib/lib.txt = "lib v1".

# v0.5.0 update flow: edit upstream, then cd into the patch dir and run
# `git cross pull -r` — the passthrough runs `git pull --rebase` with the
# patch's GIT_DIR/GIT_WORK_TREE (upstream context). No local conflicting
# commits -> it just passes. Conflict -> rebase stops and the user resolves.

log_header "Clean update: upstream advance + 'git cross pull -r' in the patch dir..."
echo "upstream-v2" > "$upstream_path/src/lib/lib.txt"
git -C "$upstream_path" add src/lib/lib.txt
git -C "$upstream_path" commit -m "Update library" -q

pushd vendor/lib >/dev/null
    pull_output=$(just cross pull -r 2>&1)
    pull_status=$?
popd >/dev/null
echo "$pull_output"
if [ "$pull_status" -ne 0 ]; then
    fail "git cross pull -r must pass cleanly when there are no local commits"
fi
# v2 D3 nesting: tracked files live under vendor/lib/src/lib/
assert_grep "vendor/lib/src/lib/lib.txt" "upstream-v2"

# ls reports the patch Clean (DIFF) after the successful pull
stat_output=$(just cross ls)
echo "$stat_output"
echo "$stat_output" | grep -q "vendor/lib" || fail "ls output missing vendor/lib"
echo "$stat_output" | grep "vendor/lib" | grep -q "Clean" \
    || fail "ls DIFF should report vendor/lib as Clean after pull -r"
echo "$stat_output" | grep "vendor/lib" | grep -qE "[0-9a-f]{7,10}" \
    || fail "ls should show the short upstream SHA for vendor/lib after pull -r"
log_success "Clean patch updated via git cross pull -r"

log_header "Conflicting update: 'git cross pull -r' stops; user resolves..."
# The local change must be COMMITTED in the patch's upstream context for a
# rebase conflict (uncommitted changes make pull -r refuse to start).
pushd vendor/lib >/dev/null
    # The standalone gitdir is a fresh clone: it needs its own git identity.
    just cross config user.email test@example.com >/dev/null
    just cross config user.name "Test User" >/dev/null
    echo "local-edit" > src/lib/lib.txt
    just cross add src/lib/lib.txt >/dev/null 2>&1 || fail "git cross add failed in patch context"
    # multi-word commit message: exercises the wt passthrough argument handling
    just cross commit -qm "local change" >/dev/null 2>&1 || fail "git cross commit failed in patch context"
popd >/dev/null

echo "upstream-v3" > "$upstream_path/src/lib/lib.txt"
git -C "$upstream_path" add src/lib/lib.txt
git -C "$upstream_path" commit -m "Conflicting upstream update" -q

pushd vendor/lib >/dev/null
    just cross pull -r > /tmp/cross-pull-conflict.log 2>&1
    conflict_status=$?
popd >/dev/null
tail -5 /tmp/cross-pull-conflict.log
if [ "$conflict_status" -eq 0 ]; then
    fail "git cross pull -r must stop on a conflicting rebase (non-zero exit)"
fi
grep -q "CONFLICT" /tmp/cross-pull-conflict.log || fail "expected CONFLICT in pull -r output"
grep -q "<<<<<<<" vendor/lib/src/lib/lib.txt || fail "conflict markers expected in src/lib/lib.txt"

# User resolves the conflict and continues the rebase (passthrough throughout).
pushd vendor/lib >/dev/null
    echo "resolved-merge" > src/lib/lib.txt
    just cross add src/lib/lib.txt >/dev/null 2>&1 || fail "git cross add (resolve) failed"
    GIT_EDITOR=true just cross rebase --continue >/dev/null 2>&1 || fail "rebase --continue failed"
    # the local commit (multi-word message) is part of the rebased history
    just cross log --oneline 2>/dev/null | grep -q "local change" || fail "local commit missing from patch history"
popd >/dev/null

assert_grep "vendor/lib/src/lib/lib.txt" "resolved-merge"
# rerere recorded the resolution in the gitdir's own rr-cache (enabled at patch time)
assert_dir_exists ".cross/worktrees/repo1/vendor_lib/rr-cache"
log_success "Conflict resolved by user; rebase completed (rerere recorded)"
