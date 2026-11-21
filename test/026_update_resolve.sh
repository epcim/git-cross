#!/usr/bin/env bash
# Test 026: update/resolve conflict lifecycle (ADR-003) — BOTH implementations.
#
# This is the integration counterpart of src-go/update_resolve_test.go: the same
# scenario runs twice, once through the Go CLI and once through Justfile.cross,
# so a divergence between the two implementations fails here.
#
# Contract under test:
#   update   fetch every patch first, then per patch land upstream in the patch
#            dir and re-apply the user's version on top
#   unstaged local edits -> refuse ("commit them in your repo first")
#   collision            -> KEPT: unmerged paths + markers (never an overwrite)
#   resolve --abort      -> patch dir back to HEAD, fetch kept
#   resolve --continue   -> requires no unmerged paths, mirror follows
#   update --no-resolve  -> land upstream as-is (upstream wins, no markers)
source "$(dirname "$0")/common.sh"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO_BIN="$(ensure_go_bin "$PROJECT_ROOT")"

exercise() {
    local who=$1
    log_header "026: $who — clean landing re-applies committed local changes"
    setup_sandbox
    cd "$SANDBOX"
    echo "upstream/" >> .gitignore

    local up
    up=$(create_upstream "u-$who")
    mkdir -p "$up/src/lib"
    echo "NAME: AAA" > "$up/src/lib/c.yaml"
    echo "keep me" > "$up/src/lib/local.txt"
    git -C "$up" add -A
    git -C "$up" commit -qm v1

    xc cfg >/dev/null 2>&1 || true
    xc use up "$up" >/dev/null 2>&1 || fail "$who: use"
    xc set up:src/lib lib >/dev/null 2>&1 || fail "$who: patch"
    git add -A && git commit -qm "vendor: initial" >/dev/null

    local gd
    gd="$SANDBOX/$(jq -r '.patches[] | select(.local_path == "lib") | .gitdir' .cross/metadata.json)"
    [ -d "$gd" ] || fail "$who: mirror not created"

    # --- clean landing -----------------------------------------------------
    echo "user edit" >> lib/local.txt
    git add lib && git commit -qm "vendor: local edit" >/dev/null
    echo "new upstream" > "$up/src/lib/new.txt"
    git -C "$up" add -A && git -C "$up" commit -qm v2

    local out
    out=$(xc update 2>&1) || true
    echo "$out"
    assert_contains "$out" "Updated lib" "$who: clean update should land"
    assert_grep "lib/new.txt" "new upstream"
    assert_grep "lib/local.txt" "user edit"
    [ -z "$(git ls-files -u)" ] || fail "$who: clean landing must not leave unmerged paths"
    # v0.6: mirror HEAD is a synthesized subtree branch — compare TREES, not commits
    [ "$(git --git-dir="$gd" rev-parse 'refs/heads/main^{tree}')" = "$(git --git-dir="$gd" rev-parse refs/remotes/origin/main:src/lib)" ] \
        || fail "$who: mirror should follow the landed revision"
    git add lib && git commit -qm "vendor: upstream sync" >/dev/null
    out=$(xc update 2>&1) || true
    assert_contains "$out" "already up to date" "$who: second update must be a no-op"

    # --- unstaged edits are refused ---------------------------------------
    log_header "026: $who — unstaged local edits refuse the update"
    local up_before
    up_before=$(git -C "$up" rev-parse HEAD)
    echo "local only" >> lib/local.txt          # unstaged on purpose
    echo "upstream v2" >> "$up/src/lib/local.txt"
    git -C "$up" commit -qam v3
    out=$(xc update 2>&1) || true
    echo "$out"
    assert_contains "$out" "has modified files; commit them in your repo first" \
        "$who: update must ask for a commit"
    assert_grep "lib/local.txt" "local only"
    assert_contains "$(git --git-dir="$gd" show 'refs/remotes/origin/main:src/lib/local.txt')" "upstream v2" \
        "$who: fetch must still have happened"
    # Undo both sides so the file is identical again for the next phase.
    git checkout -- lib/local.txt 2>/dev/null || true
    git -C "$up" reset -q --hard "$up_before"

    # --- untracked collisions refuse early (0.6.1) -------------------------
    # A file the delta would write sitting UNTRACKED in the crossed dir used to
    # surface as a raw "would be overwritten by merge" cherry-pick error; the
    # gate now refuses it BEFORE any work with guidance. Purely local untracked
    # files stay allowed (patchWorktreeDirty contract).
    log_header "026: $who — untracked delta collisions refuse the update early"
    git rm -q --cached lib/local.txt >/dev/null 2>&1
    git commit -qm "vendor: untrack local.txt" >/dev/null
    echo "upstream v5" >> "$up/src/lib/local.txt"
    git -C "$up" commit -qam v5
    out=$(xc update 2>&1) || true
    echo "$out"
    assert_contains "$out" "untracked files would be overwritten by the update" \
        "$who: the early refusal must name the problem"
    assert_contains "$out" "lib/local.txt" \
        "$who: the colliding untracked file must be listed"
    assert_contains "$out" "commit or stage them first" \
        "$who: the refusal must hint at the remedy"
    assert_contains "$out" "1 cross(es) skipped" "$who: counts as skipped, not failed"
    [ -z "$(git ls-files -u)" ] || fail "$who: refusal must not leave unmerged paths"
    assert_grep "lib/local.txt" "keep me" "$who: the untracked file is untouched"
    # restore: re-track the file so later phases start clean
    git add lib/local.txt && git commit -qm "vendor: re-track local.txt" >/dev/null
    git -C "$up" reset -q --hard "$up_before"
    out=$(xc update 2>&1) || true
    assert_contains "$out" "already up to date" \
        "$who: the untracked refusal is gone once the file is tracked (upstream rewound to the landed state)"

    # --- conflict is kept (never overwritten) ------------------------------
    log_header "026: $who — a collision is kept as a conflict"
    echo "NAME: BBB" > lib/c.yaml
    git add lib && git commit -qm "vendor: BBB" >/dev/null
    echo "NAME: CCC" > "$up/src/lib/c.yaml"
    git -C "$up" commit -qam v4

    out=$(xc update 2>&1) || true
    echo "$out"
    assert_contains "$out" "conflict in 'lib'" "$who: update must keep the conflict"
    assert_contains "$out" "git cross resolve" "$who: output should point at resolve"
    [ -n "$(git ls-files -u)" ] || fail "$who: conflict must surface as unmerged paths"
    assert_grep "lib/c.yaml" "<<<<<<<"

    out=$(xc update 2>&1) || true
    assert_contains "$out" "pending conflict" "$who: a pending conflict must not be reset over"
    [ -n "$(git ls-files -u)" ] || fail "$who: pending state must survive a second update"

    # --- resolve --abort ---------------------------------------------------
    log_header "026: $who — resolve --abort restores the user's version"
    out=$(xc resolve --abort 2>&1) || fail "$who: resolve --abort"
    [ -z "$(git ls-files -u)" ] || fail "$who: --abort must clear unmerged paths"
    assert_grep "lib/c.yaml" "NAME: BBB"
    [ "$(git --git-dir="$gd" rev-parse 'refs/heads/main^{tree}')" != "$(git --git-dir="$gd" rev-parse refs/remotes/origin/main:src/lib)" ] \
        || fail "$who: --abort must not advance the mirror"

    # --- resolve --continue ------------------------------------------------
    log_header "026: $who — resolve --continue finishes it and lets the mirror follow"
    out=$(xc update 2>&1) || true
    assert_contains "$out" "conflict in 'lib'" "$who: conflict should reappear"
    printf 'NAME: BBB\nNAME: CCC\n' > lib/c.yaml
    git add lib/c.yaml
    out=$(xc resolve --continue 2>&1) || fail "$who: resolve --continue"
    echo "$out"
    assert_contains "$out" "is clean" "$who: --continue should confirm cleanliness"
    [ "$(git --git-dir="$gd" rev-parse 'refs/heads/main^{tree}')" = "$(git --git-dir="$gd" rev-parse refs/remotes/origin/main:src/lib)" ] \
        || fail "$who: --continue must let the mirror follow"
    git commit -qm "vendor: resolved" >/dev/null

    # rerere lives in the USER's repo, not the mirror
    [ -d "$SANDBOX/.git/rr-cache" ] || fail "$who: rerere should record in <repo>/.git/rr-cache"
    [ ! -d "$gd/rr-cache" ] || true   # the mirror may hold its own cache; not required

    # --- --no-resolve ------------------------------------------------------
    log_header "026: $who — update --no-resolve lands upstream as-is"
    echo "NAME: DDD" > "$up/src/lib/c.yaml"
    git -C "$up" commit -qam v5
    out=$(xc update --no-resolve 2>&1) || true
    echo "$out"
    assert_contains "$out" "Updated lib" "$who: --no-resolve should land"
    assert_grep "lib/c.yaml" "NAME: DDD"
    [ -z "$(git ls-files -u)" ] || fail "$who: --no-resolve must not leave unmerged paths"

    # --- whole-repo cross: untracked collisions refuse early (0.6.1) --------
    # The user-reported failure shape: a WHOLE-REPO cross (remote_path "."),
    # its content untracked in the repo (git rm --cached), an upstream change
    # touching the same file. v0.6.0 let this surface as a RAW
    # "untracked working tree files would be overwritten by merge"
    # cherry-pick error; the gate must refuse it early here too — the
    # delta-path handling without a subdir (no prefix to strip) is the variant.
    log_header "026: $who — whole-repo cross: untracked delta collisions refuse early"
    xc set up:main:. lib-all >/dev/null 2>&1 || fail "$who: whole-repo set"
    git add -A && git commit -qm "vendor: lib-all initial" >/dev/null
    # The upstream change targets the upstream ROOT (README.md) so ONLY the
    # whole-repo cross sees the delta — the subdir cross `lib` stays quiet.
    git rm -q --cached lib-all/README.md >/dev/null 2>&1
    git commit -qm "vendor: untrack whole-repo README" >/dev/null
    echo "upstream v6" >> "$up/README.md"
    git -C "$up" commit -qam v6
    out=$(xc update 2>&1) || true
    echo "$out"
    assert_contains "$out" "untracked files would be overwritten by the update" \
        "$who: whole-repo refusal must name the problem"
    assert_contains "$out" "lib-all/README.md" \
        "$who: the colliding whole-repo file must be listed"
    assert_contains "$out" "commit or stage them first" \
        "$who: the whole-repo refusal must hint at the remedy"
    assert_contains "$out" "1 cross(es) skipped" \
        "$who: whole-repo refusal counts as skipped, not a raw cherry-pick error"
    assert_contains "$out" "git-cross 0.6.1" \
        "$who: a skipped cross prints the binary version once (stale-binary self-diagnosis)"
    [ -z "$(git ls-files -u)" ] || fail "$who: whole-repo refusal must not leave unmerged paths"
    grep -q "upstream v6" lib-all/README.md && fail "$who: the untracked whole-repo file is untouched"
    # recovery: re-track the file, then the whole-repo cross lands cleanly
    git add lib-all/README.md && git commit -qm "vendor: re-track whole-repo README" >/dev/null
    out=$(xc update 2>&1) || true
    echo "$out"
    assert_contains "$out" "Updated lib-all" "$who: re-tracked whole-repo cross must update"
    assert_grep "lib-all/README.md" "upstream v6" \
        "$who: the recovered whole-repo cross carries the upstream change"

    # --- untracked gate is immune to status.showUntrackedFiles=no ---------
    # `git status` honors status.showUntrackedFiles=no and lists NOTHING —
    # a status-based gate goes silently blind while git's cherry-pick still
    # refuses (user-reported on 0.6.1). The gate lists untracked files with
    # `git ls-files -o --exclude-standard`, which ignores that config.
    # (c.yaml, not local.txt: its committed content equals the mirror base,
    # so the recovery after re-tracking lands cleanly instead of conflicting
    # with the local edit local.txt carries from the earlier sections.)
    log_header "026: $who — untracked gate survives status.showUntrackedFiles=no"
    git rm -q --cached lib/c.yaml >/dev/null 2>&1
    git commit -qm "vendor: untrack c.yaml" >/dev/null
    git config status.showUntrackedFiles no
    [ -z "$(git status --porcelain -- lib | grep '^??' || true)" ] \
        || fail "$who: fixture error: status must show no ?? under the config"
    echo "NAME: EEE" > "$up/src/lib/c.yaml"
    git -C "$up" commit -qam v7
    out=$(xc update 2>&1) || true
    echo "$out"
    assert_contains "$out" "untracked files would be overwritten by the update" \
        "$who: the gate must see untracked files even when status hides them"
    assert_contains "$out" "lib/c.yaml" \
        "$who: the ls-files listing names the file directly (no dir collapse)"
    assert_contains "$out" "1 cross(es) skipped" \
        "$who: config-blind state must refuse, not raw-error"
    assert_grep "lib/c.yaml" "NAME: DDD" "$who: the untracked file stays untouched"
    # restore: re-track, drop the config, land the pending upstream change
    git config status.showUntrackedFiles normal
    git add lib/c.yaml && git commit -qm "vendor: re-track c.yaml" >/dev/null
    out=$(xc update 2>&1) || true
    assert_contains "$out" "Updated lib" "$who: after re-tracking the cross must land"
    assert_grep "lib/c.yaml" "NAME: EEE" \
        "$who: the recovered cross carries the upstream change"

    # --- resolve with no path is an informational listing (0.6.1) ----------
    # User-reported: update's own hint says `git cross resolve  # list
    # leftovers`, but at the repo root with several crosses it printed the
    # rows and then failed with a bare `Error: cross not found`. No-args
    # resolve must LIST pending state (exit 0, like git status); only the
    # mutating --continue/--abort are ambiguous without a context.
    git add -A && git commit -qm "vendor: healed cross" >/dev/null
    log_header "026: $who — no-args resolve lists pending state (no cobra error)"
    out=$(xc resolve 2>&1)
    rc=$?
    echo "$out"
    [ "$rc" -eq 0 ] || fail "$who: no-args resolve must exit 0 (listing)"
    assert_contains "$out" "No pending conflicts." "$who: clean repo must list no pending conflicts"
    case "$out" in
        *"cross not found"*) fail "$who: the listing must not carry a cobra error" ;;
    esac

    # A real pending conflict: no-args resolve at the root names the cross.
    echo "NAME: FFF" > lib/c.yaml
    git add lib && git commit -qm "vendor: FFF" >/dev/null
    echo "NAME: GGG" > "$up/src/lib/c.yaml"
    git -C "$up" commit -qam v8
    xc update >/dev/null 2>&1 || true
    out=$(xc resolve 2>&1)
    rc=$?
    echo "$out"
    [ "$rc" -eq 0 ] || fail "$who: no-args resolve with pending state must still exit 0"
    assert_contains "$out" "Crosses with unresolved conflicts:" \
        "$who: the listing must name the pending section"
    assert_contains "$out" "lib: " "$who: the conflicted cross must be named"
    assert_contains "$out" "run: git cross resolve <local_path>" \
        "$who: the listing must say how to act on it"
    case "$out" in
        *"cross not found"*) fail "$who: pending listing must not carry a cobra error" ;;
    esac

    # Mutating flags without a context stay errors — but clean ones: rows go to
    # stderr, exit 1, and never the obsolete `Error: cross not found` line
    # (the crosses WERE found; the request is just ambiguous).
    out=$(xc resolve --continue 2>&1)
    rc=$?
    echo "$out"
    [ "$rc" -ne 0 ] || fail "$who: ambiguous --continue must fail"
    assert_contains "$out" "run: git cross resolve --continue <local_path>" \
        "$who: ambiguous --continue must say how to disambiguate"
    case "$out" in
        *"cross not found"*) fail "$who: ambiguous --continue must not say 'cross not found'" ;;
    esac
    xc resolve --abort >/dev/null 2>&1 || true
    assert_grep "lib/c.yaml" "NAME: FFF" "$who: --abort restored the user's version"
}

