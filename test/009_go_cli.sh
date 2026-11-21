#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"

# Test 009: Go CLI against the v0.5.0 gitdir architecture.
#
# v0.5.0 semantics under test:
#   use     -> remotes in .cross/metadata.json only (primary git untouched)
#   patch   -> bare gitdir .cross/worktrees/<remote>/<local> + in-repo work tree
#              (D3 nesting: the patch dir mirrors the upstream ROOT)
#   update  -> fetch ALL patches first, then move each patch dir to upstream;
#              a modified patch dir is refused ("commit first"), a diverged one
#              is overwritten with the old HEAD kept under refs/cross/backup/
#   diff    -> passthrough: inside a patch dir = git diff vs upstream
#   stat    -> health table (renamed from status)
#   purge   -> renamed from prune (native prune is a passthrough)
#   set     -> renamed from init (init kept as alias)
#   compare -> REMOVED in v0.5.0 (with cmp, cross.dirdifftool and DIRDIFF_*)

# Initialize sandbox
setup_sandbox
cd "$SANDBOX"

mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/fzf" <<'EOF'
#!/usr/bin/env bash
lines=()
while IFS= read -r line; do
  lines+=("$line")
done
for (( idx=${#lines[@]}-1; idx>=0; idx-- )); do
  line="${lines[$idx]}"
  trimmed="$(echo "$line" | tr -d '[:space:]')"
  if [[ -z "$trimmed" ]]; then continue; fi
  if [[ "$line" == LOCAL_PATH* ]]; then continue; fi
  echo "$line"
  exit 0
done
exit 0
EOF
chmod +x "$SANDBOX/bin/fzf"
export PATH="$SANDBOX/bin:$PATH"

# Compile go binary
GO_BIN=$(ensure_go_bin "$REPO_ROOT")
if [ -z "$GO_BIN" ]; then
    echo "SKIP: Go toolchain unavailable or binary cannot run on this platform."
    exit 0
fi

# Smoke test: retired commands stay out of help.
command_help=$("$GO_BIN" --help 2>&1)
for retired_command in sync push replay exec prune status diff; do
    if echo "$command_help" | grep -Eq "^[[:space:]]+$retired_command[[:space:]]"; then
        fail "Retired command '$retired_command' is still exposed in Go CLI help"
    fi
done

# Setup upstream
upstream_path=$(create_upstream "go-demo")
upstream_url="file://$upstream_path"

pushd "$upstream_path" >/dev/null
mkdir -p src
echo "Go logic" > src/logic.go
git add src/logic.go
git commit -m "Add go logic"
popd >/dev/null

log_header "Testing Go 'use' command (metadata only, primary git untouched)..."
"$GO_BIN" use demo "$upstream_url"
assert_file_exists ".cross/metadata.json"
assert_grep ".cross/metadata.json" '"name": "demo"'
assert_grep ".cross/metadata.json" "\"url\": \"$upstream_url\""
assert_grep "Crossfile" "cross use demo $upstream_url"
if git remote | grep -q "^demo$"; then
    fail "Go 'use' must NOT add a git remote to the primary repo (v2)"
fi

log_header "Testing Go 'patch' command without branch..."
"$GO_BIN" set demo:src vendor/go-src
# v0.6 D3(c) subtree-rooted: the patch dir mirrors the remote SUBTREE root -> <local>/logic.go
if [ ! -f "vendor/go-src/logic.go" ]; then
    fail "Go 'patch' failed to vendor src/logic.go"
fi
[ -e vendor/go-src/.git ] && fail "patch dir must not contain a .git file"
assert_dir_exists ".cross/worktrees/demo/vendor_go-src"
# ADR-001: every location is recorded explicitly
assert_grep ".cross/metadata.json" '"worktree": "vendor/go-src"'
assert_grep ".cross/metadata.json" '"gitdir": ".cross/worktrees/demo/vendor_go-src"'

log_header "Testing Go 'patch' command with explicit branch..."
"$GO_BIN" set demo:main:src vendor/go-src-branch
if [ ! -f "vendor/go-src-branch/logic.go" ]; then
    fail "Go 'patch' with explicit branch failed"
fi

log_header "Testing Go 'patch' command with nested path and leading slash..."
pushd "$upstream_path" >/dev/null
    mkdir -p nested/dir
    echo "Nested file" > nested/dir/file.txt
    git add nested/dir/file.txt
    git commit -m "Add nested file" >/dev/null
popd >/dev/null
"$GO_BIN" set demo:main:/nested/dir vendor/nested-dir
if [ ! -f "vendor/nested-dir/file.txt" ]; then
    fail "Go 'patch' failed to vendor nested dir"
fi

log_header "Testing Go 'patch' with whole repo root (.: and :/)..."
root_upstream=$(create_upstream "root-demo")
pushd "$root_upstream" >/dev/null
echo "root file" > root.txt
mkdir -p sub
echo "sub file" > sub/data.txt
git add . && git commit -m "Root content" -q
popd >/dev/null

"$GO_BIN" use root-demo "file://$root_upstream"
"$GO_BIN" set root-demo:. vendor/whole-repo
if [ ! -f "vendor/whole-repo/root.txt" ]; then
    fail "Go 'patch' with '.' failed to vendor root.txt"
fi
if [ ! -f "vendor/whole-repo/sub/data.txt" ]; then
    fail "Go 'patch' with '.' failed to vendor sub/data.txt"
fi
# whole-repo patches must not be sparse
if [ -f ".cross/worktrees/root-demo/vendor_whole-repo/info/sparse-checkout" ]; then
    fail "whole-repo patch must not write a sparse pattern"
fi

"$GO_BIN" set root-demo:/ vendor/whole-repo-slash
if [ ! -f "vendor/whole-repo-slash/root.txt" ]; then
    fail "Go 'patch' with '/' failed to vendor root.txt"
fi
"$GO_BIN" del vendor/whole-repo-slash

log_header "Testing Go 'list' command..."
list_output=$("$GO_BIN" ls 2>&1)
echo "$list_output"
if ! echo "$list_output" | grep -q "demo"; then
    fail "Go 'list' should show remote 'demo'"
fi
if ! echo "$list_output" | grep -q "vendor/go-src"; then
    fail "Go 'list' should show patch path 'vendor/go-src'"
fi

log_header "Testing Go 'list --raw' machine-readable output..."
raw_output=$("$GO_BIN" ls --raw 2>/dev/null)
echo "$raw_output"
if echo "$raw_output" | grep -q "==>"; then
    fail "Go 'list --raw' must not print section banners"
fi
if echo "$raw_output" | grep -q '^+'; then
    fail "Go 'list --raw' must not print table borders ('+')"
fi
if echo "$raw_output" | grep -q '|'; then
    fail "Go 'list --raw' must not print table borders ('|')"
fi
if ! echo "$raw_output" | grep -q "REMOTE_NAME" || ! echo "$raw_output" | grep -q "REMOTE_URL"; then
    fail "Go 'list --raw' should print the REMOTE_NAME/REMOTE_URL header"
fi
# ADR-001: LOCAL_PATH stays field 3; WORKTREE and GITDIR are both present.
for col in LOCAL_PATH WORKTREE GITDIR BRANCH; do
    if ! echo "$raw_output" | grep -q "$col"; then
        fail "Go 'list --raw' should print the patch header with $col"
    fi
done
if ! printf '%s\n' "$raw_output" | cut -f3 | grep -qx "vendor/go-src"; then
    fail "Go 'list --raw' patches block: 'cut -f3' should yield local paths"
fi
if ! printf '%s\n' "$raw_output" | cut -f4 | grep -qx "vendor/go-src"; then
    fail "Go 'list --raw' WORKTREE column should hold the patch dir"
fi
if ! printf '%s\n' "$raw_output" | cut -f5 | grep -qx ".cross/worktrees/demo/vendor_go-src"; then
    fail "Go 'list --raw' GITDIR column should hold the bare gitdir"
fi
if ! printf '%s\n' "$raw_output" | cut -f1 | grep -qx "demo"; then
    fail "Go 'list --raw' remotes block should start with the remote name"
fi

raw_again=$("$GO_BIN" ls --raw 2>/dev/null)
if [ "$raw_output" != "$raw_again" ]; then
    fail "Go 'list --raw' output is not deterministic between runs"
fi

noheader_output=$("$GO_BIN" ls --raw --no-header 2>/dev/null)
echo "$noheader_output"
if echo "$noheader_output" | grep -q "REMOTE_NAME" || echo "$noheader_output" | grep -q "LOCAL_PATH"; then
    fail "Go 'list --raw --no-header' should omit the header lines"
fi
if ! printf '%s\n' "$noheader_output" | cut -f3 | grep -qx "vendor/go-src"; then
    fail "Go 'list --raw --no-header' should still print patch rows"
fi

table_noheader=$("$GO_BIN" ls --no-header 2>&1)
if echo "$table_noheader" | grep -q "REMOTE PATH" || echo "$table_noheader" | grep -q "LOCAL PATH"; then
    fail "Go 'list --no-header' should omit the table headers"
fi
if ! echo "$table_noheader" | grep -q "vendor/go-src"; then
    fail "Go 'list --no-header' should still print the patch rows"
fi

log_header "Testing Go 'ls' health columns (DIFF/SHA)..."
stat_output=$("$GO_BIN" ls 2>&1)
echo "$stat_output"
if ! echo "$stat_output" | grep -q "vendor/go-src"; then
    fail "Go 'ls' should show cross 'vendor/go-src'"
fi
if ! echo "$stat_output" | grep "vendor/go-src" | grep -q "Clean"; then
    fail "Go 'ls' DIFF should report a fresh cross as Clean"
fi

log_header "Testing Go 'update' command..."
pushd "$upstream_path" >/dev/null
echo "Updated go logic" > src/logic.go
git add src/logic.go
git commit -m "Update go logic"
popd >/dev/null

"$GO_BIN" update vendor/go-src
if ! grep -q "Updated go logic" "vendor/go-src/logic.go"; then
    fail "Go 'update' failed to pull updates"
fi

log_header "Testing Go update refuses an UNCOMMITTED patch dir (git-like ask-first)..."
echo "local-only edit" >> vendor/go-src/logic.go
pushd "$upstream_path" >/dev/null
echo "upstream update after local edit" >> src/logic.go
git add src/logic.go
git commit -m "Update logic again" -q
popd >/dev/null
update_output=$("$GO_BIN" update vendor/go-src 2>&1)
echo "$update_output"
if ! grep -q "local-only edit" vendor/go-src/logic.go; then
    fail "Go update overwrote the uncommitted local edit"
fi
if ! echo "$update_output" | grep -q "has modified files; commit them in your repo first"; then
    fail "Go update should ask the user to commit the uncommitted patch first"
fi
if ! echo "$update_output" | grep -q "not updated"; then
    fail "Go update should say the modified patch was NOT updated"
fi
# Fetch is innocent and happens for every patch, even a refused one.
if ! git --git-dir=".cross/worktrees/demo/vendor_go-src" show "refs/remotes/origin/main:src/logic.go" | grep -q "upstream update after local edit"; then
    fail "Fetch phase should have stored upstream at refs/remotes/origin/main in the gitdir"
fi
if echo "$update_output" | grep -q "Local edits detected"; then
    fail "Go update still prints the old 'Local edits detected' wording"
fi
if echo "$update_output" | grep -Eq "DirDiff|compare"; then
    fail "Go update must not advertise the removed compare command or dirdiff tool"
fi

log_header "Testing Go update keeps a CONFLICT and resolve --abort/--continue finish it (ADR-003)..."
# The mainstream case: the user commits in THEIR repo, upstream moves on the same
# file. update lands upstream and re-applies the user's change; the collision is
# left in the repo as unmerged paths (no silent overwrite, no data loss).
gd=".cross/worktrees/demo/vendor_go-src"
git add vendor/go-src && git commit -qm "vendor: local edit"
pushd "$upstream_path" >/dev/null
echo "upstream after divergence" > src/logic.go
git commit -qam "Update logic a third time"
popd >/dev/null
update_output=$("$GO_BIN" update vendor/go-src 2>&1)
echo "$update_output"
if ! echo "$update_output" | grep -q "conflict in 'vendor/go-src'"; then
    fail "Go update should keep the conflict instead of overwriting"
fi
if [ -z "$(git ls-files -u | awk '{print $4}' | sort -u)" ]; then
    fail "a conflict must leave unmerged paths in the user repo"
fi
if ! grep -q "<<<<<<<" vendor/go-src/logic.go; then
    fail "conflict markers should be present in the patch dir"
fi
# abort restores the user's version and keeps the fetch
abort_out=$("$GO_BIN" resolve --abort vendor/go-src 2>&1); echo "$abort_out"
if [ -n "$(git ls-files -u)" ]; then
    fail "resolve --abort should clear unmerged paths"
fi
if ! grep -q "local-only edit" vendor/go-src/logic.go; then
    fail "resolve --abort should restore the user's version"
fi
# re-run update, resolve, continue
"$GO_BIN" update vendor/go-src >/dev/null 2>&1 || true
printf 'resolved logic\n' > vendor/go-src/logic.go
git add vendor/go-src/logic.go
cont_out=$("$GO_BIN" resolve --continue vendor/go-src 2>&1); echo "$cont_out"
if ! echo "$cont_out" | grep -q "is clean"; then
    fail "resolve --continue should confirm the patch is clean"
fi
# v0.6: mirror refs/heads/<branch> is a SYNTHESIZED subtree branch — its commit
# hash NEVER equals raw origin/main. Compare TREES instead.
if [ "$(git --git-dir="$gd" rev-parse 'refs/heads/main^{tree}')" != "$(git --git-dir="$gd" rev-parse 'refs/remotes/origin/main:src')" ]; then
    fail "resolve --continue should let the mirror's synthesized tree follow the landed upstream"
fi
git commit -qm "vendor: resolved"

log_header "Testing Go pure passthrough git inside a patch dir..."
pushd vendor/go-src >/dev/null
    o=$("$GO_BIN" status --short --branch 2>&1)
    echo "$o"
    if ! echo "$o" | grep -q "## main"; then
        fail "git cross status inside a patch must run in the upstream context"
    fi
    # v0.6: the synthesized branch re-roots the subtree, so the tracked file is logic.go
    if ! echo "$o" | grep -q "logic.go"; then
        fail "upstream status should report the locally modified tracked file"
    fi
    diff_output=$("$GO_BIN" diff 2>&1 || true)
    echo "$diff_output"
    # The user's repo committed "resolved logic"; the mirror sits at upstream, so
    # the upstream-context diff shows the resolved content as a local modification.
    if ! echo "$diff_output" | grep -q "resolved logic"; then
        fail "git cross diff inside a patch must show the local modification"
    fi
popd >/dev/null
# Outside a patch dir the passthrough fails early (ADR-002) instead of running
# plain git on the primary repo.
out=$("$GO_BIN" rev-parse --show-toplevel 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
    fail "passthrough outside a patch must fail (no GIT_DIR/GIT_WORK_TREE), got: $out"
fi
assert_contains "$out" "crossed directory" "missing patch context must be explained"

log_header "Testing 'compare' is removed (v0.5.0)..."
# v0.5.0 dropped `compare`/`cmp`: the crossed directory IS upstream's work tree, so
# there is no second checkout to diff against. The name must not be a cross
# command any more; it falls through to the passthrough, which refuses outside a
# crossed directory.
cmp_rc=0
cmp_out=$(cd "$SANDBOX" && "$GO_BIN" compare 2>&1) || cmp_rc=$?
echo "$cmp_out"
[ "$cmp_rc" -ne 0 ] || fail "'compare' must not be a cross command any more"
assert_contains "$(cd "$SANDBOX" && "$GO_BIN" --help 2>&1)" "" "help sanity"
if "$GO_BIN" --help 2>&1 | grep -Eq '^\s+(compare|cmp)\s'; then
    fail "grouped help must not list compare/cmp"
fi
# ... and the removed config keys are inert: nothing reads them.
git config cross.dirdifftool 'echo SHOULD-NOT-RUN {left} {right}'
stale_out=$(cd "$SANDBOX" && "$GO_BIN" compare 2>&1 || true)
assert_not_contains "$stale_out" "SHOULD-NOT-RUN" "cross.dirdifftool must be ignored"
git config --unset cross.dirdifftool
log_success "'compare' and cross.dirdifftool are gone"

log_header "Testing Go 'set' command (renamed from init, init kept as alias)..."
init_dir="$SANDBOX/init-test"
mkdir -p "$init_dir"
pushd "$init_dir" >/dev/null
git init -q
git config user.email "test@example.com"
git config user.name "Test User"
"$GO_BIN" cfg
if [ ! -f "Crossfile" ]; then
    fail "Go 'set' failed to create Crossfile"
fi
rm -f Crossfile
"$GO_BIN" init
if [ ! -f "Crossfile" ]; then
    fail "Go 'init' alias failed to create Crossfile"
fi
# rerere is enabled in the (primary) repo config by set
if [ "$(git config --get rerere.enabled)" != "true" ]; then
    fail "Go 'set' should enable rerere in the repo config"
fi
popd >/dev/null

log_header "Testing Go 'update' from Crossfile in a fresh repository..."
update_dir="$SANDBOX/update-test"
mkdir -p "$update_dir"
pushd "$update_dir" >/dev/null
git init -q
git config user.email "test@example.com"
git config user.name "Test User"
echo "replay test" > README.md
git add . && git commit -m "init" -q

cat > Crossfile <<CROSSEOF
cross use demo $upstream_url
cross set demo:main:src vendor/update-src
CROSSEOF

"$GO_BIN" update
if [ ! -f "vendor/update-src/logic.go" ]; then
    fail "Go 'update' failed to create a missing patch from Crossfile"
fi
# assert_grep resolves against $SANDBOX, and we are inside update-test/
assert_grep "update-test/.cross/metadata.json" '"worktree": "vendor/update-src"'
# rerere is also enabled in the fresh patch's own gitdir
if [ "$(git --git-dir=.cross/worktrees/demo/vendor_update-src config --get rerere.enabled)" != "true" ]; then
    fail "Go 'update' should enable rerere in the patch gitdir"
fi
log_success "Go Crossfile update test passed"
popd >/dev/null

log_header "Testing Go 'remove' command..."
pushd "$upstream_path" >/dev/null
mkdir -p extras
echo "extra content" > extras/extra.txt
git add extras/extra.txt
git commit -m "Add extras" -q
popd >/dev/null

"$GO_BIN" set demo:extras vendor/extras
if [ ! -f "vendor/extras/extra.txt" ]; then
    fail "Go 'patch' for extras failed"
fi

"$GO_BIN" del vendor/extras
if [ -d "vendor/extras" ]; then
    fail "Go 'remove' should delete vendor/extras directory"
fi
if [ -d ".cross/worktrees/demo/vendor_extras" ]; then
    fail "Go 'remove' should delete the patch gitdir"
fi
if grep -q "vendor/extras" Crossfile 2>/dev/null; then
    fail "Go 'remove' should clean Crossfile entry"
fi
if jq -e '.patches[] | select(.local_path == "vendor/extras")' .cross/metadata.json >/dev/null 2>&1; then
    fail "Go 'remove' should clean the metadata entry"
fi
log_success "Go remove test passed"

log_header "Testing Go 'wipe' command (prune -> purge -> wipe)..."
purge_upstream=$(create_upstream "purge-demo")
pushd "$purge_upstream" >/dev/null
mkdir -p lib
echo "purge lib" > lib/purge.txt
git add lib/purge.txt
git commit -m "Add purge lib" -q
popd >/dev/null

"$GO_BIN" use purge-remote "file://$purge_upstream"
"$GO_BIN" set purge-remote:lib vendor/purge-lib

if [ ! -f "vendor/purge-lib/purge.txt" ]; then
    fail "Purge setup: patch not created"
fi

"$GO_BIN" wipe purge-remote
# v0.5.1 contract: wipe owns metadata + gitdirs ONLY — the crossed dirs are
# the user's tracked files and stay (remove them with: git cross del <path>).
if [ ! -d "vendor/purge-lib" ] || [ ! -f "vendor/purge-lib/purge.txt" ]; then
    fail "Go 'wipe' must leave crossed dirs and their files in place"
fi
if [ -d ".cross/worktrees/purge-remote" ]; then
    fail "Go 'wipe' should remove the remote's gitdir directory"
fi
if jq -e '.remotes[] | select(.name == "purge-remote")' .cross/metadata.json >/dev/null 2>&1; then
    fail "Go 'wipe' should remove the remote metadata record"
fi
if jq -e '.patches[] | select(.local_path == "vendor/purge-lib")' .cross/metadata.json >/dev/null 2>&1; then
    fail "Go 'wipe' should drop the remote's patch records"
fi
# v2: unused-remote sweep + orphaned gitdir sweep
stray=".cross/worktrees/purge-remote/stray_gitdir"
mkdir -p "$stray"
printf 'n' | "$GO_BIN" wipe >/dev/null 2>&1 || true
if [ -d "$stray" ]; then
    fail "Go 'wipe' should sweep orphaned gitdirs"
fi
log_success "Go wipe test passed"

log_header "Testing Go root-target remove guard..."
cat > Crossfile <<'EOF'
# git-cross configuration
cross set root-remote:main:. .
EOF
mkdir -p .cross
cat > .cross/metadata.json <<'EOF'
{"remotes":[{"name":"root-remote","url":"file:///nonexistent"}],"patches":[{"remote":"root-remote","remote_url":"file:///nonexistent","remote_path":".","local_path":".","worktree":".","gitdir":".cross/worktrees/root-remote/repo","branch":"main"}]}
EOF
echo "keep me" > keep-root-go.txt

"$GO_BIN" del .
if [ ! -f "keep-root-go.txt" ]; then
    fail "Go root-target remove deleted repo root contents"
fi

echo "Go implementation tests passed!"
