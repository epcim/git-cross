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
GO_BIN=$(ensure_go_bin "$REPO_ROOT" || true)
if [ -z "${GO_BIN:-}" ]; then
    echo "SKIP: Go toolchain unavailable or binary cannot run on this platform"
    exit 0
fi

"$GO_BIN" cfg
"$GO_BIN" use runtipi https://github.com/runtipi/runtipi-appstore.git
"$GO_BIN" set runtipi:apps/adguard vendor/adguard

# v2 D3 nesting: the patch dir mirrors the upstream ROOT, so the sparse subtree
# apps/adguard/ is materialized at vendor/adguard/apps/adguard/.
assert_dir_exists "vendor/adguard/apps/adguard"
assert_file_exists "vendor/adguard/apps/adguard/config.json"
assert_file_exists "vendor/adguard/apps/adguard/docker-compose.yml"

# Sparse filter: files outside apps/adguard must not be materialized.
gd=$(jq -r '.patches[] | select(.local_path == "vendor/adguard") | .gitdir' .cross/metadata.json)
wt=$(jq -r '.patches[] | select(.local_path == "vendor/adguard") | .worktree' .cross/metadata.json)
if [ -z "$gd" ] || [ "$gd" = "null" ]; then
    fail "metadata is missing 'gitdir' for vendor/adguard"
fi
grep -qx "apps/adguard/" "$gd/info/sparse-checkout" \
    || fail "info/sparse-checkout must contain 'apps/adguard/' (trailing slash)"
if [ -f "$wt/README.md" ]; then
    fail "README.md found in the patch dir! Sparse checkout failed."
fi

# The work tree is the patch dir: no .git pointer, plain files in the repo.
[ -e "$wt/.git" ] && fail "patch dir must not contain a .git file"

echo "Real-world test passed!"
