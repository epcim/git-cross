#!/usr/bin/env bash
# Test 023: local_path normalization (`./sub` must behave like `sub`).
#
# Regression: `patch <remote>:./sub` stored "./sub" in metadata, so CWD
# auto-detection, diff/cd/stat and `remove ./sub` failed to match.
# (`compare` was removed in 0.5.0, so `cd`/`diff`/`stat` are the probes.)
#
# v0.5.0 note: each patch owns its own gitdir under
# .cross/worktrees/<remote>/<local_path>, so one upstream source patched into
# several local dirs yields INDEPENDENT gitdirs (no shared state). Removing one
# must leave the others intact.
source "$(dirname "$0")/common.sh"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO_BIN="$(ensure_go_bin "$PROJECT_ROOT")"

assert_metadata_normalized() {
    local meta=".cross/metadata.json"
    jq -r '.patches[].local_path' "$meta" | grep -qx "sub" || fail "metadata missing normalized local_path 'sub'"
    jq -r '.patches[].local_path' "$meta" | grep -qx "sub2" || fail "metadata missing normalized local_path 'sub2'"
    if jq -e '.patches[] | select(.local_path | startswith("./"))' "$meta" >/dev/null 2>&1; then
        fail "metadata still contains a './' prefixed local_path"
        jq -r '.patches[].local_path' "$meta" | sed 's/^/  /' >&2
    fi
    # ADR-001: the worktree field is normalized too
    if jq -e '.patches[] | select(.worktree | startswith("./"))' "$meta" >/dev/null 2>&1; then
        fail "metadata still contains a './' prefixed worktree"
    fi
}

