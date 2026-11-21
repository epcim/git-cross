#!/usr/bin/env bash
source $(dirname "$0")/common.sh

# v0.5.1: `ls` was REMOVED (falls through to the git passthrough). The health
# columns live in `ls`: DIFF (Clean/Modified/Missing Files/Missing GD) + SHA
# (short upstream commit the mirror has checked out).

# Initialize
setup_sandbox
# common.sh sets SANDBOX and cd's into it, which is our local repo.

# Setup upstream
upstream_path=$(create_upstream "upstream-repo")
upstream_url="file://$upstream_path"

# Ensure docs directory exists in upstream
pushd "$upstream_path" >/dev/null
mkdir -p docs
echo "Docs content" > docs/README.md
git add docs/README.md
git commit -m "Add docs"
popd >/dev/null

# Use and Patch (v0.6: subdir crosses are GO-ONLY — the reference refuses
# them; assert the refusal, then create the cross with the Go CLI)
just cross use upstream "$upstream_url"
set_out=$(just cross set upstream:docs vendor/docs 2>&1 || true)
echo "$set_out" | grep -q "subtree crosses" \
    || fail "the reference must refuse subdir crosses (Go-only), got: $set_out"
GO_BIN_007=$(ensure_go_bin "$(cd "$(dirname "$0")/.." && pwd)" || true)
[ -n "$GO_BIN_007" ] || fail "Go CLI required for subtree crosses (v0.6)"
"$GO_BIN_007" set upstream:docs vendor/docs >/dev/null 2>&1 || fail "Go set failed"

# v0.6 D3(c) subtree-rooted: the patch dir mirrors the remote SUBTREE root, so
# the tracked file is vendor/docs/README.md (no docs/ prefix inside the cross).
PATCH_FILE="vendor/docs/README.md"

# Helper to check ls output
check_health() {
    local path="$1"
    local pattern="$2"
    local output=$(just cross ls)

    if ! echo "$output" | grep -q "$path"; then
         fail "ls output missing path '$path'"
    fi

    if ! echo "$output" | grep "$path" | grep -q "$pattern"; then
         echo "ls Output:"
         echo "$output"
         fail "ls row for '$path' did not match pattern '$pattern'"
    fi
}

# ------------------------------------------------------------------
# Test 1: Clean
# ------------------------------------------------------------------
check_health "vendor/docs" "Clean.*[0-9a-f]\{7,10\}"

# ------------------------------------------------------------------
# Test 1b: .crossignore override state — RETIRED in v0.5.0
#
# v0.4 filtered status/diff through .crossignore patterns and reported
# "Override". v0.5 dropped the feature (see TODO/progress open items), so this
# section is parked until the pathspec-based replacement is decided. Do not
# re-enable it expecting "Override" without reimplementing the feature first.
# ------------------------------------------------------------------

# ------------------------------------------------------------------
# Test 2: Modified (Local change)
# ------------------------------------------------------------------
echo "Modification" >> "$PATCH_FILE"
check_health "vendor/docs" "Modified.*[0-9a-f]\{7,10\}"

# Revert change for next test
git checkout -- "$PATCH_FILE" 2>/dev/null || git checkout "$PATCH_FILE"

# ------------------------------------------------------------------
# Test 3: Behind (Upstream has new commits)
# ------------------------------------------------------------------
pushd "$upstream_path" >/dev/null
echo "Upstream change" >> docs/README.md
git add docs/README.md
git commit -m "Upstream update"
popd >/dev/null

# v2: fetch happens in the patch's bare gitdir. It has no tracking refspec, so
# the refspec must be explicit (same form `update` uses).
gd=$(jq -r '.patches[] | select(.local_path == "vendor/docs") | .gitdir' .cross/metadata.json)
br=$(jq -r '.patches[] | select(.local_path == "vendor/docs") | .branch' .cross/metadata.json)
if [ -z "$gd" ] || [ ! -d "$gd" ]; then fail "Gitdir not found in metadata"; fi

git --git-dir="$gd" fetch -q origin "+refs/heads/$br:refs/remotes/origin/$br"
check_health "vendor/docs" "Clean.*[0-9a-f]\{7,10\}"

