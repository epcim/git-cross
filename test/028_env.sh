#!/usr/bin/env bash
# Test 028: `git cross env` + the gxenv wrapper (Go).
#
# Contract:
#   `git cross env` prints EVALUABLE shell code that points plain git at a
#     crossed dir's UPSTREAM: GIT_DIR (the patch's bare gitdir), GIT_WORK_TREE
#     (the crossed dir = upstream root) and CROSS_ACTIVE (the local_path).
#     Default is POSIX (`export ...`); `--fish` prints `set -gx ...`;
#     `--unset` prints the inverse for the same syntax; `--json` and
#     `--gitdir`/`--worktree`/`--local-path` print bare values (wrappers/scripts).
#     It resolves the cross from the CWD (any depth inside it) or from an
#     explicit path arg, and FAILS (exit 1, stderr hint, empty stdout) when no
#     cross matches or the gitdir is missing (the env would be useless).
#   With the env loaded: plain `git` speaks upstream (log/status/diff), while
#     `git cross ...` KEEPS working — repo discovery ignores a GIT_DIR that
#     points into .cross/worktrees/, so the primary repo (and its registry) is
#     still found, and GIT_PREFIX from the `git cross` alias is re-based onto
#     the crossed dir (CROSS_ACTIVE) instead of the repo root.
#   gxenv (from `git cross comp`) defaults to a NESTED shell, so leaving it
#     unloads — nothing leaks into the caller's shell. `gxenv -i` loads into the
#     current shell, `gxenv -u` unloads it again.
source "$(dirname "$0")/common.sh"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO_BIN="$(ensure_go_bin "$PROJECT_ROOT")"

if [ -z "$GO_BIN" ]; then
    echo "SKIP: Go CLI unavailable"
    echo "Test 028 passed!"
    exit 0
fi

setup_cross() {
    setup_sandbox
    cd "$SANDBOX"
    echo "upstream/" >> .gitignore

    local up
    up=$(create_upstream "u-env")
    mkdir -p "$up/docs"
    echo "guide v1" > "$up/docs/guide.md"
    git -C "$up" add -A
    git -C "$up" commit -qm "docs v1"
    echo "guide v2" > "$up/docs/guide.md"
    git -C "$up" add -A
    git -C "$up" commit -qm "docs v2"

    # The wrapper calls `git cross`; put our binary on PATH as git-cross.
    mkdir -p "$SANDBOX/bin"
    ln -sf "$GO_BIN" "$SANDBOX/bin/git-cross"
    export PATH="$SANDBOX/bin:$PATH"

    "$GO_BIN" use up "$up" >/dev/null 2>&1 || fail "use"
    "$GO_BIN" set up:docs vendor/docs >/dev/null 2>&1 || fail "set"
    assert_file_exists "vendor/docs/docs/guide.md"
    git add -A && git commit -qm "vendor: initial" >/dev/null
}

log_header "028: env prints the upstream context for the cross at \$PWD"
setup_cross
GD_ABS="$(pwd)/.cross/worktrees/up/vendor_docs"
WT_ABS="$(pwd)/vendor/docs"
export GO_BIN GD_ABS WT_ABS   # the nested-shell cases run bash -c scripts
out=$(cd vendor/docs && "$GO_BIN" env)
echo "$out"
assert_contains "$out" "export GIT_DIR='$GD_ABS'" "env must export the absolute gitdir"
assert_contains "$out" "export GIT_WORK_TREE='$WT_ABS'" "env must export the absolute work tree"
assert_contains "$out" "export CROSS_ACTIVE='vendor/docs'" "env must export the local_path marker"
assert_contains "$out" "export CROSS_REMOTE='up'" "env must export the remote name"
log_success "env prints GIT_DIR + GIT_WORK_TREE + CROSS_ACTIVE"

log_header "028: env works from any depth inside the cross and from a path arg"
out=$(cd vendor/docs/docs && "$GO_BIN" env)
assert_contains "$out" "export GIT_DIR='$GD_ABS'" "env must resolve from a subdirectory"
out=$("$GO_BIN" env vendor/docs)
assert_contains "$out" "export GIT_WORK_TREE='$WT_ABS'" "env must accept a local_path argument"
out=$("$GO_BIN" env "$WT_ABS/docs")
assert_contains "$out" "export CROSS_ACTIVE='vendor/docs'" "env must accept an absolute path"
log_success "CWD (any depth), relative and absolute path args resolve"

