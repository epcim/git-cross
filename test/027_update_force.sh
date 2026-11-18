#!/usr/bin/env bash
# Test 027: update --force / y-N re-adoption of lost crosses — BOTH implementations.
#
# v0.5.x contract (Go is primary, Just/Fish is the reference):
#   Go `update`: a crossed dir that exists but lost its .cross state (whole
#     registry gone, or only its gitdir) triggers a y/N prompt with the
#     ABSOLUTE path; default No (EOF/empty), y/Y adopts (wipe + re-set from
#     upstream); declined crosses are skipped and counted in a summary warning.
#     `--force` auto-applies the "yes" — no prompt.
#   Just/Fish `update` is NON-INTERACTIVE: it refuses and tells the user to
#     re-run with `--force`, which auto-adopts (wipe + re-set).
#   Direct `set` on an existing-but-unregistered dir refuses with a hint in
#     both implementations (never a silent overwrite).
#   Unsafe local paths (`../outside`) are a hard error in both.
#   Re-adoption guards (both implementations, `--force` included): a crossed dir
#   with staged/unstaged changes is refused and left intact, and `--force` on a
#   HEALTHY registered cross is a no-op (it never wipes it).
#   Go only: `update <path>` + a declined prompt reports the skip and exits 0.
source "$(dirname "$0")/common.sh"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO_BIN="$(ensure_go_bin "$PROJECT_ROOT")"

# Common per-implementation setup: sandbox + upstream + a registered, healthy
# cross at vendor/docs (work tree mirrors upstream root: vendor/docs/docs/...).
setup_cross() {
    local who=$1
    setup_sandbox
    cd "$SANDBOX"
    echo "upstream/" >> .gitignore

    local up
    up=$(create_upstream "u-$who")
    mkdir -p "$up/docs"
    echo "guide v1" > "$up/docs/guide.md"
    git -C "$up" add -A
    git -C "$up" commit -qm "docs v1"

    xc use up "$up" >/dev/null 2>&1 || fail "$who: use"
    xc set up:docs vendor/docs >/dev/null 2>&1 || fail "$who: set"
    assert_file_exists "vendor/docs/docs/guide.md"

    # The canonical Crossfile lines (use/set) are already in place — keep them,
    # so a re-adoption's re-append dedups instead of adding a second set line.
    git add -A && git commit -qm "vendor: initial" >/dev/null
}

# Disaster state: the whole .cross registry is gone, the crossed dir survives.
disaster_full() {
    rm -rf .cross
    [ -f vendor/docs/docs/guide.md ] || fail "crossed dir must survive the disaster"
}

# Raw ls row for vendor/docs (field 8 = SHA, field 7 = DIFF).
ls_raw_row() {
    xc ls --raw --no-header 2>/dev/null | awk -F'\t' '$3 == "vendor/docs"'
}

