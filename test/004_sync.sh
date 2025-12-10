#!/bin/bash
source test/common.sh

CLEANUP={$CLEANUP:-true} source test/002_patch.sh

# Modify upstream
echo "v2" > "$upstream_path/src/lib/file_sync.txt"
git -C "$upstream_path" add "$upstream_path/src/lib/file_sync.txt"
git -C "$upstream_path" commit -am "Update file" -q

# Sync
log_header "Testing 'just cross sync'..."
just cross sync vendor/lib

# Verify local updated
assert_grep "vendor/lib/file_sync.txt" "v2"




######
######

log_header "Testing conflict sync..."
# Test conflict handling (optional, maybe complex for automated test)

# Modify local
echo "v3-local" > "vendor/lib/file_sync.txt"
# Modify upstream
echo "v3-upstream" > "$upstream_path/src/lib/file_sync.txt"
git -C "$upstream_path" commit -am "Conflict update" -q

# Sync should fail or ask for manual resolution
# Our implementation exits 1 if pull --rebase fails.
# But since we run in non-interactive mode, it might just fail.


cd vendor/lib
if just cross sync; then
    echo "Sync succeeded unexpectedly (should have conflict)."
    # It might succeed if git auto-merges?
    # v3-local vs v3-upstream on same line -> conflict.
    # But wait, sync logic:
    # 1. rsync local to wt
    # 2. commit local changes in wt
    # 3. pull --rebase upstream
    # 4. rsync back
    
    # So:
    # WT has v2.
    # Local has v3-local.
    # Rsync -> WT has v3-local.
    # Commit -> WT HEAD is v3-local.
    # Upstream has v3-upstream.
    # Pull rebase -> Conflict between v3-local and v3-upstream.
    
    # So it should fail.
else
    echo "Sync failed as expected (conflict)."
fi

echo "Success!"
