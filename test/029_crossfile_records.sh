#!/usr/bin/env bash
set -euo pipefail

# Test 029: the Crossfile stays a truthful declaration set.
#
# Three reported defects, pinned here:
#   1. records vanished after `git cross update` — del -> re-declare ->
#      update must keep every record; repeated update must not rewrite the file
#   2. a lost/emptied Crossfile with crosses still registered silently
#      degraded update to "No crosses to update." — now a loud, guided error
#   3. two `use` lines for the same remote name (e.g. one forgejo + one
#      github URL) were accepted silently — now a Crossfile validation error,
#      and `use` re-points a remote (one line per remote, gitdir origins follow)
#
# update/Crossfile validation is Go-only (v0.5.1); the CORE contracts
# (`use` re-pointing, `del` keeping the use record) also run through the
# Just/Fish reference when available.
source "$(dirname "$0")/common.sh"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO_BIN="$(ensure_go_bin "$PROJECT_ROOT")"

make_upstream() {
    local name=$1
    local up
    up=$(create_upstream "$name")
    mkdir -p "$up/demo/cluster-flux/apps" "$up/demo/other"
    echo "flux v1" > "$up/demo/cluster-flux/gotk.yaml"
    echo "flux app" > "$up/demo/cluster-flux/apps/app.yaml"
    echo "other v1" > "$up/demo/other/other.yaml"
    git -C "$up" add -A
    git -C "$up" commit -qm "upstream v1"
    echo "$up"
}

# --- Go: the full del -> re-declare -> update cycle ---------------------------
if [ -n "$GO_BIN" ]; then
    log_header "029: go — records survive del -> re-declare -> update"
    setup_sandbox
    cd "$SANDBOX"
    echo "upstream/" >> .gitignore

    up=$(make_upstream "u-029-go")
    "$GO_BIN" cfg >/dev/null 2>&1 || true
    "$GO_BIN" use up "$up" >/dev/null 2>&1 || fail "go: use"
    "$GO_BIN" set up:main:demo/cluster-flux clusters/cluster-test >/dev/null 2>&1 || fail "go: set"

    grep -qxF "cross use up $up" Crossfile || fail "go: use record missing after set"
    grep -qxF "cross set up:main:demo/cluster-flux clusters/cluster-test" Crossfile \
        || fail "go: set record missing after set"

    # del removes ONLY its own set line — the use record must survive
    "$GO_BIN" del clusters/cluster-test >/dev/null 2>&1 || fail "go: del"
    grep -qxF "cross use up $up" Crossfile || fail "go: del deleted the use record"
    if grep -q "clusters/cluster-test" Crossfile; then
        fail "go: del must remove its own set record"
    fi

    # re-declare (the manual Crossfile edit) -> update re-adopts the cross;
    # the records must survive update — neither deleted nor duplicated
    printf 'cross set up:main:demo/cluster-flux clusters/cluster-test\n' >> Crossfile
    out=$("$GO_BIN" update </dev/null 2>&1) || fail "go: update re-adoption"
    assert_contains "$out" "Cross set successfully" "go: update should re-adopt the cross"
    [ -f clusters/cluster-test/gotk.yaml ] \
        || fail "go: update should materialize the crossed dir"
    grep -qxF "cross use up $up" Crossfile || fail "go: update deleted the use record"
    [ "$(grep -cxF 'cross set up:main:demo/cluster-flux clusters/cluster-test' Crossfile)" -eq 1 ] \
        || fail "go: update must keep exactly one set record (no loss, no duplication)"

    # repeated update does not touch the Crossfile (compare in a shell var:
    # run-all shares one TESTDIR and removes it between tests, so never write there)
    crossfile_before=$(cat Crossfile)
    "$GO_BIN" update </dev/null >/dev/null 2>&1 || fail "go: repeated update"
    [ "$(cat Crossfile)" = "$crossfile_before" ] \
        || fail "go: repeated update must not rewrite the Crossfile"

    log_header "029: go — a lost Crossfile is a loud error, not silence"
    : > Crossfile
    out=$("$GO_BIN" update </dev/null 2>&1) || true
    echo "$out"
    assert_contains "$out" "Crossfile has no cross declarations" "go: emptied Crossfile error"
    assert_contains "$out" "still registered" "go: emptied Crossfile must explain the state"
    grep -q "clusters/cluster-test" .cross/metadata.json \
        || fail "go: the guarded update must not unregister the cross"
    if "$GO_BIN" update </dev/null >/dev/null 2>&1; then
        fail "go: emptied Crossfile must make update exit non-zero"
    fi

    rm -f Crossfile
    out=$("$GO_BIN" update </dev/null 2>&1) || true
    echo "$out"
    assert_contains "$out" "Crossfile is missing" "go: missing Crossfile error"
    assert_contains "$out" "still registered" "go: missing Crossfile must explain the state"

    log_header "029: go — duplicate declarations are validation errors"
    # the reported case: two use lines for one remote name (different URLs)
    cat > Crossfile <<EOF
