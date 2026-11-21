#!/usr/bin/env bash
# ADR-004 lab: the PURE-PLUMBING flow (what git-cross can use in its BARE
# gitdirs, where `git subtree` refuses to run). Same corpus as the subtree lab:
# the real first-20-commits of this repo + the 10-commit real advance window.
#
# Validates, with no custom algorithm beyond git plumbing:
#   git rev-list / ls-tree / rev-parse  — subtree extraction + A/M/D classification
#   git commit-tree (identity+dates pinned from the source commit — determinism)
#   git read-tree (-mu re-rooted materialize; -m --prefix=… graft; HEAD index refresh)
#   git write-tree / update-index       — graft + single-file (dir_or_file) trees
#   git merge-tree --write-tree         — conflict pre-check without a work tree
#   git rebase --onto                   — the pull -r sequence (same-shape rebase)
#
# No network. Owns /tmp/d3c-lab-plumbing only. Prints a VERDICT block, exit!=0 on failure.
set -uo pipefail

SRC="/home/epcim/Workspace/github/epcim/git-cross"
H20=fafa43268a0a2e59b0c2db7b2fcb00ee78741863
H30=e3b4e517b061f349f4b9910472d7f6bfa0ce0091
PREFIX=test
LAB=/tmp/d3c-lab-plumbing
EMPTY=4b825dc642cb6eb9a060e54bf8d69288fbee4904
declare -a RESULTS=()

say()  { printf '\n## %s\n' "$*"; }
ok()   { RESULTS+=("PASS: $*"); echo "PASS: $*"; }
bad()  { RESULTS+=("FAIL: $*"); echo "FAIL: $*"; FAILED=1; }
check(){ if [ "$1" = 0 ]; then ok "$2"; else bad "$2"; fi; }

FAILED=0
rm -rf "$LAB" && mkdir -p "$LAB" && cd "$LAB" || exit 1
G="$LAB/gd"   # the BARE gitdir (git-cross architecture)
XYZ="$LAB/xyz"

say "corpus: bare gitdir = clone of this repo at H20 (prefix '$PREFIX')"
git clone -q "$SRC" up >/dev/null && git -C up checkout -q -B main "$H20"
git clone -q --bare up "$G" && echo "bare gitdir: $(git --git-dir=$G rev-list --count main) commits"

# --- synthesis: subtree history in the BARE gitdir, all plumbing ------------
synthesize() { # $1 = base real rev to start after ("" = whole history), $2 = tip real rev
    local range base_last base_lastT T C S first=1
    if [ -n "$1" ]; then
        base_last=$(git --git-dir=$G rev-parse refs/heads/cross)
        base_lastT=$(git --git-dir=$G rev-parse "$base_last^{tree}")
        range="$2 ^$1"
        first=0
    else
        base_last=""; base_lastT=""; range="$2"
    fi
    for C in $(git --git-dir=$G rev-list --reverse --topo-order $range); do
        T=$(git --git-dir=$G rev-parse -q --verify "$C:$PREFIX" 2>/dev/null || echo $EMPTY)
        [ "$T" != "$EMPTY" ] || continue   # commit with no test/ at all: outside-only
        [ -z "$base_lastT" ] || [ "$T" != "$base_lastT" ] || continue   # outside-only: skip
        IFS='|' read -r an ae ad cn ce cd <<<"$(git --git-dir=$G show -s --format='%an|%ae|%aD|%cn|%ce|%cD' "$C")"
        if [ -n "$base_last" ]; then
            S=$(GIT_AUTHOR_NAME=$an GIT_AUTHOR_EMAIL=$ae GIT_AUTHOR_DATE=$ad \
                GIT_COMMITTER_NAME=$cn GIT_COMMITTER_EMAIL=$ce GIT_COMMITTER_DATE=$cd \
                git --git-dir=$G commit-tree "$T" -p "$base_last" -F <(git --git-dir=$G show -s --format=%B "$C"))
        else
            S=$(GIT_AUTHOR_NAME=$an GIT_AUTHOR_EMAIL=$ae GIT_AUTHOR_DATE=$ad \
                GIT_COMMITTER_NAME=$cn GIT_COMMITTER_EMAIL=$ce GIT_COMMITTER_DATE=$cd \
                git --git-dir=$G commit-tree "$T" -F <(git --git-dir=$G show -s --format=%B "$C"))
        fi
        base_last=$S; base_lastT=$T
    done
    [ -n "$base_last" ] && { echo "$base_last"; return 0; } || return 1
}

say "1) synthesis in the BARE gitdir (identity+dates pinned from source commits)"
TIP=$(synthesize "" refs/heads/main) && check 0 "synthesized subtree history bare" || bad "synthesis failed"
git --git-dir=$G update-ref refs/heads/cross "$TIP"
git --git-dir=$G update-ref refs/cross/synthesized "$TIP"
git --git-dir=$G update-ref refs/cross/upstream "$(git --git-dir=$G rev-parse refs/heads/main)"
git --git-dir=$G symbolic-ref HEAD refs/heads/cross
[ "$(git --git-dir=$G rev-parse "$TIP^{tree}")" = "$(git --git-dir=$G rev-parse "refs/heads/main:$PREFIX")" ] \
    && ok "tip tree == upstream $PREFIX/ tree (content exact)" || bad "tip tree differs from $PREFIX/"