log_header "028: no cross / missing gitdir is a hard error (nothing on stdout)"
out=$("$GO_BIN" env 2>/tmp/env028.err); rc=$?
[ "$rc" -eq 1 ] || fail "env outside a cross must exit 1 (got $rc)"
[ -z "$out" ] || fail "env must not print shell code when no cross matches: $out"
assert_contains "$(cat /tmp/env028.err)" "no cross matches the working directory" \
    "env must explain that no cross matches"
out=$("$GO_BIN" env nope/missing 2>/dev/null); rc=$?
[ "$rc" -eq 1 ] || fail "env with an unknown path must exit 1"
[ -z "$out" ] || fail "env must print nothing for an unknown path"
mv .cross/worktrees/up/vendor_docs .cross/worktrees/up/vendor_docs.bak
out=$("$GO_BIN" env vendor/docs 2>/tmp/env028.err); rc=$?
[ "$rc" -eq 1 ] || fail "env must exit 1 when the gitdir is missing"
assert_contains "$(cat /tmp/env028.err)" "gitdir missing for vendor/docs" \
    "env must name the missing gitdir"
mv .cross/worktrees/up/vendor_docs.bak .cross/worktrees/up/vendor_docs
log_success "fail-fast when there is no usable cross"

log_header "028: --gitdir / --worktree / --local-path / --json print bare values"
[ "$("$GO_BIN" env --gitdir vendor/docs)" = "$GD_ABS" ] || fail "--gitdir must print the absolute gitdir"
[ "$("$GO_BIN" env --worktree vendor/docs)" = "$WT_ABS" ] || fail "--worktree must print the absolute work tree"
[ "$("$GO_BIN" env --local-path vendor/docs)" = "vendor/docs" ] || fail "--local-path must print the local_path"
[ "$("$GO_BIN" env --remote vendor/docs)" = "up" ] || fail "--remote must print the remote name"
json=$("$GO_BIN" env --json vendor/docs)
[ "$(printf '%s' "$json" | jq -r .git_dir)" = "$GD_ABS" ] || fail "--json git_dir"
[ "$(printf '%s' "$json" | jq -r .work_tree)" = "$WT_ABS" ] || fail "--json work_tree"
[ "$(printf '%s' "$json" | jq -r .local_path)" = "vendor/docs" ] || fail "--json local_path"
[ "$(printf '%s' "$json" | jq -r .branch)" = "$(jq -r '.patches[] | select(.local_path=="vendor/docs") | .branch' .cross/metadata.json)" ] \
    || fail "--json must report the upstream branch of the cross"
log_success "scalar values and JSON"

log_header "028: --fish and --unset print the matching syntax"
out=$("$GO_BIN" env --fish vendor/docs)
echo "$out"
assert_contains "$out" "set -gx GIT_DIR '$GD_ABS'" "fish must use set -gx"
assert_contains "$out" "set -gx CROSS_ACTIVE 'vendor/docs'" "fish must set the marker"
[ "$("$GO_BIN" env --unset)" = "unset GIT_DIR GIT_WORK_TREE CROSS_ACTIVE CROSS_REMOTE" ] \
    || fail "--unset must print the POSIX unload line"
[ "$("$GO_BIN" env --fish --unset)" = "set -e GIT_DIR GIT_WORK_TREE CROSS_ACTIVE CROSS_REMOTE" ] \
    || fail "--fish --unset must print the fish unload line"
printf '%s\n' "$out" | fish -n 2>/dev/null || true
log_success "fish syntax + unload lines"