# git-cross configuration
#cross set up:module modules/up-module
cross use up $up
cross set up:main:demo/cluster-flux clusters/cluster-test

cross use up https://github.com/epcim/mxc.git
EOF
    out=$("$GO_BIN" update </dev/null 2>&1) || true
    echo "$out"
    assert_contains "$out" "duplicate remote declaration 'up'" "go: duplicate use must be an error"
    assert_contains "$out" "exactly one URL" "go: duplicate use error must explain the rule"
    grep -q "clusters/cluster-test" .cross/metadata.json \
        || fail "go: the validated update must not unregister the cross"
    if "$GO_BIN" update </dev/null >/dev/null 2>&1; then
        fail "go: duplicate use must make update exit non-zero"
    fi

    # two set lines for one local_path are equally ambiguous
    cat > Crossfile <<EOF
cross use up $up
cross set up:main:demo/cluster-flux clusters/cluster-test
cross set up:main:demo/other clusters/cluster-test
EOF
    out=$("$GO_BIN" update </dev/null 2>&1) || true
    echo "$out"
    assert_contains "$out" "duplicate cross declaration for 'clusters/cluster-test'" \
        "go: duplicate set must be an error"

    log_header "029: go — use re-points a remote everywhere (one line, origins follow)"
    cat > Crossfile <<EOF
cross use up $up
cross set up:main:demo/cluster-flux clusters/cluster-test
EOF
    up_b=$(make_upstream "u-029-go-b")
    out=$("$GO_BIN" use up "$up_b" 2>&1) || fail "go: use re-point"
    assert_contains "$out" "Re-pointing remote up: $up -> $up_b" "go: re-point announcement"
    grep -qxF "cross use up $up_b" Crossfile || fail "go: re-point must rewrite the use line"
    [ "$(grep -c '^cross use up ' Crossfile)" -eq 1 ] \
        || fail "go: one use line per remote (no stale duplicate)"
    gd=$("$GO_BIN" env clusters/cluster-test --gitdir)
    [ "$(git --git-dir="$gd" remote get-url origin)" = "$up_b" ] \
        || fail "go: re-point must update the gitdir origin"
    grep -qxF "cross set up:main:demo/cluster-flux clusters/cluster-test" Crossfile \
        || fail "go: re-point must keep the set record untouched"

    log_success "029: go — Crossfile records stay truthful"
else
    echo "SKIP: Go CLI unavailable"
fi

# --- Just/Fish: CORE contracts (use re-pointing, del keeps the use record) ----
if command -v fish >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v just >/dev/null 2>&1; then
    log_header "029: just/fish — use re-points; del keeps the use record"
    setup_sandbox
    cd "$SANDBOX"
    echo "upstream/" >> .gitignore

    up=$(make_upstream "u-029-just")
    up_b=$(make_upstream "u-029-just-b")
    just cross cfg >/dev/null 2>&1 || true
    just cross use up "$up" >/dev/null 2>&1 || fail "just: use"
    # v0.6: subdir crosses are Go-only in the reference — use the whole-repo
    # form (remote_path '.') so the core use-re-point/del contracts stay covered.
    just cross set up:main:. clusters/cluster-test >/dev/null 2>&1 || fail "just: set"
    grep -qxF "cross use up $up" Crossfile || fail "just: use record missing after set"

    # use re-points: one line per remote, gitdir origin + metadata follow
    out=$(just cross use up "$up_b" 2>&1) || fail "just: use re-point"
    assert_contains "$out" "Re-pointing remote up: $up -> $up_b" "just: re-point announcement"
    grep -qxF "cross use up $up_b" Crossfile || fail "just: re-point must rewrite the use line"
    [ "$(grep -c '^cross use up ' Crossfile)" -eq 1 ] \
        || fail "just: one use line per remote (no stale duplicate)"
    gd=$(jq -r --arg lp "clusters/cluster-test" \
        '.patches[] | select(.local_path == $lp) | .gitdir' .cross/metadata.json)
    [ "$(git --git-dir="$gd" remote get-url origin)" = "$up_b" ] \
        || fail "just: re-point must update the gitdir origin"
    [ "$(jq -r '.remotes[] | select(.name == "up") | .url' .cross/metadata.json)" = "$up_b" ] \
        || fail "just: re-point must update the metadata remote url"

    # del keeps the use record
    just cross del clusters/cluster-test >/dev/null 2>&1 || fail "just: del"
    grep -qxF "cross use up $up_b" Crossfile || fail "just: del deleted the use record"
    if grep -q "clusters/cluster-test" Crossfile; then
        fail "just: del must remove its own set record"
    fi
    log_success "029: just/fish — core contracts hold"
else
    echo "SKIP: fish/jq/just unavailable — skipping the Just/Fish variant"
fi

echo "Test 029 passed!"
