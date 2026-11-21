#!/bin/bash
source "$(dirname "$0")/common.sh"

# Test 015: wipe (v0.4: prune -> 0.5.0: purge -> now `wipe`) — metadata + gitdir cleanup.
#
#   wipe <remote>   drop the remote record, its crosses' metadata entries and
#                   .cross/worktrees/<remote>/ — the CROSSED DIRS in the working
#                   tree are never deleted (they stay; `del` removes them)
#   wipe            remove UNUSED remotes (prompt), drop metadata entries whose
#                   worktree AND gitdir are gone, and sweep orphaned gitdirs
#
# v0.5.0 has no linked worktrees: cleanup is `rm -rf <gitdir>`; the sweep walks
# .cross/worktrees/<remote>/<gitdir> and drops anything metadata does not name.

xc() {
    if [ "$IMPL" = "just" ]; then
        just cross "$@"
    else
        "$GO_BIN" "$@"
    fi
}

######
# Test 1: wipe specific remote with its patches
######
log_header "Test 1: wipe specific remote..."

setup_sandbox
cd "$SANDBOX"

upstream1=$(create_upstream "upstream1")
mkdir -p "$upstream1/src"
pushd "$upstream1" >/dev/null
echo "upstream1 content" > src/file1.txt
git add src/file1.txt && git commit -m "Add src" -q
popd >/dev/null

GO_BIN=$(ensure_go_bin "$REPO_ROOT" || true)
IMPL=just
if just_ref_implements wipe; then
xc use test-remote-1 "file://$upstream1" >/dev/null || fail "Failed to add remote"
xc set test-remote-1:src vendor/src >/dev/null || fail "Failed to create patch"

[ -d "vendor/src" ] || fail "Patch directory not created"
gd_abs=".cross/worktrees/test-remote-1/vendor_src"
[ -d "$gd_abs" ] || fail "Patch gitdir not created"

wipe_out=$(xc wipe test-remote-1 2>&1) || fail "wipe failed"
echo "$wipe_out"

# metadata + gitdir gone
if [ -f ".cross/metadata.json" ]; then
    patch_count=$(jq -r '.patches | length' .cross/metadata.json)
    [ "$patch_count" = "0" ] || fail "Expected 0 patches after wipe, got $patch_count"
fi
[ ! -d "$gd_abs" ] || fail "wipe should delete the patch gitdir"
[ ! -d ".cross/worktrees/test-remote-1" ] || fail "wipe should delete the remote's gitdir directory"

# the CROSSED DIR is the user's files in the working tree: it must survive
[ -d "vendor/src" ] || fail "wipe must NOT delete the crossed directory"
[ -f "vendor/src/src/file1.txt" ] || fail "wipe must leave the crossed dir's content intact"
assert_contains "$wipe_out" "Leaving vendor/src in place (remove it with: git cross del vendor/src)" \
    "wipe must name the crossed dir it leaves behind"

# remote record gone (v2: remotes live in metadata, not in the primary's git config)
if jq -e '.remotes[] | select(.name == "test-remote-1")' .cross/metadata.json >/dev/null 2>&1; then
    fail "Remote test-remote-1 still recorded in metadata after purge"
fi

log_success "Test 1 passed: remote metadata+gitdirs wiped, crossed dir left in place"
else
    log_warn "SKIP (just): wipe is Go-only — NOT IMPLEMENTED in the Just reference (v0.5.1)"
fi

######
# Test 2: wipe <remote> for a remote with SEVERAL patches
######
log_header "Test 2: wipe removes all patches of a multi-patch remote..."

setup_sandbox
cd "$SANDBOX"
IMPL=just
if just_ref_implements wipe; then

upstream2=$(create_upstream "upstream2")
pushd "$upstream2" >/dev/null
mkdir -p src docs
echo "s" > src/a.txt
echo "d" > docs/b.txt
git add . && git commit -m "content" -q
popd >/dev/null

xc use multi "file://$upstream2" >/dev/null || fail "Failed to add multi remote"
xc set multi:src vendor/a >/dev/null || fail "Failed to patch vendor/a"
xc set multi:docs vendor/b >/dev/null || fail "Failed to patch vendor/b"

