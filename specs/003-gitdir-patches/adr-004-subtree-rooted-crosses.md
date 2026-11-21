# ADR-004: Subtree-rooted crosses (D3(c))

Status: ACCEPTED (0.6.0) — user decision 2026-11-21: whole-repo crosses keep the
v0.5 machinery unchanged; subdir crosses ship the subtree-rooted special case.
Validated: labs (specs/003-gitdir-patches/lab-*.sh) + test/030 + the suite.
Date: 2026-11-21
Supersedes: the D3(a) "accept nesting" decision recorded in `plan.md` (kept for
v0.5.x); D3(c) is the post-0.5.0 revisit that plan.md reserved.

## Context

D3 asked what `remote_path` means for the crossed directory's layout. v0.5.0
chose **(a) accept nesting**: the work tree mirrors the **upstream root**, and
`remote_path` is only a sparse filter — `set mxc:main:demo/cluster-flux
mxc-clusters/cluster-test` materializes `mxc-clusters/cluster-test/demo/cluster-flux/*`.
Real-world usage showed that is not the mental model: the user expectation is
that the crossed directory IS the upstream subdirectory —

```
set <remote>[:<branch>]:<remote_path> <local_path>   →   <local_path>/ = content of <remote_path>/
```

i.e. `mxc-clusters/cluster-test/` contains `demo/cluster-flux`'s files
directly, with no `demo/` (or any other upstream path prefix) inside.

## Decision

For every cross whose `remote_path != "."`, the crossed directory is rooted at
the upstream subtree (`remote_path`), and the cross's gitdir carries a
**synthesized subtree history** so the cross context (passthrough, `env`,
`status`/`diff`/`log`) stays sane. Whole-repo crosses (`remote_path == "."`)
are unchanged. The no-`.git` rule, the Crossfile format, the metadata schema
(ADR-001) and the passthrough contract (ADR-002) are unchanged.

## Gitdir layout (per cross, `remote_path != "."`)

```
refs/remotes/origin/<b>   real upstream branch          (fetch target, unchanged)
refs/heads/<b>            SYNTHESIZED subtree history   (HEAD points here)
refs/cross/synthesized/<b> last SYNTHESIZED tip (no user commits) — the rebase base
refs/cross/upstream/<b>   real upstream commit the current synthesized tip maps to
info/sparse-checkout      REMOVED (HEAD's tree already IS the subtree)
```

Synthesis (`git rev-list --reverse --topo-order`, per commit):
`T = rev-parse <C>:<rp>` (missing → empty tree `4b825d…`), skip commits whose
`T` equals the previous one (outside-only changes vanish from the log), else
`commit-tree T -p <previous-synthesized>`. Identity is fixed
(`git-cross <git-cross@localhost>`) so synthesized hashes are deterministic.
Fresh `set` synthesizes the whole branch; `update`/`pull` synthesize
incrementally from `refs/cross/upstream/<b>`. Merge parents outside the current
map fall back to the range-base synthesized commit: **content exact, merge
graph approximate** (same compromise class as `git subtree split`).

## Flows

- **set**: bare clone → synthesize → `HEAD = refs/heads/<b>` → `read-tree -mu
  HEAD` materializes the re-rooted work tree in place (no sparse config).
