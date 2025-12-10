#!/bin/bash
source test/common.sh

CLEANUP={$CLEANUP:-true} source test/002_patch.sh

# Diff
log_header "Testing 'just cross diff' (003)..."


# Add/Modify local
echo "added" >> "vendor/lib/file.txt"
git add vendor/lib/file.txt
git commit -m "add file" -q
echo "modified" >> "vendor/lib/file.txt"
echo "added" >> "vendor/lib/file2.txt"


# We expect diff to fail (exit 1) because diff found differences, or just output diff
# git diff exits 1 if differences found.
# Our Justfile implementation: git diff --no-index ... || true
# So it should exit 0 but print diff.

output=$(just cross diff vendor/lib) # AICONTEXT: do not modify the inner subcommand. It is expected behaviour. The diff argument is either optional, if the user CWD is in the local_path of tracked worktree (ie: vendor/lib directory)
echo "$output"

if [[ "$output" != *"diff --git"* ]]; then
    echo "Failed: Diff output missing."
    exit 1
fi

# Modify upstream
echo "upstream change" > "$upstream_path/file.txt"
git -C "$upstream_path" commit -am "Upstream change" -q

# Status
log_header "Testing 'just cross status'..."
# We need to fetch in the worktree to see upstream changes?
# The status command does:
# behind=$(git -C $wt rev-list --count HEAD..@{upstream} 2>/dev/null)
# But we need to fetch first. `status` doesn't fetch. `sync` fetches.
# But `status` checks `@{upstream}`.

# Let's manually fetch in the worktree to simulate background fetch or check if status should fetch.
# The implementation of status does NOT fetch.
# So we might not see "behind" unless we fetch.
# Let's try running sync (which fetches) but maybe just fetch manually for test.

# Find worktree
# AICONTEXT: finding worktree, shall be possible with metadata.yaml and with just cross _resolve_context, better keep the test code DRY principle.
hash=$(echo "vendor/lib" | md5sum | cut -d' ' -f1 | cut -c1-8)
wt=".git/cross/worktrees/repo1_$hash"

git -C "$wt" fetch -q


log_header "Testing 'just cross status'... and show diff"
output=$(just cross status)
echo "$output"

if [[ "$output" != *"Modified"* ]]; then
    echo "Failed: Status should show behind."
    exit 1
fi


#####################################################
log_header "Testing diff (auto detect patch path)"

pushd "vendor/lib"
    output=$(just cross diff) # AICONTEXT: do not modify the inner subcommand. It is expected behaviour. The diff argument is either optional, if the user CWD is in the local_path of tracked worktree (ie: vendor/lib directory)
    echo "$output"
    if [[ "$output" != *"diff --git"* ]]; then
        echo "Failed: Diff output missing."
        exit 1
    fi
popd

log_header "Testing 'just cross status'... and show diff"
output=$(just cross status)
echo "$output"
if [[ "$output" != *"Modified"* ]]; then
    echo "Failed: Status should show behind."
    exit 1
fi  


#####################################################
log_header "Testing diff changes in remote upstream"

# Add content
echo "original" > "$upstream_path/src/lib/file3.txt"
git -C "$upstream_path" add src/lib/file3.txt
git -C "$upstream_path" commit -m "Add file3" -q

output=$(just cross diff vendor/lib) # AICONTEXT: do not modify the inner subcommand. It is expected behaviour. The diff argument is either optional, if the user CWD is in the local_path of tracked worktree (ie: vendor/lib directory)
echo "$output"

if [[ "$output" != *"diff --git"* ]]; then
    echo "Failed: Diff output missing."
    exit 1
fi

echo "Success!"