[ "$(jq -r '.patches | length' .cross/metadata.json)" = "2" ] || fail "expected 2 patches"

wipe_out=$(xc wipe multi 2>&1) || fail "wipe multi failed"
echo "$wipe_out"

[ "$(jq -r '.patches | length' .cross/metadata.json)" = "0" ] || fail "wipe left metadata patches"
[ ! -d ".cross/worktrees/multi" ] || fail "wipe left the remote's gitdir directory"
[ -d "vendor/a" ] && [ -d "vendor/b" ] || fail "wipe must NOT delete the crossed directories"
assert_contains "$wipe_out" "Leaving vendor/a in place (remove it with: git cross del vendor/a)" \
    "wipe must name vendor/a"
assert_contains "$wipe_out" "Leaving vendor/b in place (remove it with: git cross del vendor/b)" \
    "wipe must name vendor/b"
log_success "Test 2 passed: multi-patch remote metadata+gitdirs wiped, crossed dirs kept"
else
    log_warn "SKIP (just): wipe is Go-only — NOT IMPLEMENTED in the Just reference (v0.5.1)"
fi

######
# Test 3: broken gitdir does not break purge
######
log_header "Test 3: wipe tolerates a missing/corrupt gitdir..."

setup_sandbox
cd "$SANDBOX"
IMPL=just
if just_ref_implements wipe; then

upstream3=$(create_upstream "upstream3")
pushd "$upstream3" >/dev/null
mkdir -p lib
echo "lib" > lib/file3.txt
git add lib/file3.txt && git commit -m "Add lib" -q
popd >/dev/null

xc use test-remote-3 "file://$upstream3" >/dev/null || fail "Failed to add remote"
xc set test-remote-3:lib vendor/lib >/dev/null || fail "Failed to create patch"

# simulate corruption: the gitdir is gone, metadata still references it
rm -rf .cross/worktrees/test-remote-3

xc wipe test-remote-3 >/dev/null || fail "wipe failed with a missing gitdir"
[ -d "vendor/lib" ] || fail "wipe must leave the crossed dir even with a missing gitdir"
[ "$(jq -r '.patches | length' .cross/metadata.json)" = "0" ] || fail "wipe did not clean metadata"
log_success "Test 3 passed: wipe is robust against a missing gitdir"
else
    log_warn "SKIP (just): wipe is Go-only — NOT IMPLEMENTED in the Just reference (v0.5.1)"
fi

######
# Test 4: orphaned gitdir cleanup (just)
######
log_header "Test 4: orphaned gitdir cleanup (just)..."

setup_sandbox
cd "$SANDBOX"
IMPL=just
if just_ref_implements wipe; then

upstream4=$(create_upstream "upstream4")
pushd "$upstream4" >/dev/null
mkdir -p src
echo "content" > src/file.txt
git add src/file.txt && git commit -m "init" -q
popd >/dev/null

xc use demo "file://$upstream4" >/dev/null || fail "Failed to add remote"
xc set demo:src vendor/src >/dev/null || fail "Failed to create patch"

active_gd=$(jq -r '.patches[] | select(.local_path == "vendor/src") | .gitdir' .cross/metadata.json)
[ -d "$active_gd" ] || fail "Active gitdir not found"

# A dead registration: both its worktree and its gitdir are gone.
xc use dead "file://$upstream4" >/dev/null || fail "Failed to add dead remote"
xc set dead:src vendor/dead >/dev/null || fail "Failed to create dead patch"
dead_gd=$(jq -r '.patches[] | select(.local_path == "vendor/dead") | .gitdir' .cross/metadata.json)
rm -rf "vendor/dead" "$dead_gd"

# Orphaned gitdirs (stale state from renames/manual ops) — v2 layout:
# .cross/worktrees/<remote>/<gitdir>
mkdir -p .cross/worktrees/demo/deadbeef
echo "orphan" > .cross/worktrees/demo/deadbeef/dummy.txt
mkdir -p .cross/worktrees/old-remote/gone

