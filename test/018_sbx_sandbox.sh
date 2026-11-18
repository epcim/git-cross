#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

# Test 018: sbx/sandbox update workflow — a local edit collides with a concurrent
# upstream update.
#
# v0.5.0 update contract (ADR-003):
#   1. fetch EVERY patch first (innocent: refs only, no work tree touched)
#   2. per patch: uncommitted changes -> refuse ("commit them in your repo first")
#      committed changes -> land upstream + re-apply the user's version on top;
#      collisions are KEPT as unmerged paths + markers, finished by
#      `git cross resolve [--continue|--abort]`

setup_sandbox
cd "$SANDBOX"

GO_BIN=$(ensure_go_bin "$REPO_ROOT" || true)
if [ -z "${GO_BIN:-}" ]; then
    echo "SKIP: Go toolchain unavailable or binary cannot run"
    exit 0
fi

upstream_path=$(create_upstream "ai-project")
mkdir -p "$upstream_path/src"
echo "v1" > "$upstream_path/src/app.js"
git -C "$upstream_path" add src/app.js
git -C "$upstream_path" commit -m "Add app" -q

"$GO_BIN" use ai-project "file://$upstream_path"
"$GO_BIN" set ai-project:src vendor/ai-src

# v2 D3 nesting: tracked files live under <patch>/src/
PATCH_FILE="vendor/ai-src/src/app.js"

# Simulate local/sandbox edits and a concurrent upstream update on the SAME file.
echo "local AI change" > "$PATCH_FILE"
echo "upstream v2" > "$upstream_path/src/app.js"
echo "new upstream file" > "$upstream_path/src/new.js"
git -C "$upstream_path" add src
git -C "$upstream_path" commit -m "Upstream update" -q

output=$("$GO_BIN" update vendor/ai-src 2>&1)
echo "$output"
# The local edit is UNSTAGED, so update refuses: the checkout/cherry-pick would
# destroy the only copy. (Committed work is safe and becomes resolve's input.)
if ! grep -q "local AI change" "$PATCH_FILE"; then
    fail "Update overwrote an uncommitted local change"
fi
if ! echo "$output" | grep -q "has modified files; commit them in your repo first"; then
    fail "Update must ask the user to commit the uncommitted patch first"
fi
if echo "$output" | grep -q "compare"; then
    fail "Review block must not mention the removed compare command"
fi
if echo "$output" | grep -q "Local edits detected"; then
    fail "Update still prints the old 'Local edits detected' wording"
fi
if echo "$output" | grep -q "DirDiff"; then
    fail "Update should not print the configured diff tool command"
fi

# Phase 1 still ran: the fetched upstream is present at refs/remotes/origin/<branch>.
gd=$(jq -r '.patches[] | select(.local_path == "vendor/ai-src") | .gitdir' .cross/metadata.json)
br=$(jq -r '.patches[] | select(.local_path == "vendor/ai-src") | .branch' .cross/metadata.json)
[ -d "$gd" ] || fail "patch gitdir not found: $gd"
if ! git --git-dir="$gd" show "refs/remotes/origin/$br:src/app.js" | grep -q "upstream v2"; then
    fail "Fetched upstream (upstream v2) must be present at refs/remotes/origin/$br"
fi
if ! git --git-dir="$gd" cat-file -e "refs/remotes/origin/$br:src/new.js" 2>/dev/null; then
    fail "The new upstream file must be present in the fetched tree"
fi
if [ -e "vendor/ai-src/src/new.js" ]; then
    fail "A refused (uncommitted) patch must not receive new upstream files"
fi

# Committing the local edit in the USER's repo (the mainstream case) makes the
# patch landable: upstream is applied and the user's change re-applied on top.
git add "$PATCH_FILE" && git commit -qm "sandbox local AI change"
output=$("$GO_BIN" update vendor/ai-src 2>&1)
echo "$output"
if ! echo "$output" | grep -q "conflict in 'vendor/ai-src'"; then
    fail "A committed local change colliding with upstream must be kept as a conflict"
fi
if ! echo "$output" | grep -q "git cross resolve"; then
    fail "Update must point at git cross resolve when a conflict is kept"
fi
if [ -z "$(git ls-files -u | awk '{print $4}' | sort -u)" ]; then
    fail "the collision must be represented as unmerged paths in the user repo"
fi
if ! grep -q "<<<<<<<" "$PATCH_FILE"; then
    fail "conflict markers must be present in the patch dir"
fi
if [ ! -e "vendor/ai-src/src/new.js" ]; then
    fail "the new upstream file must land even when another file conflicts"
fi
# Resolve like a user would, then let the mirror follow.
printf 'resolved app\n' > "$PATCH_FILE"
git add "$PATCH_FILE"
cont=$("$GO_BIN" resolve --continue vendor/ai-src 2>&1); echo "$cont"
if ! echo "$cont" | grep -q "is clean"; then
    fail "resolve --continue should confirm the patch is clean"
fi
if [ "$(git --git-dir="$gd" rev-parse HEAD)" != "$(git --git-dir="$gd" rev-parse "refs/remotes/origin/$br")" ]; then
    fail "resolve --continue must let the mirror follow the landed upstream"
fi
git commit -qm "resolved"
out=$("$GO_BIN" update vendor/ai-src 2>&1); echo "$out"
if ! echo "$out" | grep -q "already up to date"; then
    fail "after a completed resolve the next update should be a no-op"
fi
echo "Update workflow test passed."
