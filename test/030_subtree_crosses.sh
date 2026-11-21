#!/usr/bin/env bash
set -euo pipefail

# Test 030: subtree-rooted subdirectory crosses (ADR-004, D3(c), v0.6).
#
# The contract: `set <remote>:<branch>:<path> <local>` checks out the CONTENT of
# <path> at <local>/ directly (no upstream path prefix), while whole-repo
# crosses (`.`) keep the v0.5 machinery byte for byte.
#
# Go-only: the synthesis/graft machinery and the passthrough pull/push
# interception live in the Go CLI (the Just reference follows in S4).
source "$(dirname "$0")/common.sh"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO_BIN="$(ensure_go_bin "$PROJECT_ROOT")"
[ -n "$GO_BIN" ] || { echo "SKIP: Go CLI unavailable"; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t

log_header "030: set — re-rooted layout (the original bug report)"

setup_sandbox
cd "$SANDBOX"
echo "upstream/" >> .gitignore
mkdir -p upstream/u1
( cd upstream/u1
  git init -q -b main .
  git config user.email up@t; git config user.name up
  mkdir -p demo/cluster-flux/apps demo/other docs
  echo "flux v1" > demo/cluster-flux/flux.yaml
  echo app1 > demo/cluster-flux/apps/app1.yaml
  echo other > demo/other/x.txt
  git add -A && git commit -qm "c1 init"
  echo o2 > demo/other/x.txt && git commit -qam "c2 outside-only"
)
UP="$SANDBOX/upstream/u1"

xc() { "$GO_BIN" "$@"; }

xc cfg >/dev/null 2>&1 || true
xc use up "$UP" >/dev/null 2>&1 || fail "use"
xc set up:main:demo/cluster-flux clusters/cluster-test >/dev/null 2>&1 || fail "set"
git add -A && git commit -qm "vendor v1" -q

# layout: content of demo/cluster-flux at the ROOT of the crossed dir
[ -f clusters/cluster-test/flux.yaml ] || fail "flux.yaml must be at the crossed dir ROOT"
[ -f clusters/cluster-test/apps/app1.yaml ] || fail "apps/ must be at the root"
[ ! -e clusters/cluster-test/demo ] || fail "no demo/ prefix may appear inside the cross"
[ ! -e clusters/cluster-test/docs ] || fail "no sibling upstream dirs may leak"

GD=$(xc env clusters/cluster-test --gitdir)
WT=$(xc env clusters/cluster-test --worktree)

# gitdir shape: synthesized branch + markers, NO sparse config, hooks installed
[ -n "$(git --git-dir="$GD" for-each-ref refs/cross/synthesized/main)" ] || fail "refs/cross/synthesized/<b> marker missing"
[ -n "$(git --git-dir="$GD" for-each-ref refs/cross/upstream/main)" ] || fail "refs/cross/upstream/<b> marker missing"
[ -f "$GD/info/sparse-checkout" ] && fail "subdir crosses must have NO sparse config"
[ -x "$GD/hooks/pre-rebase" ] || fail "pre-rebase guard hook missing"
[ -x "$GD/hooks/pre-push" ] || fail "pre-push guard hook missing"
[ "$(git --git-dir="$GD" rev-parse 'refs/heads/main^{tree}')" = "$(git --git-dir="$GD" rev-parse 'refs/cross/upstream/main:demo/cluster-flux')" ] \
  || fail "synthesized branch tree must equal the upstream subtree tree"

# cross context: clean status, subtree-only log (c2 outside-only skipped)
st=$(git --git-dir="$GD" --work-tree="$WT" status --short --branch)
echo "$st" | grep -q '^## main$' || fail "cross-ctx status must be clean on main"
[ "$(git --git-dir="$GD" rev-list --count refs/heads/main)" -eq 1 ] || fail "log must contain only commits touching the subtree (outside-only c2 skipped)"
log_success "030: set — re-rooted layout, markers, hooks, subtree log"

log_header "030: deterministic synthesis (delete + re-set → identical hashes)"
TIP1=$(git --git-dir="$GD" rev-parse refs/heads/main)
xc del clusters/cluster-test >/dev/null 2>&1 || fail "del"
xc set up:main:demo/cluster-flux clusters/cluster-test >/dev/null 2>&1 || fail "re-set"
TIP2=$(git --git-dir="$GD" rev-parse refs/heads/main)
[ "$TIP1" = "$TIP2" ] || fail "synthesis must be deterministic (identity+dates pinned)"
# The re-created content is identical — the primary repo has nothing new to
# commit (that IS the determinism assertion, from the work-tree side too).
git add -A; git commit -qm "vendor re-set" -q || true
log_success "030: deterministic synthesis ($TIP1)"

log_header "030: update — upstream adds/mods/deletes land re-rooted"
( cd "$UP"
  echo "flux v2" > demo/cluster-flux/flux.yaml     # M
  echo new > demo/cluster-flux/new.yaml            # A
  git rm -q demo/cluster-flux/apps/app1.yaml        # D
  echo o3 >> demo/other/x.txt                       # mixed: outside part must be ignored
  git add -A && git commit -qm "c3 sub A/M/D + other"
  echo y > demo/other/y.txt && git add -A && git commit -qm "c4 outside-only"
)
out=$(xc update </dev/null 2>&1) || fail "update"
echo "$out" | grep -q "Updated clusters/cluster-test" || fail "update should land"
grep -q "flux v2" clusters/cluster-test/flux.yaml || fail "upstream M not landed"
[ -f clusters/cluster-test/new.yaml ] || fail "upstream A not landed"
[ ! -e clusters/cluster-test/apps/app1.yaml ] || fail "upstream D not landed"
[ ! -e clusters/cluster-test/other ] || fail "outside paths must never leak"
git add -A && git commit -qm "vendor v2" -q
# markers advanced to the real upstream tip
[ "$(git --git-dir="$GD" rev-parse refs/cross/upstream/main)" = "$(git --git-dir="$GD" rev-parse refs/remotes/origin/main)" ] \
  || fail "upstream marker must equal the fetched tip after update"
# DIFF Clean after committing
xc ls --raw --no-header | grep -q "Clean" || fail "ls DIFF must be Clean after a landed update"
log_success "030: update — A/M/D re-rooted, markers advanced, DIFF Clean"

log_header "030: git cross pull -r — local commit, real conflict, rebase --continue"
echo "local note" > clusters/cluster-test/flux.yaml   # collides with the same line upstream edits
git --git-dir="$GD" --work-tree="$WT" add -A
git --git-dir="$GD" --work-tree="$WT" commit -qm "local note" || fail "cross-ctx commit"
( cd "$UP" && echo "flux v3" > demo/cluster-flux/flux.yaml && git commit -qam "c5 sub v3" )
cd clusters/cluster-test   # the passthrough requires the cross as CWD (ADR-002)
set +e
out=$(xc pull -r </dev/null 2>&1); rc=$?
set -e
echo "$out"
echo "$out" | grep -q "CONFLICT" || fail "pull -r must raise a REAL conflict (both edited flux.yaml)"
[ "$rc" -ne 0 ] || fail "conflicted pull must exit non-zero"
# markers must NOT advance while the rebase is unresolved
[ "$(git --git-dir="$GD" rev-parse refs/cross/upstream/main)" != "$(git --git-dir="$GD" rev-parse refs/remotes/origin/main)" ] \
  || fail "markers must not advance on a conflicted pull"
printf 'flux v3\nlocal note\n' > flux.yaml
git --git-dir="$GD" --work-tree="$WT" add flux.yaml
GIT_DIR="$GD" GIT_WORK_TREE="$WT" GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 || fail "rebase --continue"
# lazy heal on the next command: branch re-attached, markers caught up
out=$(xc pull -r </dev/null 2>&1) || true
echo "$out" | grep -q "already up to date" || fail "after manual continue the next pull must converge"
[ "$(git --git-dir="$GD" symbolic-ref HEAD)" = "refs/heads/main" ] || fail "HEAD must be re-attached (lazy heal)"
cd "$SANDBOX"
grep -q "flux v3" clusters/cluster-test/flux.yaml || fail "upstream v3 must be in the cross"
grep -q "local note" clusters/cluster-test/flux.yaml || fail "local edit must survive pull -r"
git add -A && git commit -qm "vendor after pull -r" -q
log_success "030: pull -r — conflict + continue + lazy heal"

log_header "030: hook guards — plain git pull -r / push refused with hints"
export GIT_DIR="$GD" GIT_WORK_TREE="$WT"
set +e
out=$(git pull -r origin main 2>&1); rc=$?
set +e; unset GIT_DIR GIT_WORK_TREE
echo "$out" | grep -q "use: git cross pull -r" || fail "plain pull -r must hit the pre-rebase guard"
[ "$rc" -ne 0 ] || fail "plain pull -r must exit non-zero"
set +e
out=$(GIT_DIR="$GD" GIT_WORK_TREE="$WT" git push origin main 2>&1); rc=$?
echo "$out" | grep -q "use: git cross push" || fail "plain push must hit the pre-push guard"
[ "$rc" -ne 0 ] || fail "plain push must exit non-zero"
log_success "030: hook guards"

log_header "030: git cross push — the graft (only sub/ changes reach upstream)"
cd "$SANDBOX"; git -C "$UP" config receive.denyCurrentBranch updateInstead
# more local work to push: a NEW file
echo pushed > clusters/cluster-test/pushed.txt
git --git-dir="$GD" --work-tree="$WT" add -A
git --git-dir="$GD" --work-tree="$WT" commit -qm "local: pushed.txt"
cd clusters/cluster-test
set +e
out=$(xc push </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "$out"; fail "graft push failed"; }
grep -q "pushed" "$UP/demo/cluster-flux/pushed.txt" || fail "graft must deliver the local file into the upstream subtree"
grep -q "flux v3" "$UP/demo/cluster-flux/flux.yaml" || fail "graft must keep the resolved content upstream"
[ -z "$(git -C "$UP" diff --name-only HEAD~1 HEAD -- . ':!demo/cluster-flux')" ] \
  || fail "graft must NEVER touch paths outside the subtree"
out=$(xc push </dev/null 2>&1) || true
echo "$out" | grep -q "nothing to push" || fail "a second push must detect the already-pushed state"
cd "$SANDBOX"
log_success "030: graft push — outside untouched, idempotent"

log_header "030: lineage check — a raw re-point is detected, not silent"
git --git-dir="$GD" update-ref refs/heads/main "$(git --git-dir="$GD" rev-parse refs/remotes/origin/main)"
out=$(xc update </dev/null 2>&1) || true
echo "$out" | grep -q "no longer descends from the synthesized history" \
  || fail "the lineage error must name the problem"
echo "$out" | grep -q "re-adopt" || fail "the lineage error must offer the recovery"
log_success "030: lineage check"

log_header "030: whole-repo cross — the v0.5 machinery, unchanged"
xc set up:. whole >/dev/null 2>&1 || fail "whole-repo set"
git add -A && git commit -qm "vendor whole" -q
GD2=$(xc env whole --gitdir); WT2=$(xc env whole --worktree)
[ -f whole/demo/cluster-flux/flux.yaml ] || fail "whole-repo cross mirrors the upstream ROOT (D3(a) layout, unchanged)"
[ -f "$GD2/info/sparse-checkout" ] && fail "whole-repo crosses get NO sparse config (same as v0.5)"
[ -e "$GD2/hooks/pre-rebase" ] && fail "whole-repo crosses get NO hooks"
[ -n "$(git --git-dir="$GD2" for-each-ref refs/cross)" ] && fail "whole-repo crosses get NO refs/cross markers"
( cd "$UP" && echo w1 > w.txt && git add -A && git commit -qm "c6 whole" )
set +e
out=$(GIT_DIR="$GD2" GIT_WORK_TREE="$WT2" git pull -r 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "$out"; fail "plain pull -r must STILL work for whole-repo crosses"; }
grep -q w1 "$WT2/w.txt" || fail "whole-repo pull -r must land the upstream file"
log_success "030: whole-repo cross — no synthesis, no hooks, plain pull -r works"

echo "Test 030 passed!"
