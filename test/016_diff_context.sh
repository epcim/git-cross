#!/usr/bin/env bash
# Test 016: Context-aware cross diff
# Verifies that `diff` without a path argument auto-detects the current patch
# from CWD (when inside a patched directory), and shows all patches otherwise.
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

just cross use upstream "$upstream_url"
just cross patch upstream:src/alpha vendor/alpha
just cross patch upstream:src/beta  vendor/beta

# Locally modify both patches
echo "local alpha change" >> vendor/alpha/alpha.txt
echo "local beta change"  >> vendor/beta/beta.txt

# --- Test 1: diff with explicit path → shows only that patch ---
log_header "Test 1: diff with explicit path shows only that patch..."
output=$(just cross diff vendor/alpha 2>&1 || true)
echo "$output"
if ! echo "$output" | grep -q "alpha"; then
    fail "Test 1: diff vendor/alpha should show alpha diff"
fi
if echo "$output" | grep -q "beta"; then
    fail "Test 1: diff vendor/alpha should NOT show beta diff"
fi
log_success "Test 1 passed: explicit path filters correctly"

# --- Test 2: diff from inside patch dir (no arg) → auto-detects patch ---
log_header "Test 2: diff from inside patch dir auto-detects patch..."
pushd vendor/alpha >/dev/null
output=$(just cross diff 2>&1 || true)
echo "$output"
if ! echo "$output" | grep -q "alpha"; then
    fail "Test 2: diff from vendor/alpha should show alpha diff"
fi
if echo "$output" | grep -q "beta"; then
    fail "Test 2: diff from inside vendor/alpha should NOT show beta diff"
fi
popd >/dev/null
log_success "Test 2 passed: auto-detected patch from CWD"

# --- Test 3: diff from subdirectory inside patch → still auto-detects ---
log_header "Test 3: diff from subdirectory inside patch auto-detects..."
mkdir -p vendor/beta/subdir
pushd vendor/beta/subdir >/dev/null
output=$(just cross diff 2>&1 || true)
echo "$output"
if ! echo "$output" | grep -q "beta"; then
    fail "Test 3: diff from vendor/beta/subdir should show beta diff"
fi
if echo "$output" | grep -q "alpha"; then
    fail "Test 3: diff from inside vendor/beta should NOT show alpha diff"
fi
popd >/dev/null
log_success "Test 3 passed: subdirectory resolves to parent patch"

# --- Test 4: diff with explicit '.' from inside patch ---
log_header "Test 4: diff with '.' from inside patch..."
pushd vendor/alpha >/dev/null
output=$(just cross diff . 2>&1 || true)
echo "$output"
if ! echo "$output" | grep -q "alpha"; then
    fail "Test 4: diff . from vendor/alpha should show alpha diff"
fi
popd >/dev/null
log_success "Test 4 passed: diff . works from inside patch"

# --- Go implementation tests (when binary is available) ---
GO_BIN="$REPO_ROOT/src-go/git-cross-go"
if [ ! -f "$GO_BIN" ]; then
    (cd "$REPO_ROOT/src-go" && CGO_ENABLED=0 go build -o git-cross-go main.go 2>/dev/null)
fi
_go_ok=false
_smoke_dir=$(mktemp -d)
git init -q "$_smoke_dir"
"$GO_BIN" use _smoke file:///dev/null >/dev/null 2>&1 && _go_ok=true
if [ "$_go_ok" = false ]; then
    log_warn "Go binary not working on this platform, skipping Go-specific diff context tests"
else
    log_header "Test 5 (Go): diff from repo root shows all patches..."
    output=$("$GO_BIN" diff 2>&1 || true)
    echo "$output"
    if ! echo "$output" | grep -q "alpha" || ! echo "$output" | grep -q "beta"; then
        fail "Test 5 (Go): diff from repo root should include both patches"
    fi
    log_success "Test 5 passed: Go diff from repo root shows all patches"

    log_header "Test 6 (Go): diff from inside patch auto-detects..."
    pushd vendor/alpha >/dev/null
    output=$("$GO_BIN" diff 2>&1 || true)
    echo "$output"
    if ! echo "$output" | grep -q "alpha"; then
        fail "Test 6 (Go): auto-detect should show alpha diff"
    fi
    if echo "$output" | grep -q "beta"; then
        fail "Test 6 (Go): auto-detect should NOT show beta diff"
    fi
    popd >/dev/null
    log_success "Test 6 passed: Go auto-detects patch from CWD"

    log_header "Test 7 (Go): diff from repo root (no patches match CWD) shows all..."
    output=$("$GO_BIN" diff 2>&1 || true)
    if ! echo "$output" | grep -q "alpha" || ! echo "$output" | grep -q "beta"; then
        fail "Test 7 (Go): diff from repo root should show all patches"
    fi
    log_success "Test 7 passed: Go shows all patches from repo root"
fi

# --- Test 8: override markers print manual diff commands ---
log_header "Test 8: override markers print manual diff commands..."
cat > vendor/alpha/.crossignore <<'EOF'
.env
EOF
output=$(just cross diff vendor/alpha 2>&1 || true)
echo "$output"
if ! echo "$output" | grep -q '.env'; then
    fail "Test 8: diff should print manual override file command"
fi
rm -f vendor/alpha/.crossignore

echo ""
echo "All context-aware diff tests passed!"