assert_one_abs_path() {
    local label=$1
    local output=$2
    local expected=$3
    local line_count
    line_count=$(printf '%s\n' "$output" | sed '/^$/d' | wc -l | tr -d ' ')
    [ "$line_count" -eq 1 ] || fail "$label: expected exactly one line of output, got $line_count: $output"
    case "$output" in
        /*) ;;
        *) fail "$label: expected an absolute path, got: $output" ;;
    esac
    assert_not_contains "$output" "Opening shell" "$label: must not mention opening a shell"
    assert_not_contains "$output" "clipboard" "$label: must not copy to the clipboard"
    [ "$output" = "$expected" ] || fail "$label: expected '$expected', got '$output'"
}

# Shared body for both implementations ($1 = label, uses xc()).
exercise() {
    local who=$1
    # v0.5.1: cd is Go-only in the Just reference (NOT IMPLEMENTED stub) — its
    # assertions skip there; set/del/ls and the diff passthrough stay covered.
    local has_cd=1
    if [ "${IMPL:-}" = "just" ] && ! just_ref_implements cd; then
        has_cd=0
        log_warn "SKIP (just): cd is Go-only — NOT IMPLEMENTED in the Just reference (v0.5.1)"
    fi
    # v0.6: subdir crosses (remote_path != '.') are Go-only — the reference's
    # `set` refuses them. The whole-repo './sub' case stays covered for both;
    # sub2 falls back to a whole-repo cross for just (with the upstream layout),
    # and the subdir-only sections (two local dirs from up:main:pkg, the stale
    # vendor/b worktree probe) are skipped there after pinning the refusal.
    local has_subdir=1
    local sub2_spec="up:main:pkg" sub2_pkgfile="pkg.txt"
    if [ "${IMPL:-}" = "just" ] && ! just_ref_subdir; then
        has_subdir=0
        set +e
        ref_out=$(xc set "up:main:pkg" vendor/a 2>&1)
        ref_rc=$?
        set -e
        [ "$ref_rc" -ne 0 ] || fail "$who: set with a subdir remote_path must fail (subtree crosses are Go-only)"
        assert_contains "$ref_out" "subtree crosses" \
            "$who: set refusal must explain that subtree crosses are Go-only"
        log_warn "SKIP (just): subtree crosses are Go-only — subdir sections skipped"
        sub2_spec="up:main:."
        sub2_pkgfile="pkg/pkg.txt"
    fi

    log_header "023: patch with './' prefixed local paths ($who)"
    xc set "up:main:." ./sub >/dev/null
    xc set "$sub2_spec" ./sub2 >/dev/null
    assert_dir_exists "sub"
    assert_dir_exists "sub2"
    assert_metadata_normalized
    log_success "$who: metadata stores local_path without './'"

    log_header "023: one upstream source patched into two local dirs ($who)"
    if [ "$has_subdir" = 1 ]; then
    xc set "up:main:pkg" vendor/a >/dev/null
    xc set "up:main:pkg" vendor/b >/dev/null
    assert_dir_exists "vendor/a"
    assert_dir_exists "vendor/b"
    # D3 nesting: remote_path pkg/ lands at <patch>/pkg/
    [ -f vendor/a/pkg.txt ] || fail "$who: vendor/a was not materialized (expected vendor/a/pkg.txt)"
    [ -f vendor/b/pkg.txt ] || fail "$who: vendor/b was not materialized (expected vendor/b/pkg.txt)"

    gd_a=$(jq -r '.patches[] | select(.local_path == "vendor/a") | .gitdir' .cross/metadata.json)
    gd_b=$(jq -r '.patches[] | select(.local_path == "vendor/b") | .gitdir' .cross/metadata.json)
    [ -n "$gd_a" ] && [ "$gd_a" != "null" ] || fail "$who: metadata lost the vendor/a gitdir"
    [ -n "$gd_b" ] && [ "$gd_b" != "null" ] || fail "$who: metadata lost the vendor/b gitdir"
    # v2: one gitdir PER PATCH (independent), unlike 0.4's shared hash worktree
    [ "$gd_a" != "$gd_b" ] || fail "$who: each patch must own its gitdir (got the same path: $gd_a)"
    [ -d "$gd_a" ] && [ -d "$gd_b" ] || fail "$who: both patch gitdirs must exist on disk"
    grep -q "vendor/a" Crossfile || fail "$who: Crossfile missing the vendor/a declaration"
    grep -q "vendor/b" Crossfile || fail "$who: Crossfile missing the vendor/b declaration"
    log_success "$who: two local dirs have independent gitdirs and metadata entries"

    log_header "023: removing one local dir leaves the other intact ($who)"
    xc del vendor/a >/dev/null 2>&1 || fail "$who: remove vendor/a failed"
    [ ! -d vendor/a ] || fail "$who: remove vendor/a left the local directory behind"
    [ ! -d "$gd_a" ] || fail "$who: remove vendor/a left its gitdir behind"
    [ -d "$gd_b" ] || fail "$who: removing vendor/a deleted vendor/b's gitdir"
    [ -f vendor/b/pkg.txt ] || fail "$who: vendor/b content disappeared"
    [ "$(jq -r '.patches[] | select(.local_path == "vendor/b") | .gitdir' .cross/metadata.json)" = "$gd_b" ] \
        || fail "$who: vendor/b lost its gitdir entry"
    log_success "$who: independent gitdirs survive removing one local dir"
    else
        log_warn "SKIP (just): two-local-dirs subdir fixture is Go-only"
    fi

    nofzf_path=$(make_path_without_fzf "$SANDBOX/no-fzf-bin-$who")
    sub_abs=$(cd sub && pwd -P)

    log_header "023: cd/diff/stat resolve from inside ./sub ($who)"
    pushd sub >/dev/null
    if [ "$has_cd" = 1 ]; then
        out=$(xc cd 2>/dev/null) || fail "$who: cd inside a './sub' patch should resolve"
        echo "$out"
        [ "$out" = "$sub_abs" ] || fail "$who: cd inside ./sub should print $sub_abs, got: $out"
    fi

    echo "local sub change" >> root.txt
    out=$(xc diff 2>&1) || true
    echo "$out"
    assert_contains "$out" "local sub change" "$who: diff inside ./sub should auto-detect the patch"
    assert_not_contains "$out" "patch not found"

    if [ "$has_cd" = 1 ]; then
        out=$(xc cd sub 2>/dev/null) || fail "$who: cd sub inside a './sub' patch should resolve"
        assert_one_abs_path "$who: cd sub inside ./sub" "$out" "$sub_abs"
    fi

    # No path at all: CWD auto-detect must win before fzf is consulted.
    if [ "$has_cd" = 1 ]; then
        out=$(PATH="$nofzf_path" xc cd 2>/dev/null) \
            || fail "$who: cd without a path inside ./sub should auto-detect from CWD"
        assert_one_abs_path "$who: cd (CWD auto-detect) inside ./sub" "$out" "$sub_abs"
    fi

    out=$(xc ls 2>&1) || true
    echo "$out"
    assert_contains "$out" "sub" "$who: ls should list the normalized local_path"
    popd >/dev/null

    log_header "023: cd/diff resolve from inside ./sub2 ($who)"
    pushd sub2 >/dev/null
    sub2_abs=$(pwd -P)
    if [ "$has_cd" = 1 ]; then
        out=$(xc cd 2>/dev/null) || fail "$who: cd inside a './sub2' patch should resolve"
        [ "$out" = "$sub2_abs" ] || fail "$who: cd inside ./sub2 should print $sub2_abs, got: $out"
    fi
    echo "local sub2 change" >> "$sub2_pkgfile"
    out=$(xc diff 2>&1) || true
    assert_contains "$out" "local sub2 change"
    expected=$(pwd -P)
    if [ "$has_cd" = 1 ]; then
        out=$(xc cd sub2 2>/dev/null) || fail "$who: cd sub2 inside a './sub2' patch should resolve"
        assert_one_abs_path "$who: cd sub2 inside ./sub2" "$out" "$expected"
    fi
    if [ "$has_cd" = 1 ]; then
        out=$(PATH="$nofzf_path" xc cd 2>/dev/null) \
            || fail "$who: cd without a path inside ./sub2 should auto-detect from CWD"
        assert_one_abs_path "$who: cd (CWD auto-detect) inside ./sub2" "$out" "$expected"
    fi
    popd >/dev/null

    log_header "023: explicit './' path arguments resolve ($who)"
    if [ "$has_cd" = 1 ]; then
        out=$(xc cd ./sub 2>/dev/null) || fail "$who: cd ./sub from the repo root should resolve"
        [ "$out" = "$sub_abs" ] || fail "$who: cd ./sub should print $sub_abs, got: $out"
    fi

    log_header "023: remove ./sub2 resolves the normalized entry ($who)"
    xc del ./sub2 >/dev/null 2>&1 || fail "$who: remove ./sub2 should resolve the stored 'sub2' path"
    [ ! -d "sub2" ] || fail "$who: remove ./sub2 left the sub2 directory behind"
    if jq -e '.patches[] | select(.local_path == "sub2")' .cross/metadata.json >/dev/null 2>&1; then
        fail "$who: remove ./sub2 left the entry in metadata"
    fi
    if grep -q "sub2" Crossfile 2>/dev/null; then
        fail "$who: remove ./sub2 left the entry in Crossfile"
    fi
    log_success "$who: normalized './' arguments resolve"

    if [ "$has_subdir" = 0 ]; then
        log_warn "SKIP (just): stale-worktree probe needs the vendor/b subdir cross (Go-only)"
    else
    log_header "023: stale v0.4 worktree (inside .cross/) self-heals ($who)"
    # Regression (reported on a pre-0.5 repo): old metadata kept worktree inside
    # .cross/worktrees/<name>_<hash>, so cd printed the hidden gitdir/old worktree
    # instead of the crossed directory. ADR-001: worktree == local_path since
    # 0.5.0 — stale values must be ignored.
    local stale_meta
    stale_meta=$(mktemp)
    jq '(.patches[] | select(.local_path == "vendor/b") | .worktree) = ".cross/worktrees/vendor_b_c30e3178"' \
        .cross/metadata.json > "$stale_meta" && mv "$stale_meta" .cross/metadata.json
    if [ "$has_cd" = 1 ]; then
        out=$(xc cd vendor/b 2>/dev/null) || fail "$who: cd vendor/b with a stale worktree should resolve"
        assert_one_abs_path "$who: stale-worktree cd" "$out" "$PWD/vendor/b"
        assert_not_contains "$out" ".cross/worktrees" "$who: cd must never print a hidden .cross path"
    fi
    log_success "$who: stale worktree ignored; cd prints the crossed dir"
    fi
}

fixture() {
    upstream_path=$(create_upstream "$1")
    pushd "$upstream_path" >/dev/null
    mkdir -p pkg
    echo "root v1" > root.txt
    echo "pkg v1" > pkg/pkg.txt
    git add root.txt pkg/pkg.txt
    git commit -m "Add content" -q
    popd >/dev/null
    printf 'file://%s\n' "$upstream_path"
}

# ---------------------------------------------------------------- Go section
if [ -n "$GO_BIN" ]; then
    cd "$PROJECT_ROOT"
    setup_sandbox
    cd "$SANDBOX"
    xc() { "$GO_BIN" "$@"; }
    IMPL=go
    upstream_url=$(fixture "normalize-demo")
    "$GO_BIN" use up "$upstream_url" >/dev/null
    exercise "Go"
fi

# -------------------------------------------------------------- Just section
if command -v fish >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v just >/dev/null 2>&1; then
    cd "$PROJECT_ROOT"
    setup_sandbox
    cd "$SANDBOX"
    xc() { just cross "$@"; }
    IMPL=just
    upstream_url=$(fixture "normalize-demo-just")
    just cross use up "$upstream_url" >/dev/null
    exercise "Just"
else
    echo "SKIP: fish and/or jq/just unavailable; skipping Just assertions"
fi

echo "Test 023 passed!"
