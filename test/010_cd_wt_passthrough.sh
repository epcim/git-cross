#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

# Test 010: cd / wt in the v0.5.0 architecture.
#
#   cd [path]      prints the crossed directory (absolute); the xcd wrapper
#                  performs the real directory change in the parent shell.
#   wt <git-args>  git passthrough in the patch's UPSTREAM context
#                  (GIT_DIR=<bare gitdir>, GIT_WORK_TREE=<patch dir>).
#   git cross <native-git-cmd>   same passthrough. Outside a patch dir it FAILS
#                  early (no GIT_DIR/GIT_WORK_TREE to configure) — it never falls
#                  back to plain git on the primary repo (ADR-002).

setup_sandbox
cd "$SANDBOX"

upstream_path=$(create_upstream "shell-worktree")
upstream_url="file://$upstream_path"

pushd "$upstream_path" >/dev/null
mkdir -p src
echo "shell data" > src/data.txt
git add src/data.txt
git commit -m "Add shell data" >/dev/null
popd >/dev/null

# Dispatch to the implementation under test (IMPL=just|go).
xc() {
    if [ "$IMPL" = "just" ]; then
        just cross "$@"
    else
        "$GO_BIN" "$@"
    fi
}

exercise() {
    xc use demo "$upstream_url" >/dev/null
    xc set demo:src vendor/shell-src >/dev/null

    # ADR-001: metadata records every location explicitly.
    local gd wt
    gd=$(jq -r '.patches[] | select(.local_path == "vendor/shell-src") | .gitdir' .cross/metadata.json)
    wt=$(jq -r '.patches[] | select(.local_path == "vendor/shell-src") | .worktree' .cross/metadata.json)
    [ -n "$gd" ] && [ "$gd" != "null" ] || fail "$IMPL: metadata is missing 'gitdir'"
    [ -n "$wt" ] && [ "$wt" != "null" ] || fail "$IMPL: metadata is missing 'worktree'"
    [ "$wt" = "vendor/shell-src" ] || fail "$IMPL: worktree should equal local_path, got '$wt'"
    [ -d "$gd" ] || fail "$IMPL: gitdir '$gd' does not exist"
    # the work tree is the patch dir inside the repo — no .git pointer
    [ ! -e "$wt/.git" ] || fail "$IMPL: patch dir must not contain a .git file"

    # cd with an explicit path: stdout is exactly the absolute patch dir.
    # (v0.5.1: cd/wt are Go-only in the Just reference — skip their assertions there;
    #  the passthrough below is core and stays covered for both.)
    local expected_local output
    expected_local=$(cd vendor/shell-src && pwd -P)
    if [ "$IMPL" != "just" ] || just_ref_implements cd; then
        output=$(xc cd vendor/shell-src 2>/dev/null)
        [ "$output" = "$expected_local" ] \
            || fail "$IMPL: cd with explicit path returned '$output', expected '$expected_local'"
    fi

    # cd from inside the patch dir resolves via CWD.
    pushd vendor/shell-src >/dev/null
        if [ "$IMPL" != "just" ] || just_ref_implements cd; then
            output=$(xc cd 2>/dev/null)
            [ "$output" = "$expected_local" ] \
                || fail "$IMPL: cd from patch dir returned '$output', expected '$expected_local'"

            # wt is an alias of cd: same absolute path, no git passthrough
            output=$(xc wt 2>/dev/null)
            [ "$output" = "$expected_local" ] \
                || fail "$IMPL: wt (cd alias) returned '$output', expected '$expected_local'"
        fi

        # wt runs git against the UPSTREAM: the work tree root is the patch dir.
        output=$(xc rev-parse --show-toplevel 2>/dev/null)
        [ "$output" = "$expected_local" ] \
            || fail "$IMPL: passthrough --show-toplevel returned '$output', expected the patch dir"

        # ... and upstream data is visible (D3: files live under src/).
        # NB: no `| head -1` here — under `set -o pipefail` the early-closed pipe
        # gives the child SIGPIPE (141) and aborts the script.
        output=$(xc remote -v 2>/dev/null)
        assert_contains "$output" "$upstream_url" "$IMPL: passthrough remote must show the upstream URL"
        output=$(xc log --oneline 2>/dev/null)
        assert_contains "$output" "Add shell data" "$IMPL: wt log must show upstream history"
        output=$(xc ls-files 2>/dev/null)
        assert_contains "$output" "src/data.txt" "$IMPL: wt ls-files must list the nested upstream file"

        # bare native passthrough reaches the same context
        output=$(xc log --oneline 2>/dev/null)
        assert_contains "$output" "Add shell data" "$IMPL: git cross log must use the upstream context"
    popd >/dev/null

    # v0.5.1 bugfix probes: recognition is path-segment aware. ANY depth inside
    # the crossed dir is patch context; a sibling dir that merely shares a
    # string prefix must NOT match (Just _resolve_context2 used startswith).
    mkdir -p vendor/shell-src/deeply/nested vendor/shell-srcx
    pushd vendor/shell-src/deeply/nested >/dev/null
        output=$(xc rev-parse --show-toplevel 2>/dev/null)
        [ "$output" = "$expected_local" ] \
            || fail "$IMPL: a deep subdir must still resolve to the crossed dir"
    popd >/dev/null
    pushd vendor/shell-srcx >/dev/null
        set +e
        output=$(xc rev-parse --show-toplevel 2>&1)
        sib_rc=$?
        set -e
        echo "$output"
        [ "$sib_rc" -ne 0 ] || fail "$IMPL: sibling dir sharing a name prefix must NOT be patch context"
        assert_contains "$output" "not inside a crossed directory" "$IMPL: sibling miss must keep the crossed-dir hint"
    popd >/dev/null

    # Git !-alias simulation (v0.5.2 fix): git runs `!`-aliases from the REPO
    # ROOT and exports GIT_PREFIX (the caller's original CWD, root-relative).
    # `git cross <git-args>` through an alias must still resolve the cross.
    if [ "$IMPL" = "just" ]; then
        git config alias.crossx '!just cross'
    else
        git config alias.crossx "!$GO_BIN"
    fi
    pushd vendor/shell-src >/dev/null
        set +e
        output=$(git crossx rev-parse --show-toplevel 2>&1)
        alias_rc=$?
        set -e
        echo "$output"
        [ "$alias_rc" -eq 0 ] || fail "$IMPL: git !-alias invocation must resolve the cross via GIT_PREFIX"
        [ "$output" = "$expected_local" ] \
            || fail "$IMPL: git !-alias rev-parse must print the crossed dir, got '$output'"
        set +e
        dbg_out=$(CROSS_DEBUG=1 git crossx status --short 2>&1)
        dbg_rc=$?
        set -e
        echo "$dbg_out"
        [ "$dbg_rc" -eq 0 ] || fail "$IMPL: aliased status must succeed"
        assert_contains "$dbg_out" "GIT_DIR=" "$IMPL: CROSS_DEBUG=1 must print the passthrough env"
    popd >/dev/null

    # Outside a patch dir the passthrough FAILS early: there is no
    # GIT_DIR/GIT_WORK_TREE to configure, and silently running git on the primary
    # repo would make `git cross pull -r` pull the wrong repository (ADR-002).
    set +e
    out=$(xc rev-parse --show-toplevel 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "$IMPL: native passthrough outside a patch dir must fail too"
    assert_contains "$out" "crossed directory" "$IMPL: native passthrough must explain the missing patch context"

    # A mistyped cross command says so and suggests the closest one; a real
    # git command keeps the crossed-dir hint (no misleading suggestions).
    set +e
    out=$(xc commp fish 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "$IMPL: typo 'commp' should fail"
    assert_contains "$out" "not a git-cross command" "$IMPL: 'commp' must be reported as not a cross command"
    assert_contains "$out" "did you mean: comp" "$IMPL: 'commp' should suggest 'comp'"
    out=$(xc status 2>&1) || true
    assert_contains "$out" "not inside a crossed directory" "$IMPL: 'status' outside must keep the crossed-dir hint (no 'stat' suggestion)"

    # plain git inside the patch dir still targets the primary repo
    output=$(cd vendor/shell-src && git rev-parse --show-toplevel)
    assert_contains "$output" "$SANDBOX" "$IMPL: plain git in a patch dir must target the primary repo"

    log_success "$IMPL: cd/wt/passthrough semantics verified"
}

log_header "cd/wt tests (just)"
IMPL=just
exercise

GO_BIN=$(ensure_go_bin "$REPO_ROOT" || true)
if [ -z "${GO_BIN:-}" ]; then
    log_warn "Go toolchain unavailable or build failed - skipping Go part"
else
    log_header "cd/wt tests (go)"
    # fresh sandbox so both implementations exercise the same starting state
    setup_sandbox
    cd "$SANDBOX"
    IMPL=go
    exercise
fi

echo "010 cd/wt tests passed!"