# --- Go ---------------------------------------------------------------------
# Full matrix: EOF -> skip+summary, y -> adopt, N -> skip, --force -> no
# prompt, gitdir-only loss, direct set refusal, unsafe path.
if [ -n "$GO_BIN" ]; then
    xc() { "$GO_BIN" "$@"; }

    log_header "027: go — EOF piped to the y/N prompt skips (default No)"
    setup_cross go
    disaster_full
    out=$("$GO_BIN" update </dev/null 2>&1)
    echo "$out"
    assert_contains "$out" "Delete '$(pwd)/vendor/docs' and re-adopt it from upstream? [y/N]:" \
        "go: the prompt must show the absolute path"
    assert_contains "$out" "Skipped vendor/docs (not confirmed; re-run with --force to adopt without asking)" \
        "go: a declined cross must be skipped with a warning"
    assert_contains "$out" "1 cross(es) not adopted: not confirmed (use --force to adopt without asking)." \
        "go: the declined summary must be printed"
    assert_file_exists "vendor/docs/docs/guide.md"
    log_success "EOF skips, dir intact"

    log_header "027: go — piped N skips like EOF"
    out=$(printf 'N\n' | "$GO_BIN" update 2>&1)
    assert_contains "$out" "1 cross(es) not adopted" "go: N must skip like EOF"
    assert_file_exists "vendor/docs/docs/guide.md"
    log_success "N skips"

    log_header "027: go — piped y adopts the cross from upstream"
    out=$(printf 'y\n' | "$GO_BIN" update 2>&1)
    echo "$out"
    assert_contains "$out" "Re-adopting vendor/docs from upstream (existing dir wiped)" \
        "go: adoption must be announced"
    assert_file_exists "vendor/docs/docs/guide.md"
    registered=$(jq -r '.patches[] | select(.local_path == "vendor/docs") | .gitdir' .cross/metadata.json)
    [ -n "$registered" ] || fail "go: adopted cross must be registered in metadata"
    row=$(ls_raw_row)
    [ -n "$row" ] || fail "go: ls --raw must list the adopted cross"
    assert_contains "$row" "Clean" "go: the re-adopted cross must be Clean"
    sha=$(printf '%s' "$row" | awk -F'\t' '{print $8}')
    [ -n "$sha" ] && [ "$sha" != "-" ] || fail "go: the re-adopted cross must have an upstream SHA"
    log_success "y adopts: dir restored, registered, Clean + SHA"

    log_header "027: go — --force adopts without prompting"
    disaster_full
    out=$("$GO_BIN" update --force </dev/null 2>&1)
    echo "$out"
    assert_not_contains "$out" "Delete '" "go: --force must not prompt"
    assert_contains "$out" "Re-adopting vendor/docs from upstream (existing dir wiped)" \
        "go: --force must adopt"
    assert_file_exists "vendor/docs/docs/guide.md"
    [ -n "$(ls_raw_row)" ] || fail "go: --force adoption must register the cross"
    log_success "--force adopts, no prompt"

    log_header "027: go — gitdir-only loss prompts and --force re-adopts"
    rm -rf .cross/worktrees/up/vendor_docs
    out=$("$GO_BIN" update </dev/null 2>&1)
    assert_contains "$out" "Delete '$(pwd)/vendor/docs' and re-adopt it from upstream? [y/N]:" \
        "go: a lost gitdir must trigger the same prompt"
    assert_contains "$out" "1 cross(es) not adopted" "go: gitdir-only loss must be skippable"
    assert_file_exists "vendor/docs/docs/guide.md"
    out=$("$GO_BIN" update --force </dev/null 2>&1)
    assert_contains "$out" "Re-adopting vendor/docs from upstream (existing dir wiped)" \
        "go: --force must re-adopt after gitdir loss"
    assert_file_exists "vendor/docs/docs/guide.md"
    [ -n "$(ls_raw_row)" ] || fail "go: re-adoption after gitdir loss must register the cross"
    log_success "gitdir-only loss handled"

    log_header "027: go — --force leaves a healthy registered cross alone"
    setup_cross go
    gitdir_before=$(jq -r '.patches[] | select(.local_path == "vendor/docs") | .gitdir' .cross/metadata.json)
    sha_before=$(ls_raw_row | awk -F'\t' '{print $8}')
    echo "local only" > vendor/docs/docs/local-only.md
    git add vendor/docs/docs/local-only.md >/dev/null
    git commit -qm "local: keep me" >/dev/null
    out=$("$GO_BIN" update --force </dev/null 2>&1)
    rc=$?
    echo "$out"
    [ "$rc" -eq 0 ] || fail "go: --force on a healthy cross must succeed"
    assert_not_contains "$out" "Re-adopting" "go: --force must never wipe a registered cross"
    assert_not_contains "$out" "Delete '" "go: --force on a healthy cross must not prompt"
    assert_file_exists "vendor/docs/docs/local-only.md"
    [ "$(jq -r '.patches[] | select(.local_path == "vendor/docs") | .gitdir' .cross/metadata.json)" = "$gitdir_before" ] \
        || fail "go: --force must not re-clone a healthy cross"
    [ "$(ls_raw_row | awk -F'\t' '{print $8}')" = "$sha_before" ] \
        || fail "go: --force must not move a healthy cross's mirror"
    log_success "--force is a no-op on a healthy cross"

    log_header "027: go — --force refuses a dirty lost-state dir (no data loss)"
    setup_cross go
    disaster_full
    echo "uncommitted work" > vendor/docs/docs/wip.md
    out=$("$GO_BIN" update --force </dev/null 2>&1)
    rc=$?
    echo "$out"
    [ "$rc" -ne 0 ] || fail "go: --force must refuse a dirty lost-state dir"
    assert_contains "$out" \
        "vendor/docs has uncommitted changes; commit or stash them first (refusing to delete them)" \
        "go: the dirty refusal must explain why"
    assert_not_contains "$out" "Re-adopting" "go: a refused re-adoption must not wipe"
    assert_not_contains "$out" "Delete '" "go: --force must not prompt"
    assert_file_exists "vendor/docs/docs/wip.md"
    assert_file_exists "vendor/docs/docs/guide.md"
    log_success "dirty lost-state refused, content intact"

    log_header "027: go — a modified tracked file also blocks re-adoption"
    echo "edited" >> vendor/docs/docs/guide.md
    out=$("$GO_BIN" update --force </dev/null 2>&1)
    rc=$?
    echo "$out"
    [ "$rc" -ne 0 ] || fail "go: a modified tracked file must block the wipe"
    assert_contains "$out" "vendor/docs has uncommitted changes"
    assert_contains "$(cat vendor/docs/docs/guide.md)" "edited" "go: the modified file must survive"
    log_success "modified file refused, edit intact"

    log_header "027: go — update <path> + declined prompt is a skip, not a missing cross"
    setup_cross go
    disaster_full
    out=$("$GO_BIN" update vendor/docs </dev/null 2>&1)
    rc=$?
    echo "$out"
    [ "$rc" -eq 0 ] || fail "go: a declined single-path update must exit 0"
    assert_contains "$out" "1 cross(es) not adopted" "go: the declined summary must be printed"
    assert_not_contains "$out" "no Crossfile cross found for path" "go: vendor/docs IS in the Crossfile"
    assert_file_exists "vendor/docs/docs/guide.md"
    out=$("$GO_BIN" update nope/missing </dev/null 2>&1)
    rc=$?
    echo "$out"
    [ "$rc" -ne 0 ] || fail "go: a path absent from the Crossfile is still a hard error"
    assert_contains "$out" "no Crossfile cross found for path: nope/missing" \
        "go: a genuinely missing path keeps the hard error"
    log_success "decline is a skip; missing path still errors"

    log_header "027: go — direct set on an existing unregistered dir refuses"
    setup_cross go
    disaster_full
    "$GO_BIN" update </dev/null >/dev/null 2>&1   # use line re-registers the remote
    out=$("$GO_BIN" set up:docs vendor/docs 2>&1)
    rc=$?
    echo "$out"
    [ "$rc" -ne 0 ] || fail "go: direct set must refuse"
    assert_contains "$out" "refusing to overwrite it" "go: refusal message"
    assert_contains "$out" "add it to Crossfile and run: git cross update --force — or remove the directory" \
        "go: refusal must hint at the Crossfile + update --force remedy"
    assert_file_exists "vendor/docs/docs/guide.md"
    log_success "direct set refuses with a hint"

    log_header "027: go — unsafe local path is a hard error"
    printf 'cross set up:docs ../outside\n' > Crossfile
    out=$("$GO_BIN" update --force </dev/null 2>&1)
    rc=$?
    echo "$out"
    [ "$rc" -ne 0 ] || fail "go: unsafe path must be a hard error"
    assert_contains "$out" "Unsafe local path, refusing to touch it: ../outside" \
        "go: unsafe path refusal message"
    [ ! -e "$SANDBOX/../outside" ] || fail "go: nothing outside the repo may be touched"
    log_success "unsafe path refused"
