#!/usr/bin/env bash
# ADR-004 lab: the `git subtree` TOOLCHAIN flow on the real history of THIS repo
# (first 20 commits as the vendored state, commits 21..30 as the "upstream
# advance"). Validates the workflow proposed for D3(c) WITHOUT any custom
# algorithm — only git subtree split/add/merge — and records where git refuses.
#
# Corpus (pinned):
#   H20 = fafa43268a0a2e59b0c2db7b2fcb00ee78741863   first-20-commits state
#   H30 = e3b4e517b061f349f4b9910472d7f6bfa0ce0091   10 real commits later
#   prefix = test/  (13 files at H20; window = 4 M + 5 A; 6 of 10 commits touch it)
#
# No network. Owns /tmp/d3c-lab-subtree only. Prints a VERDICT block, exit!=0 on failure.
set -uo pipefail

SRC="/home/epcim/Workspace/github/epcim/git-cross"
H20=fafa43268a0a2e59b0c2db7b2fcb00ee78741863
H30=e3b4e517b061f349f4b9910472d7f6bfa0ce0091
PREFIX=test
LAB=/tmp/d3c-lab-subtree
declare -a RESULTS=()

say()  { printf '\n## %s\n' "$*"; }
ok()   { RESULTS+=("PASS: $*"); echo "PASS: $*"; }
bad()  { RESULTS+=("FAIL: $*"); echo "FAIL: $*"; FAILED=1; }
check(){ if [ "$1" = 0 ]; then ok "$2"; else bad "$2"; fi; }

FAILED=0
rm -rf "$LAB" && mkdir -p "$LAB" && cd "$LAB" || exit 1

say "corpus: upstream = this repo's first 20 commits (prefix '$PREFIX')"
git clone -q "$SRC" up && git -C up checkout -q -B main "$H20" && echo "up@main=$(git -C up rev-parse --short main)"
git clone -q up wc && echo "wc clone: $(git -C wc rev-list --count origin/main) commits"

# --- S1: split in a CLONE of upstream (the prefix exists at HEAD there) ------
say "1) subtree split of the upstream subdirectory"
S1=$(git -C wc subtree split --prefix="$PREFIX" origin/main 2>/dev/null) && check 0 "split ran (in a clone; prefix at HEAD)" || bad "split failed: $S1"
git -C wc update-ref "refs/subtree/$PREFIX" "$S1"
echo "S1=$S1  log:"; git -C wc log --format='    %h %an: %s' "$S1" | head -8
N_SUB=$(git -C wc rev-list --count "$S1"); N_TCH=$(git -C "$SRC" rev-list --count "$H20" -- "$PREFIX")
[ "$N_SUB" -eq "$N_TCH" ] && ok "split history = commits touching $PREFIX/ ($N_SUB; outside-only skipped)" || bad "split commit count $N_SUB != touching-count $N_TCH"

say "2) consumer repo: subtree add (vendored at xyz/)"
git init -q -b main work && cd work
git config user.email lab@t && git config user.name lab
echo own > README.md && git add -A && git commit -qm "own files"
git remote add wc ../wc && git fetch -q wc "refs/subtree/$PREFIX:refs/subtree/S1"
git subtree add --prefix=xyz refs/subtree/S1 >/dev/null 2>&1 && check 0 "subtree add xyz <- S1" || bad "subtree add failed"
ADD=$(git rev-parse HEAD)
git ls-tree -r --name-only HEAD xyz/ | sed 's|^xyz/||' | sort > /tmp/d3c-lab-subtree/got.txt
git -C "$SRC" ls-tree -r --name-only "$H20" "$PREFIX/" | sed "s|^$PREFIX/||" | sort > /tmp/d3c-lab-subtree/want.txt
cmp -s /tmp/d3c-lab-subtree/got.txt /tmp/d3c-lab-subtree/want.txt && ok "xyz/ == upstream $PREFIX/ content (re-rooted, all 13 files)" || { bad "xyz/ differs"; diff /tmp/d3c-lab-subtree/want.txt /tmp/d3c-lab-subtree/got.txt | head; }

say "3) local modifications (mod a file the window also modifies + local-only file)"
echo "# local note" >> xyz/009_go_cli.sh && echo local > xyz/local-note.md
git add -A && git commit -qm "local: mod+add" && ok "local commit on the vendored tree"

