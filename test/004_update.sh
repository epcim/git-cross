#!/usr/bin/env bash
source test/common.sh

source test/002_patch.sh

log_header "Updating a clean patch from upstream..."
echo "upstream-v2" > "$upstream_path/src/lib/lib.txt"
git -C "$upstream_path" add src/lib/lib.txt
git -C "$upstream_path" commit -m "Update library" -q
clean_output=$(just cross update vendor/lib 2>&1)
echo "$clean_output"
assert_grep "vendor/lib/lib.txt" "upstream-v2"
if echo "$clean_output" | grep -q "differs from upstream"; then
    fail "Update should not warn about local edits for a clean patch"
fi
if ! echo "$clean_output" | grep -q "Review the differences:"; then
    fail "A completed update run should print the review block"
fi
log_success "Clean patch updated"

log_header "Preserving local edits and refreshing sparse worktree..."
echo "local-edit" > vendor/lib/lib.txt
echo "upstream-v3" > "$upstream_path/src/lib/lib.txt"
git -C "$upstream_path" add src/lib/lib.txt
git -C "$upstream_path" commit -m "Conflicting upstream update" -q
output=$(just cross update vendor/lib 2>&1)
echo "$output"
assert_grep "vendor/lib/lib.txt" "local-edit"
if ! echo "$output" | grep -q "differs from upstream"; then
    fail "Update should report that the local copy differs from upstream"
fi
if echo "$output" | grep -q "Compare with:"; then
    fail "Update warning should not inline a per-path suggestion"
fi
if ! echo "$output" | grep -q "Review the differences:"; then
    fail "Update should print the end-of-run review block"
fi
if ! echo "$output" | grep -q "git cross diff  "; then
    fail "Review block should suggest 'git cross diff' without a path"
fi
if ! echo "$output" | grep -q "git cross compare"; then
    fail "Review block should suggest 'git cross compare'"
fi
if echo "$output" | grep -q "git cross diff vendor/lib"; then
    fail "Review block should not repeat per-patch paths"
fi
# The old verbose workflow (global config hint + tool invocation) is gone.
if echo "$output" | grep -q "Local edits detected"; then
    fail "Update still prints the old 'Local edits detected' wording"
fi
if echo "$output" | grep -q "DirDiff"; then
    fail "Update should not print the configured diff tool command"
fi
if echo "$output" | grep -q "git config --global cross.diffTool"; then
    fail "Update should not print the global cross.diffTool hint"
fi
wt_path=$(jq -r '.patches[] | select(.local_path == "vendor/lib") | .worktree' .cross/metadata.json)
if ! git -C "$wt_path" log -1 --oneline >/dev/null 2>&1; then
    fail "Expected sparse worktree to remain available"
fi

if ! git -C "$wt_path" show HEAD:src/lib/lib.txt | grep -q upstream-v3; then
    fail "Sparse worktree should advance to upstream version while local stays unchanged"
fi
assert_grep "vendor/lib/lib.txt" "local-edit"

log_success "Update conflict behavior verified"