# no-arg wipe: pipe 'n' to skip the interactive unused-remote prompt
echo "n" | xc wipe >/dev/null 2>&1 || true

[ ! -d ".cross/worktrees/demo/deadbeef" ] || fail "Orphaned demo/deadbeef not cleaned"
[ ! -d ".cross/worktrees/old-remote/gone" ] || fail "Orphaned old-remote/gone not cleaned"
[ -d "$active_gd" ] || fail "Active gitdir $active_gd was incorrectly removed"
if [ -d "vendor/dead" ]; then fail "dead crossed dir should have been removed by the test itself"; fi
if jq -e '.patches[] | select(.local_path == "vendor/dead")' .cross/metadata.json >/dev/null 2>&1; then
    fail "wipe did not drop the metadata entry whose worktree and gitdir are both missing"
fi

log_success "Test 4 passed: orphaned gitdirs cleaned, dead metadata entry dropped"
else
    log_warn "SKIP (just): wipe is Go-only — NOT IMPLEMENTED in the Just reference (v0.5.1)"
fi

######
# Test 5: orphaned gitdir cleanup (go)
######
log_header "Test 5: orphaned gitdir cleanup (go)..."

if [ -z "${GO_BIN:-}" ]; then
    echo "SKIP: Go binary not available, skipping Go orphan wipe test"
else
    setup_sandbox
    cd "$SANDBOX"
    IMPL=go

    upstream5=$(create_upstream "upstream5")
    pushd "$upstream5" >/dev/null
    mkdir -p lib
    echo "content" > lib/file.txt
    git add lib/file.txt && git commit -m "init" -q
    popd >/dev/null

    xc set >/dev/null 2>&1 || true
    xc use demo "file://$upstream5" >/dev/null || fail "Failed to add remote (go)"
    xc set demo:lib vendor/lib >/dev/null || fail "Failed to create patch (go)"

    active_gd=$(jq -r '.patches[] | select(.local_path == "vendor/lib") | .gitdir' .cross/metadata.json)
    [ -d "$active_gd" ] || fail "Active gitdir not found (Go)"

    mkdir -p .cross/worktrees/demo/deadbeef
    mkdir -p .cross/worktrees/stale/gone

    echo "n" | xc wipe >/dev/null 2>&1 || true

    [ ! -d ".cross/worktrees/demo/deadbeef" ] || fail "Go: orphaned demo/deadbeef not cleaned"
    [ ! -d ".cross/worktrees/stale/gone" ] || fail "Go: orphaned stale/gone not cleaned"
    [ -d "$active_gd" ] || fail "Go: active gitdir incorrectly removed"

    log_success "Test 5 passed: orphaned gitdirs cleaned by go purge"
fi

######
# Test 6: root-target wipe safety guard
######
log_header "Test 6: root-target wipe safety guard..."

setup_sandbox
cd "$SANDBOX"
IMPL=just
if just_ref_implements wipe; then

root_upstream=$(create_upstream "root-purge")
just cross use root-remote "file://$root_upstream" >/dev/null || fail "Failed to add root-remote"

cat > Crossfile <<'EOF'
# git-cross configuration
cross set root-remote:main:. .
EOF
mkdir -p .cross
cat > .cross/metadata.json <<'EOF'
{"remotes":[{"name":"root-remote","url":"file:///nonexistent"}],"patches":[{"remote":"root-remote","remote_url":"file:///nonexistent","remote_path":".","local_path":".","worktree":".","gitdir":".cross/worktrees/root-remote/repo","branch":"main"}]}
EOF
echo "keep me" > keep.txt

wipe_out=$(just cross wipe root-remote 2>&1) || fail "Root-target wipe failed"
echo "$wipe_out"

[ -f "keep.txt" ] || fail "root-target wipe deleted repo root contents"
assert_contains "$wipe_out" "Leaving . in place (remove it with: git cross del .)" \
    "root-target wipe must leave the repo root and say so"
if jq -e '.remotes[] | select(.name == "root-remote")' .cross/metadata.json >/dev/null 2>&1; then
    fail "root-target wipe did not remove the remote record"
fi
[ "$(jq -r '.patches | length' .cross/metadata.json)" = "0" ] || fail "root-target wipe did not clean metadata"

