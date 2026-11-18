#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

# Test 012: sparse checkout in the v0.5.0 architecture.
#
# The patch gitdir is BARE and holds the sparse config; the crossed directory in
# the repo is the work tree. `git sparse-checkout` refuses on a bare repo, so the
# implementation writes the plumbing directly:
#   <gitdir>/config          core.sparseCheckout = true
#   <gitdir>/info/sparse-checkout   "<remote_path>/"  (trailing slash)
# and materializes with `read-tree -mu HEAD`.
#
# Locations are resolved from .cross/metadata.json with jq (never by globbing).

setup_sandbox
cd "$SANDBOX"

upstream_path=$(create_upstream "sparse-upstream")
upstream_url="file://$upstream_path"

pushd "$upstream_path" >/dev/null
echo "root-file" > root.txt
mkdir -p apps/app1
echo "app1-file" > apps/app1/data.txt
git add .
git commit -m "Initial commit" >/dev/null
popd >/dev/null

xc() {
    if [ "$IMPL" = "just" ]; then
        just cross "$@"
    else
        "$GO_BIN" "$@"
    fi
}

exercise() {
    xc use demo "$upstream_url" >/dev/null
    xc set demo:apps/app1 vendor/app1 >/dev/null

    local gd wt
    gd=$(jq -r '.patches[] | select(.local_path == "vendor/app1") | .gitdir' .cross/metadata.json)
    wt=$(jq -r '.patches[] | select(.local_path == "vendor/app1") | .worktree' .cross/metadata.json)
    [ -n "$gd" ] && [ "$gd" != "null" ] || fail "$IMPL: metadata is missing 'gitdir'"
    [ -d "$gd" ] || fail "$IMPL: gitdir '$gd' does not exist"

    # sparse state lives in the bare gitdir
    [ "$(git --git-dir="$gd" config --get core.sparseCheckout)" = "true" ] \
        || fail "$IMPL: core.sparseCheckout must be true in the gitdir"
    grep -qx "apps/app1/" "$gd/info/sparse-checkout" \
        || fail "$IMPL: info/sparse-checkout must contain 'apps/app1/' (trailing slash)"

    # the work tree is the patch dir; only the filtered subtree is materialized...
    [ -f "$wt/apps/app1/data.txt" ] || fail "$IMPL: sparse file apps/app1/data.txt missing from the patch dir"
    # ...and D3 nesting keeps the upstream path (no re-rooting)
    [ -f "$wt/apps/app1/data.txt" ] || fail "$IMPL: upstream path must be mirrored under the patch dir"
    # files outside the filter must NOT be materialized
    [ ! -e "$wt/root.txt" ] || fail "$IMPL: root.txt found in the patch dir — sparse filter failed"

    # the primary repo sees the patch files as normal blobs
    git add "$wt" >/dev/null 2>&1 || true
    [ "$(git ls-files -s "$wt/apps/app1/data.txt" | awk '{print $1}')" = "100644" ] \
        || fail "$IMPL: patch files must be tracked as normal blobs by the primary repo"

    log_success "$IMPL: sparse checkout verified"
}

log_header "Sparse checkout (just)"
IMPL=just
exercise

GO_BIN=$(ensure_go_bin "$REPO_ROOT" || true)
if [ -z "${GO_BIN:-}" ]; then
    log_warn "Go toolchain unavailable or build failed - skipping Go part"
else
    log_header "Sparse checkout (go)"
    setup_sandbox
    cd "$SANDBOX"
    IMPL=go
    exercise
fi

echo "Sparse checkout validation passed!"