else
    echo "SKIP: Go CLI unavailable"
fi

# --- Just/Fish --------------------------------------------------------------
# Non-interactive reference: refuse + hint without --force, auto-adopt with.
# v0.5.1: update is Go-only in the Just reference (stub) — this section is
# entirely update-driven, so skip the whole variant when stubbed.
if command -v fish >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v just >/dev/null 2>&1 && just_ref_implements update; then
    xc() { just cross "$@"; }

    log_header "027: just — plain update on an unregistered dir refuses (non-interactive)"
    setup_cross just
    disaster_full
    out=$(just cross update 2>&1)
    rc=$?
    echo "$out"
    [ "$rc" -ne 0 ] || fail "just: plain update must refuse an unregistered dir"
    assert_contains "$out" \
        "vendor/docs exists but is not registered; refusing to overwrite it (use: git cross update --force)" \
        "just: refusal must hint at --force"
    assert_file_exists "vendor/docs/docs/guide.md"
    log_success "plain update refuses, dir intact"

    log_header "027: just — update --force auto-adopts without prompting"
    out=$(just cross update --force </dev/null 2>&1)
    rc=$?
    echo "$out"
    [ "$rc" -eq 0 ] || fail "just: --force must succeed"
    assert_not_contains "$out" "Delete '" "just: the reference must never prompt"
    assert_contains "$out" "Re-adopting vendor/docs from upstream (existing dir wiped)" \
        "just: --force adoption must be announced"
    assert_file_exists "vendor/docs/docs/guide.md"
    row=$(ls_raw_row)
    [ -n "$row" ] || fail "just: --force adoption must register the cross"
    assert_contains "$row" "Clean" "just: the re-adopted cross must be Clean"
    sha=$(printf '%s' "$row" | awk -F'\t' '{print $8}')
    [ -n "$sha" ] && [ "$sha" != "-" ] || fail "just: the re-adopted cross must have an upstream SHA"
    log_success "--force adopts: dir restored, registered, Clean + SHA"

    log_header "027: just — gitdir-only loss refuses without --force"
    rm -rf .cross/worktrees/up/vendor_docs
    out=$(just cross update 2>&1)
    rc=$?
    echo "$out"
    [ "$rc" -ne 0 ] || fail "just: gitdir-only loss must refuse without --force"
    assert_contains "$out" "Gitdir missing for vendor/docs" "just: gitdir-loss refusal message"
    assert_contains "$out" "update --force" "just: gitdir-loss refusal must hint at --force"
    assert_file_exists "vendor/docs/docs/guide.md"
    log_success "gitdir-only loss refuses, dir intact"

    log_header "027: just — --force leaves a healthy registered cross alone"
    setup_cross just
    gitdir_before=$(jq -r '.patches[] | select(.local_path == "vendor/docs") | .gitdir' .cross/metadata.json)
    sha_before=$(ls_raw_row | awk -F'\t' '{print $8}')
    echo "local only" > vendor/docs/docs/local-only.md
    git add vendor/docs/docs/local-only.md >/dev/null
    git commit -qm "local: keep me" >/dev/null
    out=$(just cross update --force </dev/null 2>&1)
    rc=$?
    echo "$out"
    [ "$rc" -eq 0 ] || fail "just: --force on a healthy cross must succeed"
    assert_not_contains "$out" "Re-adopting" "just: --force must never wipe a registered cross"
    assert_file_exists "vendor/docs/docs/local-only.md"
    [ "$(jq -r '.patches[] | select(.local_path == "vendor/docs") | .gitdir' .cross/metadata.json)" = "$gitdir_before" ] \
        || fail "just: --force must not re-clone a healthy cross"
    [ "$(ls_raw_row | awk -F'\t' '{print $8}')" = "$sha_before" ] \
        || fail "just: --force must not move a healthy cross's mirror"
    log_success "--force is a no-op on a healthy cross"

    log_header "027: just — --force refuses a dirty lost-state dir (no data loss)"
    setup_cross just
    disaster_full
    echo "uncommitted work" > vendor/docs/docs/wip.md
    out=$(just cross update --force </dev/null 2>&1)
    rc=$?
    echo "$out"
    [ "$rc" -ne 0 ] || fail "just: --force must refuse a dirty lost-state dir"
    assert_contains "$out" \
        "vendor/docs has uncommitted changes; commit or stash them first (refusing to delete them)" \
        "just: the dirty refusal must explain why"
    assert_not_contains "$out" "Re-adopting" "just: a refused re-adoption must not wipe"
    assert_file_exists "vendor/docs/docs/wip.md"
    assert_file_exists "vendor/docs/docs/guide.md"
    log_success "dirty lost-state refused, content intact"

    log_header "027: just — direct set on an existing unregistered dir refuses"
    setup_cross just
    disaster_full
    just cross update >/dev/null 2>&1   # use line re-registers the remote, update refuses
    out=$(just cross set up:docs vendor/docs 2>&1)
    rc=$?
    echo "$out"
    [ "$rc" -ne 0 ] || fail "just: direct set must refuse"
    assert_contains "$out" "refusing to overwrite it" "just: refusal message"
    assert_contains "$out" "add it to Crossfile and run: git cross update --force — or remove the directory" \
        "just: refusal must hint at the Crossfile + update --force remedy"
    assert_file_exists "vendor/docs/docs/guide.md"
    log_success "direct set refuses with a hint"
else
    echo "SKIP: fish/jq/just unavailable — or update is Go-only (NOT IMPLEMENTED in the Just reference, v0.5.1); skipping the Just/Fish variant"
fi

echo "Test 027 passed!"
