#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

# Test 012: subdir crosses in the v0.6 D3(c) architecture.
#
# Sparse checkout is GONE for subdir crosses. Instead of a sparse filter, the
# patch gitdir holds a SYNTHESIZED subtree branch:
#   refs/heads/<branch>                       synthesized subtree branch — its
#                                            TREE equals refs/cross/upstream/<branch>:<remote_path>
#   refs/cross/synthesized/<branch>           marker pointing at the synthesized head
#   refs/cross/upstream/<branch>              marker pointing at the adopted upstream commit
#   hooks/pre-rebase, hooks/pre-push          guards: plain `git pull -r` / `git push`
#                                            are refused with a 'use: git cross ...' hint
# The crossed directory materializes the subtree RE-ROOTED: <local>/<files>,
# with NO <remote_path>/ prefix inside it.
#
# Whole-repo crosses (remote_path '.') stay sparse-free as before: the upstream
# root is mirrored as-is and no sparse plumbing (and no re-rooting) happens.
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

    # v0.6: NO sparse plumbing in the gitdir (sparse checkout is gone).
    [ -z "$(git --git-dir="$gd" config --get core.sparseCheckout)" ] \
        || fail "$IMPL: core.sparseCheckout must NOT be set in a subdir gitdir (sparse is gone in v0.6)"
    [ ! -e "$gd/info/sparse-checkout" ] \
        || fail "$IMPL: info/sparse-checkout must not exist in a subdir gitdir (sparse is gone in v0.6)"

    # v0.6: refs/cross markers record the synthesized + upstream heads.
    git --git-dir="$gd" rev-parse --verify --quiet "refs/cross/synthesized/main" >/dev/null \
        || fail "$IMPL: refs/cross/synthesized/main marker missing from the gitdir"
    git --git-dir="$gd" rev-parse --verify --quiet "refs/cross/upstream/main" >/dev/null \
        || fail "$IMPL: refs/cross/upstream/main marker missing from the gitdir"

    # v0.6: guard hooks refuse a plain rebase/push and point at git cross.
    [ -x "$gd/hooks/pre-rebase" ] || [ -f "$gd/hooks/pre-rebase" ] \
        || fail "$IMPL: hooks/pre-rebase guard missing from the gitdir"
    [ -x "$gd/hooks/pre-push" ] || [ -f "$gd/hooks/pre-push" ] \
        || fail "$IMPL: hooks/pre-push guard missing from the gitdir"

    # the mirror HEAD is a SYNTHESIZED subtree branch: its TREE equals
    # refs/cross/upstream/main:<remote_path> — NEVER compare raw commit hashes.
    local synth_tree origin_tree
    synth_tree=$(git --git-dir="$gd" rev-parse 'refs/heads/main^{tree}')
    origin_tree=$(git --git-dir="$gd" rev-parse 'refs/cross/upstream/main:apps/app1')
    [ "$synth_tree" = "$origin_tree" ] \
        || fail "$IMPL: synthesized HEAD tree must equal refs/cross/upstream/main:apps/app1 (got $synth_tree vs $origin_tree)"

    # the work tree is the patch dir; the subtree is materialized RE-ROOTED
    # (D3(c): <local>/<files>, no apps/app1 prefix inside the crossed dir).
    [ -f "$wt/data.txt" ] || fail "$IMPL: subtree file must be re-rooted at $wt/data.txt"
    [ ! -e "$wt/apps" ] || fail "$IMPL: remote path prefix 'apps/' must NOT appear inside the patch dir"
    # files outside the subtree must NOT be materialized
    [ ! -e "$wt/root.txt" ] || fail "$IMPL: root.txt found in the patch dir — subtree materialization failed"

    # the primary repo sees the patch files as normal blobs
    git add "$wt" >/dev/null 2>&1 || true
    [ "$(git ls-files -s "$wt/data.txt" | awk '{print $1}')" = "100644" ] \
        || fail "$IMPL: patch files must be tracked as normal blobs by the primary repo"

    log_success "$IMPL: v0.6 subtree-rooted cross verified"
}

exercise_whole_repo() {
    # Whole-repo crosses stay sparse-free: upstream root mirrored as-is,
    # no sparse config (and no re-rooting to verify).
    xc use whole "$upstream_url" >/dev/null
    xc set whole:. vendor/whole >/dev/null

    local gd
    gd=$(jq -r '.patches[] | select(.local_path == "vendor/whole") | .gitdir' .cross/metadata.json)
    [ -d "$gd" ] || fail "$IMPL: gitdir '$gd' does not exist"
    [ -z "$(git --git-dir="$gd" config --get core.sparseCheckout)" ] \
        || fail "$IMPL: whole-repo gitdir must not set core.sparseCheckout"
    [ ! -e "$gd/info/sparse-checkout" ] \
        || fail "$IMPL: whole-repo gitdir must not have info/sparse-checkout"
    [ -f "vendor/whole/root.txt" ] || fail "$IMPL: whole-repo cross must mirror the upstream root"
    [ -f "vendor/whole/apps/app1/data.txt" ] \
        || fail "$IMPL: whole-repo cross keeps the upstream directory structure"

    log_success "$IMPL: whole-repo cross stays sparse-free"
}

log_header "Subtree-rooted cross (just)"
IMPL=just
if just_ref_subdir; then
    exercise
else
    # v0.6: the reference's `set` REFUSES subdir crosses — assert the refusal
    # (the contract) and skip the synthesis assertions (Go owns them).
    set +e
    ref_out=$(just cross set demo:apps/app1 vendor/app1 2>&1)
    ref_rc=$?
    set -e
    [ "$ref_rc" -ne 0 ] || fail "just: set with a subdir remote_path must fail (subtree crosses are Go-only)"
    assert_contains "$ref_out" "subtree crosses" \
        "just: set refusal must explain that subtree crosses are Go-only"
    assert_contains "$ref_out" "git cross set" \
        "just: the refusal must point at the Go CLI"
    log_warn "SKIP (just): subtree crosses are Go-only — refs/cross markers, hooks and synthesis are Go-owned"
fi
exercise_whole_repo

GO_BIN=$(ensure_go_bin "$REPO_ROOT" || true)
if [ -z "${GO_BIN:-}" ]; then
    log_warn "Go toolchain unavailable or build failed - skipping Go part"
else
    log_header "Subtree-rooted cross (go)"
    setup_sandbox
    cd "$SANDBOX"
    IMPL=go
    exercise
    exercise_whole_repo
fi

echo "Subtree-rooted cross validation passed!"
