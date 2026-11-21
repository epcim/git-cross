#!/bin/bash
# Source 001 to setup environment and run 'use' tests
# This sets up SANDBOX, upstream_path, upstream_url, and runs 'just cross use'
CLEANUP={$CLEANUP:-true} source test/001_use.sh

log_header "Testing 'just cross set' (002)..."

# Add content to upstream
mkdir -p "$upstream_path/src/lib"
echo "lib v1" > "$upstream_path/src/lib/lib.txt"
git -C "$upstream_path" add src/lib/lib.txt
git -C "$upstream_path" commit -m "Add lib" -q

# Use and patch
just cross use repo1 "$upstream_url"

# v0.6 (ADR-004): the Just/Fish reference REFUSES subdir crosses — that IS
# the reference contract now. Assert the refusal message + non-zero exit.
# NB: capture inside an `if` so `set -e` consumers (014) don't abort on it.
refusal_status=0
if refusal_output=$(just cross set repo1:src/lib vendor/lib 2>&1); then
    refusal_status=0
else
    refusal_status=1
fi
echo "$refusal_output"
if [ "$refusal_status" -eq 0 ]; then
    echo "Assertion failed: just cross set on a subdir cross must exit non-zero."
    exit 1
fi
case "$refusal_output" in
    *"NOT IMPLEMENTED in Justfile version: subtree crosses"*) ;;
    *)
        echo "Assertion failed: expected the 'NOT IMPLEMENTED ... subtree crosses' refusal."
        exit 1
        ;;
esac
if just_ref_subdir; then
    echo "Assertion failed: just_ref_subdir must report subdir crosses as refused."
    exit 1
fi

# Create the cross with the GO binary so the shared chain sandbox (003/004/014)
# has the patch. Subtree crosses are Go-only (ADR-004).
GO_BIN=$(ensure_go_bin "$REPO_ROOT" || true)
if [ -z "$GO_BIN" ] || [ ! -x "$GO_BIN" ]; then
    echo "Failed: Go binary unavailable — subtree crosses cannot be created; 002 requires Go."
    exit 1
fi
"$GO_BIN" set repo1:src/lib vendor/lib

# Verify
log_header "Verify 'just cross set' (002)..."
assert_dir_exists "vendor/lib"
# v0.6 D3(c) subtree-rooted: the crossed dir IS the upstream subdirectory —
# repo1:src/lib vendor/lib materializes vendor/lib/lib.txt (no src/lib/ prefix)
assert_file_exists "vendor/lib/lib.txt"
assert_grep "vendor/lib/lib.txt" "lib v1"
if [ -e "vendor/lib/src" ]; then
    echo "Assertion failed: no upstream path prefix may appear in the crossed dir."
    exit 1
fi

# Verify Crossfile
assert_grep "Crossfile" "cross set repo1:main:src/lib vendor/lib"

echo "Success!"