say "4) upstream advances 10 real commits (adds/mods/deletes + outside-only)"
cd ../up && git update-ref refs/heads/main "$H30" && echo "up@main -> $(git rev-parse --short main)"
cd ../wc && git fetch -q origin
S2=$(git subtree split --prefix="$PREFIX" origin/main 2>/dev/null) && echo "S2=$S2"
git update-ref "refs/subtree/$PREFIX" "$S2"
git merge-base --is-ancestor "$S1" "$S2" && ok "repeated split DESCENDS the first (stable, incremental ancestry)" || bad "re-splits produce parallel histories"
[ "$(git rev-list --count "$S1..$S2")" -eq 6 ] && ok "exactly the 6 commits touching $PREFIX/ were synthesized (4 outside-only skipped)" || bad "unexpected delta count: $(git rev-list --count "$S1..$S2")"

say "5) 3-way merge of the new split into xyz/"
cd ../work && git fetch -q wc "refs/subtree/$PREFIX:refs/subtree/S2"
git subtree merge --prefix=xyz refs/subtree/S2 >/dev/null 2>&1; RC=$?
if [ $RC -ne 0 ] && git status --porcelain | grep -qE '^(UU|AA)'; then
  ok "real 3-way conflict raised (markers), as a pull should"
  CONFLICTED=1
  while read -r st p; do
    case "$st" in UU|AA)
      git show "refs/subtree/S2:${p#xyz/}" > "$p" 2>/dev/null && git add "$p" || git rm -q "$p";;
    esac
  done < <(git status --porcelain | awk '{print $1" "$2}')
else
  CONFLICTED=0; ok "merged cleanly (no overlap in the window's changes)"
fi
git commit -qm "merge upstream $PREFIX (resolved)" >/dev/null 2>&1 || true
for f in 010_worktree.sh 012_sparse_checkout.sh 013_real_world.sh 014_remove.sh; do
  [ -f "xyz/$f" ] && ok "upstream ADD landed: xyz/$f" || bad "missing upstream add: xyz/$f"
done
grep -q "# local note" xyz/009_go_cli.sh && ok "local modification preserved through the merge" || bad "local edit lost"
[ -f xyz/local-note.md ] && ok "local-only file kept" || bad "local-only file lost"
[ -z "$(git diff --name-only "$ADD" HEAD -- . ':!xyz')" ] && ok "nothing outside xyz/ was touched" || bad "leak outside xyz/: $(git diff --name-only "$ADD" HEAD -- . ':!xyz')"
[ -f README.md ] && ok "own repo files intact" || bad "own files damaged"

say "6) push back: split xyz -> graft into an upstream clone at $PREFIX"
SL=$(git subtree split --prefix=xyz HEAD 2>/dev/null) && echo "SL=$SL (local history re-rooted)"
git update-ref refs/subtree/xyz "$SL"
cd .. && git clone -q up pusher && cd pusher
git config user.email lab@t && git config user.name lab
git remote add work ../work && git fetch -q work refs/subtree/xyz:refs/subtree/xyz
git subtree merge --prefix="$PREFIX" refs/subtree/xyz >/dev/null 2>&1; RC=$?
if [ $RC -ne 0 ]; then
  NCONF=$(git status --porcelain | grep -cE '^(UU|AA|AU|UA|DU|UD)') || true
  echo "    subtree merge into upstream exited $RC with ~$NCONF unmerged path(s) — recording raw behavior"
  while read -r st p; do
    case "$st" in UU|AA|AU|UA)
      if git show "refs/subtree/xyz:${p#$PREFIX/}" > "$p" 2>/dev/null; then git add "$p"; else git rm -q "$p"; fi;;
    DU|UD) git show "refs/subtree/xyz:${p#$PREFIX/}" > "$p" 2>/dev/null && git add "$p" || true;;
    esac
  done < <(git status --porcelain | awk '{print $1" "$2}')
  git commit -qm "graft: subtree take-theirs under $PREFIX/" >/dev/null 2>&1 || true
fi
OUTSIDE=$(git diff --name-only "$H30" HEAD -- . ":!$PREFIX" | grep -v '^$')
[ -z "$OUTSIDE" ] && ok "push-back NEVER touched paths outside $PREFIX/" || bad "outside paths damaged: $OUTSIDE"
grep -q "# local note" "$PREFIX/009_go_cli.sh" && ok "local change pushed back into upstream $PREFIX/" || bad "push-back lost the local change"
echo "--- pusher topology:"; git log --oneline --graph | head -6

say "VERDICT"
printf '%s\n' "${RESULTS[@]}"
[ $FAILED -eq 0 ] && echo "LAB (subtree toolchain) PASSED" || { echo "LAB (subtree toolchain) FAILED"; exit 1; }