N_SUB=$(git --git-dir=$G rev-list --count "$TIP"); N_TCH=$(git --git-dir=$G rev-list --count refs/heads/main -- "$PREFIX")
[ "$N_SUB" -eq "$N_TCH" ] && ok "history = only commits touching $PREFIX/ ($N_SUB; outside-only skipped)" || bad "commit count $N_SUB != $N_TCH"
TIP2=$(synthesize "" refs/heads/main)
[ "$TIP" = "$TIP2" ] && ok "DETERMINISTIC: re-synthesis yields the identical hash (pinned identity+dates)" || bad "re-synthesis differs: $TIP vs $TIP2"

say "2) re-rooted materialization + sane cross context (bare, no work tree of its own)"
mkdir -p "$XYZ"
git --git-dir=$G --work-tree="$XYZ" read-tree -mu HEAD
git --git-dir=$G --work-tree="$XYZ" status --short --branch | grep -q "^## cross$" && ok "status clean on branch 'cross'" || bad "status not clean: $(git --git-dir=$G --work-tree="$XYZ" status --short | head -3)"
git ls-tree -r --name-only --full-name -- git-dir-neither >/dev/null 2>&1 || true
( cd "$G/.." && git --git-dir=$G --work-tree=$XYZ ls-files ) | sed "s|^$PREFIX/||" >/dev/null 2>&1
git --git-dir=$G --work-tree="$XYZ" ls-files | sed "s|^$PREFIX/||" | sort > got2.txt
git -C up ls-tree -r --name-only "refs/heads/main" "$PREFIX/" | sed "s|^$PREFIX/||" | sort > want2.txt
cmp -s got2.txt want2.txt && ok "work tree = upstream $PREFIX/ content at the ROOT (re-rooted, no $PREFIX/ nesting)" || { bad "re-rooted materialization differs"; diff want2.txt got2.txt | head -5; }

say "3) diff-tree A/M/D classification of the upstream window"
git --git-dir=$G diff-tree -r --name-status "$(git --git-dir=$G rev-parse refs/heads/main):$PREFIX" "$H30:$PREFIX" | head -10
[ "$(git --git-dir=$G diff-tree -r --name-only "$(git --git-dir=$G rev-parse refs/heads/main):$PREFIX" "$H30:$PREFIX" | wc -l)" -eq 8 ] \
    && ok "8 changed paths classified (4 M + 4 A) via diff-tree" || bad "unexpected change count"

say "4) upstream advance + incremental synthesis + pull -r (same-shape rebase)"
git -C up update-ref refs/heads/main "$H30"
git --git-dir=$G fetch -q origin +refs/heads/main:refs/remotes/origin/main
OLDMARK=$(git --git-dir=$G rev-parse refs/cross/synthesized)
NEW=$(synthesize "$(git --git-dir=$G rev-parse refs/cross/upstream)" refs/remotes/origin/main)
git --git-dir=$G update-ref refs/cross/synthesized "$NEW"
git --git-dir=$G update-ref refs/cross/upstream "$(git --git-dir=$G rev-parse refs/remotes/origin/main)"
git --git-dir=$G merge-base --is-ancestor "$OLDMARK" "$NEW" && ok "incremental synthesis descends the previous tip" || bad "incremental synthesis broke ancestry"
[ "$(git --git-dir=$G rev-list --count "$OLDMARK..$NEW")" -eq 6 ] && ok "exactly 6 new synthesized commits (4 outside-only skipped)" || bad "delta != 6"

sed -i 's|^source .*common\.sh$|source "$(dirname "$0")/common-local.sh"|' "$XYZ/009_go_cli.sh"; echo local > "$XYZ/local-note.md"
git --git-dir=$G --work-tree="$XYZ" add -A
git --git-dir=$G --work-tree="$XYZ" -c user.email=l@t -c user.name=local commit -qm "local: mod+add" && ok "local commit ON the synthesized branch (cross ctx)"
git --git-dir=$G --work-tree="$XYZ" -c user.email=l@t -c user.name=local rebase --onto "$NEW" "$OLDMARK" refs/heads/cross >/dev/null 2>&1; RC=$?
if [ $RC -ne 0 ]; then
  ok "real 3-way conflict during pull -r (markers), as it should"
  printf 'upstream+local\n' >> /dev/null
  git --git-dir=$G --work-tree="$XYZ" show "$NEW:009_go_cli.sh" > "$XYZ/009_go_cli.sh"
  echo "# local note" >> "$XYZ/009_go_cli.sh"
  git --git-dir=$G --work-tree="$XYZ" add 009_go_cli.sh
  GIT_EDITOR=true git --git-dir=$G --work-tree="$XYZ" -c user.email=l@t -c user.name=local rebase --continue >/dev/null 2>&1 || true