- **update (ADR-003)**: fetch `origin` unchanged; refuse dirty/pending as
  today; the user-repo delta uses the **subtree hashes of the real commits**
  (`rev-parse <base>:<rp>`, `<theirs>:<rp>`) with the existing throwaway-index
  `read-tree --prefix=<P>/` machinery — paths in the user's repo become
  `P/<flattened>` matching the new layout. On success: advance
  `refs/heads/<b>` to the new synthesized tip, set `refs/cross/upstream/<b>`,
  and **refresh the mirror index** (`read-tree HEAD`, index-only — no `-u`:
  the work tree is the user's dir, already landed by the cherry-pick). That
  refresh also fixes a latent v0.5.x staleness: `advanceMirror` today moves the
  ref but never the index, so cross-ctx `git status` after an update showed
  stale-index noise (verified).
- **ls DIFF**: throwaway index + `diff --quiet HEAD` (HEAD's tree is already
  the subtree — no pathspec, no sparse caveat).
- **env / passthrough**: mechanics unchanged; semantics now correct because
  HEAD, index and work tree are all subtree-shaped.
- **`git cross pull -r` in a subdir cross** is intercepted by the passthrough
  (this is what makes it keep working — a plain `rebase` onto the real
  `origin/<b>` would mismatch tree shapes):
  1. `git fetch origin` (real refs, unchanged refspec),
  2. incremental synthesis `refs/cross/upstream/<b>..origin/<b>` → new tip `S`,
     update both `refs/cross/*` markers,
  3. `git rebase --onto S refs/cross/synthesized/<b> refs/heads/<b>` — a
     **same-shape rebase**: your cross-ctx commits replay cleanly onto the new
     subtree tip; conflicts are REAL content conflicts (markers, `rebase
     --continue`, rerere in the gitdir — verified in the prototype). Merge-mode
     `pull` merges `S` instead. Exotic pull args (refspecs, options beyond
     `-r/--rebase`) are refused with a hint.
  This replaces v0.4's model, where re-rooting was done by
  `rsync --delete $wt/$r_path/ $l_path/` from a hidden upstream-rooted linked
  worktree and `pull -r` operated on that hidden tree — there is no git
  variable that remaps a work-tree root to a subdirectory; the remap was the
  rsync. D3(c) gives the same UX with no second work tree and no copy step.
- **`git cross push` in a subdir cross** = the **graft**, validated in the lab
  (git ≥2.53 form — note: `read-tree -m --prefix` is refused with "Which one?"):
  temp index in the gitdir, every command naming the work tree EXPLICITLY
  (portability: never `core.worktree` in config):
  1. `read-tree <origin/<b> tree>` (seed the full upstream tree),
  2. `ls-tree -r --name-only <upstream tree> -- <rp>/` → feed `0 <40×0>\t<path>`
     lines to `update-index --index-info` (remove the upstream rp/ entries),
  3. `read-tree --prefix=<rp>/ <local subtree tree>` (place the local state),
  4. `write-tree` → graft tree (byte-identical outside `<rp>/`),
  5. `commit-tree -p <fetched upstream tip>` → a normal commit, then a normal
     (non-forced) `git push`, marked `CROSS_PUSH_GRAFT=1` so the gitdir's own
     pre-push hook lets it through. Refused when upstream also changed `<rp>/`
     since the last marker ("pull -r first, then push"). An empty local
     subtree = the path vanishes upstream. `git subtree merge` CANNOT be used
     (refuses: unrelated histories — see Validation evidence).
- **Plain `git` under `gxenv` (env vars only)** — the contract:
  - ✅ `status` / `diff` / `log` (subtree history) / `blame` / `show` / `fetch`:
    sane and correct (that is the editor/IDE/lazygit use-case `gxenv` exists
    for) — and `add`/`commit` land on the synthesized branch, which is exactly
    what `pull -r`/`update` rebase and land: MORE coherent than v0.5.x, where
    mirror-branch commits were documented as semi-lost.
  - ⛔ plain `git pull -r`: would rebase subtree commits onto the REAL upstream
    history (shape mismatch). Guard: a **pre-rebase hook** written into the
    gitdir at `set` time aborts with a hint ("subdirectory cross: use `git
    cross pull -r`") and allows only git-cross's own rebases (target =
    `refs/cross/synthesized/<b>`, distinguishable by the hook's `$1`). Bare
    gitdirs run hooks (verified: pre-push fired and aborted a push).
  - ⛔ plain `git push`: would overwrite the upstream branch with the subtree
    history. Guard: a **pre-push hook** aborts with a hint to use `git cross
    push` (the graft). This is strictly SAFER than v0.5.x, where a plain push
    under `gxenv` silently pushed the mirror branch.

## Migration

A user-visible one-time layout move; users re-fetch their subdir crosses
(`del` + `update`, or `wipe <remote>` + `update`). Legacy pre-0.6 gitdirs
(no `refs/cross/upstream/<b>`) surface through the **existing** re-adoption
flow on the next `update` (the `y/p/N` prompt, with local-content preserve)
— no new migration machinery. The primary repo shows the move as delete+add
(`P/<remote_path>/...` → `P/...`) — inherent, committed once by the user.

## Plain-git command audit (subdir-cross context)

The gitdir holds TWO histories — the real upstream (`refs/remotes/origin/*`)
and the synthesized subtree branch — so any command that crosses them is
affected. Inventory:

- ✅ **Sane as-is**: `status` `diff` `log` `blame` `show` `ls-files` `grep`
  `fetch` `stash` `branch` `tag` — all one shape; `log`/`blame` improve
  (subtree-only history).
- ✅ **Work and are the intended flow**: `add` `commit` `rm` `mv` `restore`
  `checkout -- <paths>` `apply` (subtree-shaped patches) `revert` /
  `cherry-pick` of synthesized commits, `rebase -i HEAD~n`, `bisect` (synth
  history), `gc` (the refs keep borrowed objects alive).
- ⛔ **Hook-guarded, fail-fast with a hint**: `pull -r` / `rebase <real-ref>`
  (`pre-rebase` — allows only rebases whose target is under
  `refs/cross/synthesized/`, detectable via the hook's `$1`); `push`
  (`pre-push` → use `git cross push`, the graft). Bare gitdirs run hooks
  (verified).
- ✅ **Naturally refused by git itself**: `merge`/merge-mode `pull` onto the
  real branch ("refusing to merge unrelated histories"), `pull --ff-only`
  (never an ancestor), `git am`/apply of upstream-shaped patches (paths do
  not exist in the re-rooted worktree).
- ⚠️ **Unguardable residual class** (no hook exists): `reset --hard
  origin/<b>`, `checkout origin/<b>`, `checkout -b x origin/<b>` (re-point the
  branch at real history; the crossed dir would re-materialize
  upstream-rooted), `cherry-pick`/`revert` of a REAL upstream commit
  (conflict mess — the correct flow is `git cross update`, which lands exactly
  that commit via the subtree delta), `merge --allow-unrelated-histories`,
  `filter-branch`, `replace`.

**Safety net for the ⚠️ class — lineage check**: `update` (and the `ls` health
view) verify that `refs/heads/<b>` still descends from
`refs/cross/synthesized/<b>` (and that its tree matches
`refs/cross/upstream/<b>:<rp>`); a raw git command that re-pointed the branch
breaks the check, the cross is reported corrupted, and the existing
re-adoption flow (`y/p/N`, `--force`) recovers it. Nothing in the ⚠️ class can
corrupt silently.

## Regressions

1. **History graph approximation** for merge-heavy upstreams (see Synthesis) —
   content exact, log graph simplified around old merges.
2. **Plain `git pull`/`git push` under `gxenv` in subdir crosses** abort with a
   hint (hooks) instead of doing the wrong thing silently — see the env
   contract above. Whole-repo crosses are entirely unaffected (plain pull/push
   keep working there exactly as in v0.5.x).
3. Version bump to **0.6.0** (visible layout change).

`pull -r` is NOT a regression: `git cross pull -r` works via the interception
above (verified end-to-end: fetch → synth → rebase, real conflict markers,
`rebase --continue`, branch restored, clean status), and `git cross push` works
via the proven graft.

## Validation evidence (labs, this repo's real history)

Two self-contained labs (rerunnable: `specs/003-gitdir-patches/lab-subtree-adr004.sh`,
`lab-plumbing-adr004.sh`) run against this repo's first 20 commits (H20) plus a
10-commit real advance window (H30), prefix `test/` (13 files; window = 4 M + 5 A;
6 of 10 commits touch the prefix, 4 outside-only). **Zero rsync anywhere.**

- **Toolchain lab (git subtree)** — all user-visible semantics pass: split is
  deterministic and incremental (re-splits descend), outside-only commits are
  skipped, `subtree add` re-roots the content exactly, the 3-way merge lands
  upstream adds/mods while preserving local edits and local-only files, and
  nothing outside the vendored prefix is ever touched. Two genuine refusals
  are design data: `git subtree` cannot run in a **bare** repo, and a
  `subtree split` of a foreign branch fails unless the prefix is at the current
  HEAD — so splits must run where the prefix exists (an upstream clone).
- **Push-back datum:** grafting the local split back into an upstream clone via
  `git subtree merge` is REFUSED (exit 128, "refusing to merge unrelated
  histories", 0 unmerged paths) because the synthesized split chain and the
  real upstream history share no ancestor and the upstream has no subtree
  bookkeeping (`--rejoin` markers) we could rely on. → The push-back primitive
  is the plumbing graft, not the subtree script.
- **Graft-form datum (git 2.53):** `read-tree -m --prefix` is REFUSED ("Which
  one? -m, --reset, or --prefix?"), and `update-index` / `read-tree --prefix`
  refuse to run without a work tree. The validated recipe names the work tree
  explicitly and removes-then-adds (see the push bullet). The lab's first
  "pass" with `-m --prefix` was a silent NO-OP false positive (the seeded
  index survived the failed command) — the lab now asserts graft ≠ upstream
  and graft:<rp> == local subtree, byte for byte.
- **Plumbing lab (bare-safe, what git-cross will use)** — FULL PASS: synthesis
  in the bare gitdir with identity+dates pinned from the source commits
  (deterministic: identical hash on re-run), tip tree exactly `H:<rp>`, re-rooted
  `read-tree -mu` materialization (clean cross-ctx status), `diff-tree` A/M/D
  classification, incremental synthesis (exactly the prefix-touching commits),
  the `pull -r` sequence (`rebase --onto`) with a REAL 3-way conflict resolved
  via `rebase --continue` (branch restored, work tree clean, local change +
  upstream adds + local-only files all preserved), `merge-tree --write-tree`
  conflict pre-check with no work tree, the **graft** (`read-tree -m --prefix`
  + `write-tree`: upstream H30 tree with `test/` replaced, nothing outside the
  prefix differs), and the single-FILE cross primitive (`update-index
  --cacheinfo` → one-entry tree — the `dir_or_file` case).
- Implementation note from the lab: cross-ctx commits/rebases in the bare
  gitdir need identity handling (the gitdir's own `user.*` config or a `-c`
  fallback) — a bare clone has none.
- **Hook guard demonstrated live** in the exact `xcd` + plain-`git pull -r`
  scenario: the gitdir's `hooks/pre-rebase` (allow targets under `refs/cross/*`,
  abort with a `use: git cross pull -r` hint otherwise) fired and refused the
  rebase *after* the harmless fetch and before any replay damage; the internal
  `rebase --onto <synth> <marker>` passed the hook untouched.

- **Go git-proxy (path rewriting) — RECORDED FALLBACK, not chosen (user
  decision 2026-11-21)**: a Go-side proxy that intercepts EVERY git command in
  the cross context and rewrites paths (strip `<rp>/` on the way in, prepend on
  the way out) would avoid synthesis/graft/hooks entirely. Not chosen because:
  (1) it must translate each git subcommand's path semantics — git's surface is
  huge and subtle mismatches corrupt silently, while the shipped approach uses
  git itself for every transform; (2) it requires proxying ALL git invocations
  (a PATH shim — bypassable by absolute paths/fixed-PATH subprocesses) and
  forfeits `gxenv`/env-based contexts (editors, IDEs, lazygit, `gh`);
  (3) a stateless proxy still needs somewhere to STORE re-rooted history —
  which is the synthesis it was trying to avoid. **Reconsider if**: many exotic
  subcommands must work transparently with re-rooted paths, the hook/
  interception guard UX proves too restrictive in practice, or synthesis cost
  on very large histories becomes a problem (the proxy can be lazier).

## Fallback ladder (if the D3(c) implementation or its tests fail)

The special case is ADDITIVE: whole-repo crosses (`remote:.`) keep the exact
v0.5.x code path (no synthesis, no refs/cross/*, no hooks, no graft — plain
`pull -r`/`push` unchanged). Every fallback below therefore works with the
RELEASED code today, no new machinery needed:

1. **Full-repo cross + user-side re-root** — `git cross set remote:. vendor/<r>`
   (or `remote:main:.`) and re-root with your own tool (rsync/cp the wanted
   subdirectory to the target). The v0.4 model, done by the user.
2. **Symlink — RECOMMENDED until the graft flow is verified in practice** —
   cross the WHOLE repo at its original path layout and symlink the local
   name onto the upstream subpath:
   `git cross set mxc:main:. vendor/mxc-src` +
   `ln -s ../vendor/mxc-src/demo/cluster-flux mxc-clusters/cluster-test`
   (relative link). Verified: the cross context resolves through the symlink,
   plain `pull -r`/`push` work with no hooks, the primary tracks plain blobs
   + the symlink blob. Zero functionality limits; costs: whole repo vendored
   + a link instead of a real dir. Documented as usage in the README
   ("Full git functionality, no graft").
3. **Manual `git subtree`** — the classic toolchain in a scratch clone
   (semantics validated in lab-subtree; the push-back graft must be done by
   plumbing there too).
4. **Stay on v0.5.x** — the D3(a) nested layout (pin the release).

Trigger: if the S2/S4 test stages (below) cannot be made green, stop, keep
whole-repo behavior, and present this ladder — no partial subtree machinery
ships.

## Alternatives rejected

- **Keep D3(a)**: the reported UX is wrong for the vendoring use case.
- **Re-root only the work tree, keep HEAD/index upstream-rooted**: makes
  cross-ctx `status`/`diff` permanently noisy — worse than the bug it fixes.
- **Shared base + linked worktrees**: disqualified by the no-`.git` rule and
  the shared-refs fights (see README "Design Notes"; separate backlog item for
  object sharing).
- **Single snapshot commit instead of synthesized history**: `git log` in the
  cross context becomes a one-entry stub; rejected.

## Test impact (planned)

002/003/004/007/009/012 (sparse plumbing assertions become no-sparse +
synthesized-HEAD assertions)/016/018/023/025/026/029 + a new test for
synthesis (outside-only commits skipped), re-rooted layout, cross-ctx
status/diff/log sanity, incremental update, and the migration prompt.
`pull -r` tests (004/024) move to whole-repo crosses.