log_header "028: evaluated context makes plain git speak UPSTREAM"
echo "local edit" >> vendor/docs/docs/guide.md
out=$(cd vendor/docs && eval "$("$GO_BIN" env)" && git rev-parse --show-toplevel)
[ "$out" = "$WT_ABS" ] || fail "git toplevel must be the crossed dir, got: $out"
out=$(cd vendor/docs && eval "$("$GO_BIN" env)" && git log --oneline -1)
assert_contains "$out" "docs v2" "plain git log must show the upstream commit"
out=$(cd vendor/docs && eval "$("$GO_BIN" env)" && git diff --name-only)
echo "$out"
[ "$out" = "docs/guide.md" ] || fail "plain git diff must be upstream-relative (docs/guide.md), got: $out"
git checkout -- vendor/docs/docs/guide.md
log_success "plain git inside the loaded context sees upstream"

log_header "028: with the env loaded, git-cross itself keeps working"
out=$(cd vendor/docs && eval "$("$GO_BIN" env)" && "$GO_BIN" ls --raw --no-header | awk -F'\t' '$3=="vendor/docs"')
assert_contains "$out" "vendor/docs" "git cross ls must still find the primary repo registry"
out=$(cd vendor/docs/docs && eval "$("$GO_BIN" env)" && "$GO_BIN" env --local-path)
[ "$out" = "vendor/docs" ] || fail "git cross env must be idempotent with the env loaded, got: $out"
# The `git cross` git-alias runs from the toplevel (= the crossed dir when the
# env is loaded) and hands the caller's location over in GIT_PREFIX; it must be
# re-based onto CROSS_ACTIVE, not onto the primary repo root.
out=$(cd vendor/docs && GIT_PREFIX=docs/ GIT_DIR="$GD_ABS" GIT_WORK_TREE="$WT_ABS" CROSS_ACTIVE=vendor/docs \
    "$GO_BIN" log --oneline -1)
assert_contains "$out" "docs v2" "the passthrough must resolve GIT_PREFIX relative to the crossed dir"
out=$(cd vendor/docs && GIT_PREFIX=docs/ GIT_DIR="$GD_ABS" GIT_WORK_TREE="$WT_ABS" CROSS_ACTIVE=vendor/docs \
    "$GO_BIN" env --local-path)
[ "$out" = "vendor/docs" ] || fail "env must resolve the patch from a re-based GIT_PREFIX, got: $out"
log_success "registry, idempotency and the alias GIT_PREFIX path all survive"

