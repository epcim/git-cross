#!/bin/bash
#
# Test 025: v0.5.0 gitdir patches — patch creation & checkout (staged scope).
#
# New architecture under test (STAGE 1 of the v0.5.0 rollout):
#   .cross/worktrees/<remote>/<local_path_underscored>/   standalone BARE gitdir
#     (".git content": objects, refs, sparse config, rerere, remote origin)
#   <local_path>/                                        THE PATCH: plain files
#     inside the primary repo, tracked by the primary as normal blobs.
#
# Covered in this stage: use (metadata remotes, primary git untouched),
# patch (bare gitdir, sparse filter, shallow via cross.depth, rerere, no .git
# file in the patch dir), primary blob tracking, upstream-context git via
# the bare `git cross <native-git-cmd>` passthrough, cd.
#
# STAGE 2 (extend, tracked in specs/003-gitdir-patches/plan.md): update flow,
# status/diff/list assertions, remove, prune — and the Go implementation.

TESTDIR="${TESTDIR:-$(mktemp -d)}"
export TESTDIR

. "$(dirname "$0")/common.sh"

setup_sandbox

# ---------------------------------------------------------------- fixtures ---
UPSTREAM="$SANDBOX/upstream/demo"
mkdir -p "$UPSTREAM/docs/guides" "$UPSTREAM/src"
(
    cd "$UPSTREAM" || exit 1
    git init -q -b main
    git config user.email upstream@example.com
    git config user.name "Upstream User"
    echo "v1 readme" > README.md
    echo "v1 guide" > docs/guide.md
    echo "v1 api"   > docs/guides/api.md
    echo "v1 lib"   > src/lib.ts
    git add -A && git commit -qm "upstream v1"
) || fail "upstream fixture setup failed"
UP_URL="file://$UPSTREAM"

# Dispatch to the implementation under test (IMPL=just|go).
xc() {
    if [ "$IMPL" = "just" ]; then
        just cross "$@"
    else
        "$GO_BIN" "$@"
    fi
}

# opt-in shallow clone for both implementations
git config cross.depth 1

# ------------------------------------------------------------- test flow ----
exercise_patch_creation() {
    log_header "$IMPL: use registers the remote in metadata (primary git untouched)"
    xc use demo "$UP_URL" || fail "use failed"
    assert_grep .cross/metadata.json '"name": "demo"'
    assert_grep .cross/metadata.json "\"url\": \"$UP_URL\""
    assert_grep Crossfile "cross use demo $UP_URL"
    if git remote | grep -q demo; then
        fail "primary repo must NOT get a git remote for demo (v2: remotes live in .cross)"
    fi

    log_header "$IMPL: patch creates a standalone bare gitdir and a work tree in the main repo"
    xc set demo:main:docs vendor/docs || fail "patch failed"
    # gitdir holds only .git content (bare layout)
    assert_file_exists .cross/worktrees/demo/vendor_docs/HEAD
    assert_file_exists .cross/worktrees/demo/vendor_docs/config
    assert_dir_exists .cross/worktrees/demo/vendor_docs/objects
    # sparse + shallow + rerere state inside the gitdir
    assert_grep .cross/worktrees/demo/vendor_docs/info/sparse-checkout '^docs/$'
    assert_file_exists .cross/worktrees/demo/vendor_docs/shallow
    [ "$(git --git-dir=.cross/worktrees/demo/vendor_docs config --get rerere.enabled)" = "true" ] \
        || fail "rerere must be enabled in the standalone gitdir"
    # work tree: plain files inside the primary repo, no .git pointer
    [ ! -e vendor/docs/.git ] || fail "patch dir must NOT contain a .git file (breaks primary tracking)"
    assert_file_exists vendor/docs/docs/guide.md
    [ ! -e vendor/docs/README.md ] || fail "sparse filter failed: README.md must not be checked out"
    [ ! -e vendor/docs/src/lib.ts ] || fail "sparse filter failed: src/ must not be checked out"
    # metadata v2 entry
    assert_grep .cross/metadata.json '"gitdir": ".cross/worktrees/demo/vendor_docs"'
    assert_grep .cross/metadata.json '"local_path": "vendor/docs"'

    log_header "$IMPL: primary tracks patch files as normal blobs (no submodule gitlink)"
    git add vendor/docs
    mode=$(git ls-files -s vendor/docs | head -1 | awk '{print $1}')
    [ "$mode" = "100644" ] || fail "patch files must be tracked as normal blobs, got mode: $mode"

    log_header "$IMPL: bare git cross <git-cmd> runs git in the patch's upstream context"
    o=$(cd vendor/docs && xc remote -v 2>/dev/null | head -1)
    assert_contains "$o" "$UP_URL" "bare passthrough remote must point at the upstream"
    o=$(cd vendor/docs && xc log --oneline 2>/dev/null | head -1)
    assert_contains "$o" "upstream v1" "bare passthrough log must show upstream history"
    o=$(cd vendor/docs && xc status --short --branch 2>/dev/null)
    assert_contains "$o" "## main" "bare passthrough status must run against the upstream branch"

    log_header "$IMPL: bare git cross <native-git-cmd> falls through to the same passthrough"
    o=$(cd vendor/docs && xc log --oneline 2>/dev/null)
    assert_contains "$o" "upstream v1" "git cross log must show upstream history inside a patch"

    log_header "$IMPL: bare git cross outside a cross dir fails early (no GIT_DIR/GIT_WORK_TREE)"
    o=$(xc rev-parse --show-toplevel 2>&1)
    if [ $? -eq 0 ]; then
        fail "bare passthrough outside a cross dir must fail instead of running plain git"
    fi
    assert_contains "$o" "crossed directory" "bare passthrough outside a cross dir must explain the missing context"

    log_header "$IMPL: plain git in the patch dir still targets the primary repo"
    o=$(cd vendor/docs && git rev-parse --show-toplevel)
    assert_contains "$o" "$SANDBOX" "plain git in the patch dir must target the primary repo"

    log_header "$IMPL: cd prints the crossed directory"
    if [ "$IMPL" != "just" ] || just_ref_implements cd; then
        o=$(xc cd vendor/docs)
        assert_contains "$o" "$SANDBOX/vendor/docs" "cd must print the patch dir"
    else
        log_warn "SKIP (just): cd is Go-only — NOT IMPLEMENTED in the Just reference (v0.5.1)"
    fi
}

# --------------------------------------------------------------- Part A -----
IMPL=just
exercise_patch_creation

# --------------------------------------------------------------- Part B -----
GO_BIN=$(ensure_go_bin)
if [ -z "$GO_BIN" ]; then
    log_warn "Go toolchain unavailable or build failed - skipping Go part (see test/009)"
else
    IMPL=go
    exercise_patch_creation
fi

log_success "025_gitdir_patch (stage 1: creation/checkout): PASS (just$( [ -n "$GO_BIN" ] && echo " + go"))"