log_success "Test 6 passed: root-target wipe keeps repo root contents"
else
    log_warn "SKIP (just): wipe is Go-only — NOT IMPLEMENTED in the Just reference (v0.5.1)"
fi

######
# Test 7: undeclared registrations are stale metadata (user-reported)
#
# The Crossfile is the source of truth: after hand-editing a `set` line out,
# the registry entry is stale even while the crossed dir (and possibly the
# gitdir) survive. `wipe` must drop it, leave the files, and then treat its
# remote as unused.
######
log_header "Test 7: wipe drops registrations no longer declared in Crossfile..."

if [ -z "${GO_BIN:-}" ]; then
    echo "SKIP: Go binary not available, skipping the undeclared-entry test"
else
    setup_sandbox
    cd "$SANDBOX"
    IMPL=go

    up7=$(create_upstream "upstream7")
    pushd "$up7" >/dev/null
    echo "keep" > keep.txt
    echo "stale" > stale.txt
    git add -A && git commit -m "init" -q
    popd >/dev/null

    xc cfg >/dev/null 2>&1 || true
    xc use up7 "file://$up7" >/dev/null || fail "7: use failed"
    xc set up7:main:. keep >/dev/null || fail "7: set keep failed"
    xc set up7:main:. stale >/dev/null || fail "7: set stale failed"
    git add -A && git commit -qm "vendor: initial" >/dev/null

    # The user's shape: gitdir gone (Missing GD), dir present, line hand-removed.
    stale_gd=$(jq -r '.patches[] | select(.local_path == "stale") | .gitdir' .cross/metadata.json)
    rm -rf "$stale_gd"
    grep -v "stale$" Crossfile > Crossfile.tmp && mv Crossfile.tmp Crossfile

    # update names the stale registration instead of silently ignoring it.
    upd_out=$(xc update </dev/null 2>&1) || true
    echo "$upd_out"
    assert_contains "$upd_out" "no longer declared in Crossfile (stale)" \
        "7: update must warn about the stale registration"
    assert_contains "$upd_out" "git cross wipe" "7: the warning must name the cleanup command"

    wipe_out=$(echo n | xc wipe 2>&1) || fail "7: wipe failed"
    echo "$wipe_out"
    assert_contains "$wipe_out" "Dropping stale from metadata: it is no longer declared in Crossfile" \
        "7: wipe must drop the undeclared entry"
    assert_contains "$wipe_out" "Leaving stale in place" \
        "7: wipe must leave the user's files in place"
    [ -f stale/stale.txt ] || fail "7: wipe deleted the crossed dir"
    [ -f keep/keep.txt ] || fail "7: wipe touched a declared cross"
    if jq -e '.patches[] | select(.local_path == "stale")' .cross/metadata.json >/dev/null 2>&1; then
        fail "7: the stale patch entry survived in metadata"
    fi
    jq -e '.patches[] | select(.local_path == "keep")' .cross/metadata.json >/dev/null 2>&1 \
        || fail "7: the declared patch must survive"

    # A remote used ONLY by an undeclared entry becomes unused and is swept.
    xc use up7b "file://$up7" >/dev/null || fail "7: use up7b failed"
    xc set up7b:main:. stale2 >/dev/null || fail "7: set stale2 failed"
    git add -A && git commit -qm "vendor: stale2" >/dev/null
    grep -v "stale2$" Crossfile > Crossfile.tmp && mv Crossfile.tmp Crossfile
    wipe_out=$(echo y | xc wipe 2>&1) || fail "7: second wipe failed"
    echo "$wipe_out"
    assert_contains "$wipe_out" "Unused remotes: up7b" \
        "7: the stale entry's remote must become unused"
    if jq -e '.remotes[] | select(.name == "up7b")' .cross/metadata.json >/dev/null 2>&1; then
        fail "7: the unused remote survived the sweep"
    fi
    [ -f stale2/stale.txt ] || fail "7: the swept remote's crossed dir must stay"

    log_success "Test 7 passed: undeclared registrations dropped, files kept"
fi

log_success "All wipe tests passed!"
