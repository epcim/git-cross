#!/bin/bash
source test/common.sh

CLEANUP={$CLEANUP:-true} source test/002_patch.sh

# v0.5.0: `diff` is the git passthrough — it only works INSIDE a crossed directory
# (GIT_DIR/GIT_WORK_TREE = the patch's upstream context). At the repo root it
# fails early (ADR-002). Local changes are tracked files under the nested
# upstream path (D3: vendor/lib/src/lib/lib.txt).

log_header "Testing 'just cross diff' inside the patch dir (003)..."

# Add/Modify local (v2 D3 nesting: tracked files live under vendor/lib/src/lib/)
echo "added" >> "vendor/lib/src/lib/lib.txt"
git add vendor/lib/src/lib/lib.txt
git commit -m "add file" -q
echo "modified" >> "vendor/lib/src/lib/lib.txt"

pushd vendor/lib >/dev/null
    output=$(just cross diff || true)
    echo "$output"
    if [[ "$output" != *"src/lib/lib.txt"* ]]; then
        echo "Failed: Diff of the tracked nested file missing."
        exit 1
    fi
    if [[ "$output" != *"diff --git"* ]]; then
        echo "Failed: Diff output missing."
        exit 1
    fi
popd >/dev/null

# Modify upstream and fetch into the gitdir (bare clones need an explicit refspec).
# NB: use a tracked upstream file — `commit -am` ignores untracked files.
echo "upstream change" > "$upstream_path/src/lib/lib.txt"
git -C "$upstream_path" commit -am "Upstream change" -q || true

log_header "Testing 'just cross ls' DIFF column..."
gd=$(jq -r '.patches[] | select(.local_path == "vendor/lib") | .gitdir' .cross/metadata.json)
if [ -z "$gd" ] || [ ! -d "$gd" ]; then
    echo "Failed: gitdir for vendor/lib not found in metadata."
    exit 1
fi
br=$(jq -r '.patches[] | select(.local_path == "vendor/lib") | .branch' .cross/metadata.json)
git --git-dir="$gd" fetch -q origin "+refs/heads/$br:refs/remotes/origin/$br"

output=$(just cross ls)
echo "$output"
if [[ "$output" != *"Modified"* ]]; then
    echo "Failed: ls DIFF should report the patch as Modified (local edits)."
    exit 1
fi
# (v0.5.1) the "N behind" state went away with stat's UPSTREAM column; the
# gitdir fetch itself is covered by the Modified DIFF above and by 026's
# mirror-advance assertions.

#####################################################
log_header "Testing diff auto-detect from a patch subdirectory"

mkdir -p vendor/lib/src/lib/nested
pushd vendor/lib/src/lib/nested >/dev/null
    output=$(just cross diff || true)
    echo "$output"
    if [[ "$output" != *"src/lib/lib.txt"* ]]; then
        echo "Failed: diff from a patch subdirectory should still show the patch diff."
        exit 1
    fi
popd

#####################################################
log_header "Testing diff with an explicit git pathspec inside the patch"

pushd vendor/lib >/dev/null
    output=$(just cross diff src/lib/lib.txt || true)
    echo "$output"
    if [[ "$output" != *"modified"* ]]; then
        echo "Failed: diff with a pathspec should show the modification."
        exit 1
    fi
popd

#####################################################
log_header "Testing that diff at the repo root fails early (ADR-002)"

rc=0
output=$(just cross diff vendor/lib 2>&1) || rc=$?
echo "$output"
if [ "$rc" -eq 0 ]; then
    echo "Failed: diff outside a crossed directory must exit non-zero."
    exit 1
fi
if [[ "$output" != *"crossed directory"* ]]; then
    echo "Failed: diff outside a crossed directory must explain the missing context."
    exit 1
fi

echo "Success!"