log_header "028: gxenv wrapper — nested shell by default, -i/-u in this shell"
cat > "$SANDBOX/fake-shell.sh" <<'EOS'
#!/bin/sh
echo "nested GIT_DIR=$GIT_DIR WORK_TREE=$GIT_WORK_TREE ACTIVE=$CROSS_ACTIVE"
EOS
chmod +x "$SANDBOX/fake-shell.sh"
out=$(cd vendor/docs && SHELL="$SANDBOX/fake-shell.sh" bash -c '
    eval "$("$GO_BIN" comp bash)" || exit 1
    gxenv || exit 1
    echo "parent GIT_DIR=[${GIT_DIR:-}] ACTIVE=[${CROSS_ACTIVE:-}]"
' )
echo "$out"
assert_contains "$out" "nested GIT_DIR=$GD_ABS WORK_TREE=$WT_ABS ACTIVE=vendor/docs" \
    "gxenv must run a nested shell with the upstream context exported"
assert_contains "$out" "parent GIT_DIR=[] ACTIVE=[]" \
    "gxenv must NOT leak the context into the caller's shell"
out=$(cd vendor/docs && bash -c '
    eval "$("$GO_BIN" comp bash)" || exit 1
    PS1="prompt\$ "
    gxenv -i || exit 1
    echo "loaded GIT_DIR=[$GIT_DIR] ACTIVE=[$CROSS_ACTIVE] git=$(git log --oneline -1)"
    echo "marked PS1=[$PS1]"
    gxenv -u
    echo "unloaded GIT_DIR=[${GIT_DIR:-}] ACTIVE=[${CROSS_ACTIVE:-}] PS1=[$PS1]"
')
echo "$out"
assert_contains "$out" "loaded GIT_DIR=[$GD_ABS] ACTIVE=[vendor/docs] git=" \
    "gxenv -i must load the context into the current shell"
assert_contains "$out" "docs v2" "gxenv -i must make plain git see upstream"
assert_contains "$out" "marked PS1=[prompt\$ [cross:up] ]" "gxenv -i must mark the prompt"
assert_contains "$out" "unloaded GIT_DIR=[] ACTIVE=[] PS1=[prompt\$ ]" \
    "gxenv -u must unload the context and restore the prompt"
log_success "gxenv: nested by default, -i loads, -u unloads"

if command -v fish >/dev/null 2>&1; then
    log_header "028: fish — gxenv loads with -i and unloads with -u"
    (cd vendor/docs && "$GO_BIN" comp fish) > "$SANDBOX/init.fish" || fail "comp fish"
    cat > "$SANDBOX/gxenv_test.fish" <<EOS
source $SANDBOX/init.fish
gxenv -i
echo "in=[\$GIT_DIR][\$CROSS_ACTIVE]"
git log --oneline -1
echo "marked_prompt:"(fish_prompt)
gxenv -u
echo "out=[\$GIT_DIR]"
echo "restored_prompt:"(fish_prompt)
EOS
    out=$(cd vendor/docs && fish "$SANDBOX/gxenv_test.fish" 2>&1)
    echo "$out"
    assert_contains "$out" "in=[$GD_ABS][vendor/docs]" "fish gxenv -i must export the context"
    assert_contains "$out" "docs v2" "fish gxenv -i must let plain git see upstream"
    assert_contains "$out" "out=[]" "fish gxenv -u must unload the context"
    assert_contains "$out" "marked_prompt:" "[cross:up]" "fish gxenv -i must mark fish_prompt"
    marked=$(printf '%s\n' "$out" | grep -A1 "marked_prompt:" | tail -1)
    restored=$(printf '%s\n' "$out" | grep -A1 "restored_prompt:" | tail -1)
    case "$restored" in *"[cross:up]"*) fail "fish gxenv -u must restore fish_prompt" ;; esac
    [ -n "$marked" ] && [ -n "$restored" ] || fail "fish prompt markers must be printable"
    log_success "fish gxenv -i / -u"
    cat > "$SANDBOX/gxenv_nested.fish" <<EOS
source $SANDBOX/init.fish
gxenv
echo "parent=[\$CROSS_ACTIVE]"
EOS
    out=$(cd vendor/docs && SHELL="$SANDBOX/fake-shell.sh" fish "$SANDBOX/gxenv_nested.fish" 2>&1)
    assert_contains "$out" "nested GIT_DIR=$GD_ABS" "fish gxenv must open a nested shell with the context"
    assert_contains "$out" "parent=[]" "fish gxenv must not leak into the caller shell"
    log_success "fish gxenv nested shell"
fi

if command -v bash >/dev/null 2>&1; then
    log_header "028: gxenv nested shell marks the prompt too (bash)"
    out=$(cd vendor/docs && printf 'echo "PROMPT=[$PS1] GIT_DIR=[$GIT_DIR]"
exit
' \
        | SHELL=/bin/bash bash -c 'eval "$("$GO_BIN" comp bash)"; gxenv' 2>/dev/null)
    echo "$out"
    assert_contains "$out" "[cross:up]" "the nested shell must mark its prompt"
    assert_contains "$out" "GIT_DIR=[$GD_ABS]" "the nested shell must carry the context"
    log_success "nested prompt marker"
fi

log_header "028: quoting survives paths with spaces"
"$GO_BIN" set "up:docs" "vendor/my docs" >/dev/null 2>&1 || fail "set with a space in the local path"
out=$(cd "vendor/my docs" && eval "$("$GO_BIN" env)" && echo "GIT_WORK_TREE=$GIT_WORK_TREE" && git log --oneline -1)
echo "$out"
assert_contains "$out" "GIT_WORK_TREE=$(pwd)/vendor/my docs" "eval must handle a path with a space"
assert_contains "$out" "docs v2" "the quoted context must still work"
[ "$("$GO_BIN" env --local-path "vendor/my docs")" = "vendor/my docs" ] \
    || fail "--local-path must handle a path with a space"
log_success "shell quoting handles spaces"

echo "Test 028 passed!"
