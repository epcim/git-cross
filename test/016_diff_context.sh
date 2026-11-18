#!/usr/bin/env bash
# Test 016: context-aware diff in the v0.5.0 architecture.
#
# v0.5.0 has NO dedicated diff command: `git cross diff` is the git passthrough.
#   - inside a crossed directory (or any subdirectory of one) it is
#     `git diff` in the patch's UPSTREAM context (GIT_DIR/GIT_WORK_TREE)
#   - at the repo root it FAILS early: there is no patch context to configure
#     (ADR-002). It never silently diffs the primary repo.
#   - `git cross diff <path>` is plain `git diff <path>` on the PRIMARY repo,
#     because an explicit git pathspec is just a git argument.
source "$(dirname "$0")/common.sh"

setup_sandbox

# --- Setup upstream with two separate source trees ---
upstream_path=$(create_upstream "diff-context-upstream")
pushd "$upstream_path" >/dev/null
mkdir -p src/alpha src/beta
echo "alpha v1" > src/alpha/alpha.txt
echo "beta v1"  > src/beta/beta.txt
git add src/
git commit -m "Add alpha and beta" -q
popd >/dev/null
upstream_url="file://$upstream_path"

just cross use upstream "$upstream_url" >/dev/null
just cross set upstream:src/alpha vendor/alpha >/dev/null
just cross set upstream:src/beta  vendor/beta  >/dev/null

# Locally modify both patches (D3 nesting: tracked files live under src/<name>/)
echo "local alpha change" >> vendor/alpha/src/alpha/alpha.txt
echo "local beta change"  >> vendor/beta/src/beta/beta.txt

# --- Test 1: diff from inside patch dir shows only that patch's upstream diff ---
log_header "Test 1: diff inside a patch dir shows only that patch..."
pushd vendor/alpha >/dev/null
output=$(just cross diff 2>&1 || true)
echo "$output"
if ! echo "$output" | grep -q "local alpha change"; then
    fail "Test 1: diff inside vendor/alpha should show the alpha change"
fi
if echo "$output" | grep -q "local beta change"; then
    fail "Test 1: diff inside vendor/alpha should NOT show the beta change"
fi
popd >/dev/null
log_success "Test 1 passed: patch-context diff is scoped to the patch"

# --- Test 2: diff from a subdirectory of a patch still resolves that patch ---
log_header "Test 2: diff from a subdirectory resolves the parent patch..."
mkdir -p vendor/beta/src/beta/subdir
pushd vendor/beta/src/beta/subdir >/dev/null
output=$(just cross diff 2>&1 || true)
echo "$output"
if ! echo "$output" | grep -q "local beta change"; then
    fail "Test 2: diff from a beta subdirectory should show the beta change"
fi
if echo "$output" | grep -q "local alpha change"; then
    fail "Test 2: diff from a beta subdirectory should NOT show the alpha change"
fi
popd >/dev/null
log_success "Test 2 passed: subdirectory resolves to the parent patch"

# --- Test 3: diff . from inside a patch ---
log_header "Test 3: diff . from inside a patch..."
pushd vendor/alpha >/dev/null
output=$(just cross diff . 2>&1 || true)
echo "$output"
if ! echo "$output" | grep -q "local alpha change"; then
    fail "Test 3: diff . inside vendor/alpha should show the alpha change"
fi
popd >/dev/null
log_success "Test 3 passed: diff . works inside a patch"

# --- Test 4: repo root without a patch context → fail early (ADR-002) ---
log_header "Test 4: diff at the repo root fails early (no patch context)..."
diff_rc=0
output=$(just cross diff 2>&1) || diff_rc=$?
echo "$output"
if [ "$diff_rc" -eq 0 ]; then
    fail "Test 4: diff outside a patch dir should exit non-zero"
fi
if ! echo "$output" | grep -q "crossed directory"; then
    fail "Test 4: diff outside a patch dir should explain the missing patch context"
fi
if ! echo "$output" | grep -q "git cross cd"; then
    fail "Test 4: the hint should point at 'git cross cd'"
fi
log_success "Test 4 passed: root-level diff fails early"

# --- Test 5: a git pathspec does not create a patch context ---
log_header "Test 5: diff <pathspec> at the repo root also fails early..."
diff_rc=0
output=$(just cross diff Justfile.cross 2>&1) || diff_rc=$?
echo "$output"
if [ "$diff_rc" -eq 0 ]; then
    fail "Test 5: diff <pathspec> outside a patch dir should exit non-zero"
fi
if ! echo "$output" | grep -q "crossed directory"; then
    fail "Test 5: a pathspec must not silently turn the passthrough into a primary-repo diff"
fi
log_success "Test 5 passed: git pathspecs do not create a patch context"

# --- Go implementation: same contract ---
GO_BIN=$(ensure_go_bin "$REPO_ROOT" || true)
if [ -z "${GO_BIN:-}" ]; then
    log_warn "Go toolchain unavailable or build failed - skipping Go part"
else
    log_header "Test 6 (Go): diff inside a patch dir is patch-scoped..."
    pushd vendor/alpha >/dev/null
    output=$("$GO_BIN" diff 2>&1 || true)
    echo "$output"
    echo "$output" | grep -q "local alpha change" \
        || fail "Test 6 (Go): diff inside the patch should show the alpha change"
    if echo "$output" | grep -q "local beta change"; then
        fail "Test 6 (Go): diff inside the patch should NOT show the beta change"
    fi
    popd >/dev/null
    log_success "Test 6 passed: Go patch-context diff"

    log_header "Test 7 (Go): diff at the repo root fails early..."
    diff_rc=0
    output=$("$GO_BIN" diff 2>&1) || diff_rc=$?
    echo "$output"
    [ "$diff_rc" -ne 0 ] || fail "Test 7 (Go): diff outside a patch dir should exit non-zero"
    assert_contains "$output" "crossed directory" "Test 7 (Go): must explain the missing patch context"
    log_success "Test 7 passed: Go root-level diff fails early"

    log_header "Test 8 (Go): diff from a patch subdirectory..."
    pushd vendor/beta/src/beta/subdir >/dev/null
    output=$("$GO_BIN" diff 2>&1 || true)
    echo "$output"
    echo "$output" | grep -q "local beta change" \
        || fail "Test 8 (Go): diff from a subdirectory should show the beta change"
    popd >/dev/null
    log_success "Test 8 passed: Go subdirectory resolution"
fi

echo ""
echo "All context-aware diff tests passed!"
