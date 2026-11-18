#!/bin/bash
source test/common.sh

setup_sandbox "$TESTDIR" "true"

# Setup upstream
upstream_path=$(create_upstream "repo1")
upstream_url="file://$upstream_path"

# Add content to upstream
mkdir -p "$upstream_path/src/metal"
echo "metal config" > "$upstream_path/src/metal/config.yaml"
git -C "$upstream_path" add src/metal/config.yaml
git -C "$upstream_path" commit -m "Add metal config" -q

# Create a Crossfile entry manually (simulating what a user might have checked in)
# We append to test that replay works with existing entries too
echo "" >| Crossfile
cat >> Crossfile <<EOF
# upstream (standard 'cross' prefix)
cross use repo1 $upstream_url

# cross patches (mixing prefixes for test coverage)
git cross patch repo1:src/metal deploy/metal
just cross exec "echo 'Replay hook working'"
EOF

# Run replay
log_header "Testing 'just cross replay'..."
just cross replay

# Verify remote added
if ! git remote show | grep -q "^repo1$"; then
    echo "Failed: Remote repo1 not added."
    exit 1
fi

# Verify files patched
assert_dir_exists "deploy/metal"
assert_file_exists "deploy/metal/config.yaml"
assert_grep "deploy/metal/config.yaml" "metal config"

echo "Success!"