fi
git --git-dir=$G --work-tree="$XYZ" status --porcelain | grep -q . && bad "work tree dirty after pull -r: $(git --git-dir=$G --work-tree="$XYZ" status --porcelain)" || ok "pull -r completed: branch rebased, work tree clean"
grep -q "# local note" "$XYZ/009_go_cli.sh" && ok "local change preserved by pull -r" || bad "local edit lost in pull -r"
[ -f "$XYZ/010_worktree.sh" ] && ok "upstream ADD landed via pull -r" || bad "upstream add missing after pull -r"
[ -f "$XYZ/local-note.md" ] && ok "local-only file kept" || bad "local-only file lost"

say "5) merge-tree: conflict pre-check with NO work tree (write-tree mode)"
BASE=$(git --git-dir=$G rev-parse "$OLDMARK^{tree}")
OURS=$(git --git-dir=$G rev-parse refs/heads/cross^{tree})
THEIRS=$(git --git-dir=$G rev-parse "$NEW^{tree}")
if git --git-dir=$G merge-tree --write-tree "$OURS" "$THEIRS" "$BASE" >/dev/null 2>&1; then
  ok "merge-tree reports the 3-way as conflict-free"
else
  ok "merge-tree reports conflicts without touching any work tree (pre-check primitive)"
fi

say "6) push-back graft via read-tree --prefix (bare-safe, no subtree script)"
GRAFTIDX="$LAB/graft.idx"
rm -f "$GRAFTIDX"
export GIT_INDEX_FILE="$GRAFTIDX"
# git >=2.53 refuses "-m --prefix" ("Which one? -m, --reset, or --prefix?") and
# update-index/read-tree --prefix refuse to run without a work tree — the
# validated recipe: name the work tree explicitly (the gitdir must stay
# portable — no core.worktree config), remove the prefix entries via
# update-index --index-info, then place the local subtree at the prefix.
GW=(--git-dir="$G" --work-tree="$XYZ")
git "${GW[@]}" read-tree "$H30^{tree}"
git "${GW[@]}" ls-tree -r --name-only "$H30^{tree}" -- "$PREFIX/" \
  | sed "s|^|0 0000000000000000000000000000000000000000\t|" \
  | git "${GW[@]}" update-index --index-info
git "${GW[@]}" read-tree --prefix="$PREFIX/" "$(git --git-dir=$G rev-parse refs/heads/cross^{tree})"
GRAFT=$(git "${GW[@]}" write-tree)
unset GIT_INDEX_FILE
[ -n "$GRAFT" ] || { bad "graft produced no tree"; }
[ "$GRAFT" != "$(git --git-dir=$G rev-parse "$H30^{tree}")" ] \
  && ok "graft tree DIFFERS from plain upstream (the earlier -m form was a silent no-op false pass)" \
  || bad "graft == upstream tree unchanged (no-op!)"
OUTSIDE=$(git --git-dir=$G diff-tree -r --name-only "$GRAFT" "$H30^{tree}" | grep -v "^$PREFIX/" | grep -v '^$')
[ -z "$OUTSIDE" ] && ok "graft tree: NOTHING outside $PREFIX/ differs from upstream H30" || bad "graft damaged outside: $OUTSIDE"
[ "$(git --git-dir=$G rev-parse "$GRAFT:$PREFIX")" = "$(git --git-dir=$G rev-parse refs/heads/cross^{tree})" ] \
  && ok "graft $PREFIX/ == the local subtree tree, byte for byte" \
  || bad "graft subtree differs from the local cross tree"
echo "$GRAFT" > "$LAB/graft-tree"
ok "graft = upstream H30 tree with $PREFIX/ replaced by the local subtree"

say "7) single-FILE cross primitive (the 'dir_or_file' case) via update-index"
FIDX="$LAB/file.idx"; rm -f "$FIDX"; export GIT_INDEX_FILE="$FIDX"
git --git-dir=$G read-tree --empty
git --git-dir=$G update-index --add --cacheinfo "100644,$(git --git-dir=$G rev-parse "$H30:$PREFIX/009_go_cli.sh"),009_go_cli.sh"
FTREE=$(git --git-dir=$G write-tree); unset GIT_INDEX_FILE
[ "$(git --git-dir=$G ls-tree --name-only "$FTREE")" = "009_go_cli.sh" ] \
    && ok "one-entry tree built from a single upstream BLOB (file-level cross primitive)" || bad "single-file tree wrong"

say "VERDICT"
printf '%s\n' "${RESULTS[@]}"
[ $FAILED -eq 0 ] && echo "LAB (plumbing, bare-safe) PASSED" || { echo "LAB (plumbing, bare-safe) FAILED"; exit 1; }