# ------------------------------------------------------------------
# Test 3b: Modified — GO implementation (v0.5.1 bugfix: the Go health diff ran
# without --work-tree against the BARE mirror, git refused with "must be run
# in a work tree" and the error was swallowed as Clean)
# ------------------------------------------------------------------
GO_BIN_007=$(ensure_go_bin "$(cd "$(dirname "$0")/.." && pwd)" || true)
if [ -n "$GO_BIN_007" ]; then
    echo "Modification" >> "$PATCH_FILE"
    go_row=$("$GO_BIN_007" ls --raw --no-header 2>/dev/null | awk -F'\t' '$3 == "vendor/docs"')
    echo "$go_row"
    assert_contains "$go_row" "Modified" "go: ls DIFF must report Modified for a local edit"

    # committed to the primary repo: STILL Modified — the crossed dir IS the
    # upstream work tree, so DIFF compares content against the mirror HEAD.
    git add "$PATCH_FILE" >/dev/null
    git -c user.email=t@t -c user.name=t commit -qm "vendor: local edit" >/dev/null
    go_row=$("$GO_BIN_007" ls --raw --no-header 2>/dev/null | awk -F'\t' '$3 == "vendor/docs"')
    echo "$go_row"
    assert_contains "$go_row" "Modified" "go: a primary-repo commit is still a diff vs upstream"

    # content restored from the mirror HEAD: Clean again (and no unstaged edit
    # left behind — the next test's update must not refuse on a dirty tree).
    git --git-dir="$gd" --work-tree="$PWD/vendor/docs" checkout -q HEAD -- README.md
    git add "$PATCH_FILE" >/dev/null
    git -c user.email=t@t -c user.name=t commit -qm "vendor: restore upstream content" >/dev/null
    go_row=$("$GO_BIN_007" ls --raw --no-header 2>/dev/null | awk -F'\t' '$3 == "vendor/docs"')
    echo "$go_row"
    assert_contains "$go_row" "Clean" "go: restored content must be Clean again"
    log_success "Test 3b passed: go Modified (unstaged + committed) and Clean"
else
    log_warn "SKIP (007 Test 3b): Go binary unavailable"
fi

# ------------------------------------------------------------------
# Test 4: Ahead (local commit in the patch's upstream context)
# ------------------------------------------------------------------
# Sync first so we are even again: v0.5.0 (ADR-003) `update` itself lands the
# upstream change in the patch dir and lets the mirror follow. The landed files
# are staged in the user's repo, so commit them like any other vendored change.
# (v0.5.1: update is Go-only — the Just reference answers NOT IMPLEMENTED — so
# the SYNC runs through the Go binary; the rest of this test stays on the Just
# flow: passthrough config/add/commit/log + ls health columns.)
GO_BIN_007=$(ensure_go_bin "$(cd "$(dirname "$0")/.." && pwd)" || true)
if [ -z "$GO_BIN_007" ]; then
    log_warn "SKIP (007 Test 4): update is Go-only in the Just reference and no Go binary could be built"
fi
if [ -n "$GO_BIN_007" ]; then
"$GO_BIN_007" update vendor/docs >/dev/null 2>&1 || fail "update should land the upstream change"
git add vendor/docs && git commit -qm "vendor: upstream sync"

check_health "vendor/docs" "Clean.*[0-9a-f]\{7,10\}"

# The standalone gitdir needs its own identity before it can commit.
pushd vendor/docs >/dev/null
    just cross config user.email test@example.com >/dev/null
    just cross config user.name "Test User" >/dev/null
    echo "Patch change" >> README.md
    just cross add README.md >/dev/null 2>&1 || fail "git cross add failed in patch context"
    just cross commit -qm "Patch changes" >/dev/null 2>&1 || fail "git cross commit failed in patch context"
popd >/dev/null

# (v0.5.1) the "N ahead" state went away with stat's UPSTREAM column; verify the
# upstream-context commit landed instead (log -1 in the cross's upstream ctx).
pushd vendor/docs >/dev/null
    just cross log --oneline -1 | grep -q "Patch changes" \
        || fail "upstream-context commit did not land in the mirror"
popd >/dev/null
check_health "vendor/docs" "Clean.*[0-9a-f]\{7,10\}"
fi

# ------------------------------------------------------------------
# Test 5: Missing gitdir (v0.4: "Missing WT")
# ------------------------------------------------------------------
rm -rf "$gd"
check_health "vendor/docs" "Missing GD"

# ------------------------------------------------------------------
# Test 6: Whole-repo patch stays Clean (no .git pointer any more)
# ------------------------------------------------------------------
log_header "Testing whole-repo cross stays Clean in ls..."
setup_sandbox
cd "$SANDBOX"

whole_upstream=$(create_upstream "whole-status")
pushd "$whole_upstream" >/dev/null
mkdir -p nested
echo "nested content" > nested/file.txt
git add nested/file.txt
git commit -m "Add nested content" -q
popd >/dev/null

just cross use whole "file://$whole_upstream"
just cross set "whole:." ./whole

# v2: the patch dir is a plain work tree inside the primary repo — there is no
# .git pointer file that could look like a local change.
[ ! -e whole/.git ] || fail "whole-repo patch dir must not contain a .git file"
check_health "whole" "Clean.*[0-9a-f]\{7,10\}"

echo "Test 007 passed!"
