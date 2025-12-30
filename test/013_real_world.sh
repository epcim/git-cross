#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

# Note: This test requires internet access to clone runtipi-appstore
if [[ "${SKIP_NETWORK_TESTS:-}" == "true" ]]; then
    echo "Skipping network tests."
    exit 0
fi

setup_sandbox
cd "$SANDBOX"

log_header "Testing with real-world repo: runtipi-appstore"

# Use Go implementation for this real-world test as it's the primary one
GO_BIN="$REPO_ROOT/src-go/git-cross-go"
if [ ! -f "$GO_BIN" ]; then
    (cd "$REPO_ROOT/src-go" && go build -o "$GO_BIN" main.go)
fi

"$GO_BIN" init
"$GO_BIN" use runtipi https://github.com/runtipi/runtipi-appstore.git
"$GO_BIN" patch runtipi:apps/adguard vendor/adguard

assert_dir_exists "vendor/adguard"
assert_file_exists "vendor/adguard/config.json"
assert_file_exists "vendor/adguard/docker-compose.yml"

# Verify no extra files in worktree
wt_path=$(find .git/cross/worktrees -maxdepth 1 -name "runtipi_*" | head -n 1)
if [ -f "$wt_path/README.md" ]; then
    fail "README.md found in worktree! Sparse checkout failed."
fi

echo "Real-world test passed!"