# --- Go ---------------------------------------------------------------------
if [ -n "$GO_BIN" ]; then
    xc() { "$GO_BIN" "$@"; }
    exercise go
else
    echo "SKIP: Go CLI unavailable"
fi

# --- Go: submodule recursion during the objects import ----------------------
# User-reported (gitops-infra): a repo MIGRATED from a `just` submodule to a
# `just` cross still carries `.gitmodules` + `submodule.just.url`. `git fetch`
# defaults to --recurse-submodules=on-demand, so importing the mirror's objects
# tried to fetch the recorded submodule commit from that stale URL, failed
# ("fatal: ... not our ref" / "Errors during submodule fetch: just"), and made
# the whole import exit 1 — "cannot import upstream objects from the mirror"
# with the cross skipped while a plain fetch would have transferred everything.
# The import must never recurse: git-cross moves object graphs, not submodules.
if [ -n "$GO_BIN" ]; then
    log_header "026: go — object import never recurses into submodules"

    setup_sandbox
    cd "$SANDBOX"
    # The fixture repos are raw `git init`s (create_upstream sets identity per
    # repo; these are foreign/upstream repos), so give this section an identity.
    export GIT_AUTHOR_NAME="026 Sub" GIT_AUTHOR_EMAIL="026@example.com"
    export GIT_COMMITTER_NAME="026 Sub" GIT_COMMITTER_EMAIL="026@example.com"
    git config fetch.recurseSubmodules true     # the user's global-style setting
    echo "upstream/" >> .gitignore               # the fixture upstreams live here (harness convention)
    local_up="$SANDBOX/upstream"
    mkdir -p "$local_up"

    git init -q -b main "$local_up/sub"
    ( cd "$local_up/sub"; echo one > f.txt; git add -A; git commit -qm c1 )
    git init -q -b main "$local_up/other"       # unrelated: the recorded commit is "not our ref"
    ( cd "$local_up/other"; echo other > f.txt; git add -A; git commit -qm c1 )

    # The superproject upstream: has a submodule at path `just`.
    git init -q -b main "$local_up/super"
    ( cd "$local_up/super"
      git -c protocol.file.allow=always submodule add -q "file://$local_up/sub" just
      git commit -qm "add gitlink just"
      echo v1 > top.txt; git add -A; git commit -qm v1 )

    "$GO_BIN" cfg >/dev/null 2>&1 || true
    "$GO_BIN" use sup "file://$local_up/super" >/dev/null || fail "026-sub: use failed"
    "$GO_BIN" set sup:main:. keep >/dev/null || fail "026-sub: set failed"
    git add -A && git commit -qm "vendor: initial" >/dev/null

    # The migration shape: the repo itself had `just` as a submodule. Its
    # mapping (pointing at an unrelated repo) and its module clone survive.
    cp "$local_up/super/.gitmodules" .gitmodules
    git config submodule.just.url "file://$local_up/other"
    sha=$(git -C "$local_up/super" ls-tree HEAD just | awk '{print $3}')
    git update-index --add --cacheinfo 160000,$sha,just
    git commit -qm "gitlink just (pre-migration shape)" >/dev/null
    git -c protocol.file.allow=always submodule update --init just >/dev/null 2>&1 || true
    [ -d .git/modules/just ] || fail "026-sub: fixture did not leave a submodule module dir"

    # Upstream advances AND bumps the submodule pointer to a commit that does
    # not exist locally: exactly the condition that made on-demand recursion fire.
    ( cd "$local_up/sub"; echo two > f.txt; git commit -qam c2 )
    ( cd "$local_up/super"
      git -C just fetch -q origin
      git -C just checkout -q origin/main
      git add just
      echo v2 > top.txt
      git add top.txt
      git commit -qm "bump submodule + v2" )

    out=$("$GO_BIN" update 2>&1)
    rc=$?
    echo "$out"
    [ "$rc" -eq 0 ] || fail "026-sub: update must exit 0"
    assert_contains "$out" "Updated keep" "026-sub: the cross must land despite the stale submodule mapping"
    case "$out" in
        *"submodule"*) fail "026-sub: the import must not try to fetch submodules" ;;
        *"cannot import upstream objects"*) fail "026-sub: the import must not fail on submodules" ;;
    esac
    assert_grep "keep/top.txt" "v2" "026-sub: upstream content must have landed"
else
    echo "SKIP: Go CLI unavailable"
fi

# --- Just/Fish --------------------------------------------------------------
# v0.5.1: update/resolve are Go-only in the Just reference (stubs) — this test
# is entirely update/resolve-driven, so skip the whole variant when stubbed.
if command -v fish >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v just >/dev/null 2>&1 && just_ref_implements update; then
    xc() { just cross "$@"; }
    exercise just
else
    echo "SKIP: fish/jq/just unavailable — or update is Go-only (NOT IMPLEMENTED in the Just reference, v0.5.1); skipping the Just/Fish variant"
fi

echo "Test 026 passed!"
