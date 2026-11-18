> **RENAME-NOTE (post-0.5.0, unreleased):** command names changed after this document
> was written: `patch`→`set`, `remove`→`del`, `set`→`cfg`, `list`→`ls`, `completion`→`comp`;
> `wt <git-args>` was retired (the bare `git cross <git-args>` fall-through is the only
> git passthrough; `wt [path]` is an alias of `cd`). This file is kept as the historical
> v0.5.0 design record — see CHANGELOG.md [Unreleased] for the current command surface.

# v0.5.0 gitdir patches — progress & handoff (session restart)

**Read first:** `AGENTS.md` (repo conventions) → `specs/003-gitdir-patches/plan.md` (design, decisions L1–L8, validated mechanics). This file records current state and the exact remaining stages.

**Working style (user directives):** implement in stages, not all at once · ask to approve before implementing · ask for code review early · user decides major changes · save tokens · avoid repeated failures — stop and ask · Just/Fish first, Go second, tests alongside BOTH implementations.

---

## 1b. Session update — ADR-001 + tests 001–010 green

**New decisions (user, do not re-litigate):**

- **ADR-001** (`specs/003-gitdir-patches/adr-001-metadata-locations.md`): metadata
  records **every** location explicitly — `local_path` (user key), `worktree` (the
  patch dir in the repo; equals `local_path` in 0.5.0), `gitdir` (the bare gitdir).
  All repo-relative. Nothing absolute is stored. `list --raw` patch columns:
  `REMOTE REMOTE_PATH LOCAL_PATH WORKTREE GITDIR BRANCH`.
- **`git cross <native-git-cmd>` outside a patch directory must not silently fall
  back to plain git** — it has no GIT_DIR/GIT_WORK_TREE to configure, so warn early
  and fail (TASK, not yet implemented — see open items).
- **Update/pull workflow:** edit upstream → `cd <patch>` → `git cross pull -r`. Clean
  → passes; conflicting local commits → rebase stops and the user resolves, then
  `git cross add` + `git cross rebase --continue`.
- **Test lookup rule:** never glob `.cross/worktrees/` (no `find -name '<remote>_*'`);
  resolve paths with `jq` on `.cross/metadata.json`.

**Implemented this session:**

| Item | State |
|---|---|
| ADR-001 written; `worktree` field added to Just + Go metadata writes, with a Go read fallback to `local_path` | DONE |
| `list --raw` / table: WORKTREE + GITDIR columns in both implementations | DONE |
| Just `wt` uses fish `$argv` (was `{{args}}` — multi-word args were split) | DONE |
| Go `update <path>`: a preserved (conflicted) patch now counts as processed → exit 0 + review block (Just parity) | DONE |
| Go `compare`: left side (temp export outside the repo) stays absolute; only in-repo paths are rel-ified | DONE |
| `.agents/skills/git-cross-test-update/SKILL.md` — procedure + v0.4→v0.5 assertion mapping | DONE |

**Tests green:** `001 002 003 004 007 009 010 025` (both implementations where applicable).

Test-side changes of note: 001 (metadata not git-remote), 002/003/004/007 (D3 nesting,
`.gitdir`, `stat`, gitdir fetch refspec, `pull -r` flow, whole-repo no-`.git`), 009
(full v2 rewrite; `.crossignore` + legacy `cross.diffTool` + push/fetch-URL sections
removed), 010 (rewritten: cd/wt/passthrough semantics for just **and** go; no longer
opt-in).

## 1. Current state (end of stage 1)

**v0.5.0 core is DONE and tested for both implementations:**

```
SHELL=/bin/bash bash test/025_gitdir_patch.sh
✓ 025_gitdir_patch (stage 1: creation/checkout): PASS (just + go)
```

| File | State |
|---|---|
| `Justfile.cross` | v2: `use`, `patch`, `wt` (git passthrough), `set` (+`init` alias), `stat`, `update`, `compare`, `list`, `cd`, `remove`, `purge`, `completion`/`shell-init`; helpers `_remote_url`, `_patch_gitdir`; removed `_crossignore_*`, old `diff` recipe, `git` recipe, `worktree` alias; `check-deps` no longer requires rsync |
| `Justfile` (root) | `cross *ARGS` wrapper: recipe-exists check via `grep -Eq "^$1([[:space:]]|:)" Justfile.cross`; unknown commands → `wt` passthrough |
| `src-go/main.go` | Fresh v2 rewrite (~1650 lines, cobra): all commands above incl. root passthrough (`DisableFlagParsing` + manual `-h/--version`), `wt` passthrough, metadata v2; deleted sync/push/replay/exec, crossignore, rsync, gogs/git-module, `.git`-mirror diff |
| `src-go/go.mod` | deps now only: fatih/color, olekukonko/tablewriter, spf13/cobra (grsync + gogs dropped via `go mod tidy`) |
| `test/025_gitdir_patch.sh` | Stage-1 test, Just + Go parts; uses `common.sh` helpers (`setup_sandbox`, `ensure_go_bin`) |
| `specs/003-gitdir-patches/plan.md` | Design + decisions + §6.1 stage table (stage 1 DONE) |

Smoke-validated additionally (Go, on leftover sandbox; assertions not yet in a test file): update ff-merge preserving local edits, conflict abort (`'vendor/docs' differs from upstream; local copy preserved (resolve manually: cd vendor/docs; git cross wt rebase refs/remotes/origin/main)`), `stat` (Modified / 1 behind), `remove`, `purge`, `set`/`init` alias, `list --raw`.

### Architecture in one paragraph
`.cross/worktrees/<remote>/<local_path_slashes→underscores>/` is a standalone **bare gitdir** (clone `--bare --branch <b>` + `--depth`/`--filter` opt-in via git config `cross.depth`/`cross.filter`), holding objects/refs/remotes + `rerere.enabled true` + manual sparse config (`core.sparseCheckout true` + `info/sparse-checkout` = `<remote_path>/`). The **work tree is the patch dir inside the primary repo** — materialized by `git --git-dir --work-tree read-tree -mu HEAD`; **no `.git` file** ever exists there, so the primary tracks patch files as normal blobs (validated: mode 100644). All upstream git ops run via env `GIT_DIR=<gitdir> GIT_WORK_TREE=<patchdir>`. No rsync, no linked worktrees, no remotes in the primary repo.

---

## 2. Locked decisions (user-decided; do not re-litigate)

1. **Layout** `.cross/worktrees/<remote>/<local_path_underscored>/` — per-patch standalone bare gitdir, no hash, no shared base, no `worktrees/` nesting (L1–L3).
2. **Pure env-driven** GIT_DIR/GIT_WORK_TREE — relative `core.worktree` is unusable (resolves from invocation CWD, not gitdir — verified); absolute breaks portability. Nothing absolute is stored (L4).
3. **No migration** — delete `.cross/` + rerun `update` from Crossfile (L5).
4. **Prune-first is optional** suggestion only (L6).
5. **ff-merge stays**; non-ff → user rebases manually in upstream ctx; **rerere on BOTH** primary and every gitdir (each gitdir own `rr-cache`) (L7).
6. **Command namespace (L8):** cross commands must not shadow native git subcommands — unknown names fall through to the `wt` passthrough (upstream ctx inside a patch, plain git elsewhere). Renames: `status`→`stat`, `prune`→`purge`, dedicated `diff` dropped (= passthrough `git diff`), `init`→`set` with **`init` preserved as alias** (native `git init` passthrough is chicken-egg impossible). Retired `push/sync/replay/exec` deleted → `git cross push` inside a patch pushes to **upstream**. crosscd/crosswt kept but expected low-usage; crosswt delegates to `cd` (wt is a passthrough now).
7. **wt semantics (user, final):** `git cross wt <git-args...>` = git ops on the patch's upstream worktree; `git cross cd [path]` = cd to patch dir (0.4 cd behavior). There is no user reason to visit `.cross/worktrees/...` paths.
8. **D3 patch semantics:** worktree root = local_path mirrors the **upstream root**; `remote_path` is a sparse filter only (nested: `patch demo:main:docs vendor/docs` → `vendor/docs/docs/*`). Accepted for 0.5.0.
9. **D4 shallow/partial:** opt-in via `git config cross.depth N` / `cross.filter blob:none`; plain full clone default.
10. **D6 remove:** 0.4 parity — removes cross state AND the patch dir (visible deletions in primary).
11. **No backward compatibility** with 0.4 — 0.5.0 is the first usable version.

---

## 3. Gotchas discovered (do not re-learn these)

- **Tests need `SHELL=/bin/bash`** exported (common.sh does it for run-all; direct invocation too).
- **Go build:** `cd src-go && rm -rf vendor && CGO_ENABLED=0 go build -mod=mod -o git-cross-go main.go` (common.sh `ensure_go_bin` already does this).
- **Local test upstreams must use `file://` URLs** — `--depth` is ignored on plain local paths (warning only, still works with file://).
- **`git sparse-checkout` CLI refuses on a bare repo** ("must be run in a work tree") → manual plumbing: `git --git-dir=<gd> config core.sparseCheckout true` + write `<gd>/info/sparse-checkout` with trailing `/` pattern.
- **Work tree dir must exist before `read-tree -mu`** (mkdir first).
- **Bare gitdir porcelain needs the work tree** — always pass both env vars (or `--git-dir --work-tree`); `git -C <gitdir> <porcelain>` fails ("must be run in a work tree").
- **cobra passthrough:** `DisableFlagParsing: true` on `wt` AND root (otherwise `-v`/`--oneline` are eaten as cross flags); root handles `-h`/`--help`/`--version` manually; git exit codes propagated via `exec.ExitError`→`os.Exit`.
- **just wrapper:** internal recipes are `_`-prefixed and start at column 0 — the grep check `^$1([[:space:]]|:)` catches them; **new recipes must also start at column 0** or the wrapper will misroute them to the wt passthrough.
- **`git clone --bare --branch <b>`** is valid and sets HEAD to the branch; `--depth` implies single-branch (fine).
- **Update fetch refspec** must be explicit in the bare gitdir: `git --git-dir=<gd> fetch origin +refs/heads/<b>:refs/remotes/origin/<b>` (bare clones have no tracking refspec).
- **merge --ff-only via env** aborts when the same file changed locally+upstream — everything preserved; local edits on untouched files survive (this IS the preserve behavior; no pre-checks needed).
- **crossfileCommands is strict**: any non-use/patch line errors out. The repo's OWN `Crossfile` still contains a legacy `cross sync` line — **remove it or `git cross update` fails in this repo** (Stage 2 task).
- Sandbox env: fish 4.2.1, just 1.59.0, go 1.27.3, git 2.53.

---

## 4. Stage 2 — full lifecycle test (026) + old test updates

**Stage 2a — write `test/026_gitdir_lifecycle.sh`** (both impls, same `xc`/`exercise` pattern as 025; reuse the trimmed-out sections — they were validated earlier in the 025 full version):
1. update: upstream advance → new file materializes, changed file lands, local edit on untouched file preserved
2. update conflict: same file changed both sides → abort, local preserved, upstream NOT applied; rerere hint present
3. `stat` output: Modified / N behind rows
4. `compare`: set `git config cross.dirdifftool "echo TOOL {left} {right}"` → assert invocation + left is a temp export dir + right is the patch dir (restore config after)
5. `remove`: gitdir + patch dir + Crossfile/metadata entries gone
6. `purge <remote>`: remote record + `.cross/worktrees/<remote>/` gone; `purge` (no arg) interactive confirm path + orphaned-gitdir sweep (create a stray dir under `.cross/worktrees/<remote>/` and assert removal)
7. whole-repo patch variant (`patch demo:main:. vendor/full` → no sparse file, all files materialized)

**Stage 2b — update 0.4-era tests** (they assert old architecture; expected to fail now — update, don't delete):
- `009_go_cli.sh`: worktree paths, `use` adds git remote (v2: metadata), `status`→`stat`, `prune`→`purge`, `diff`→passthrough, `init`→`set`/`init`
- `010_worktree.sh`, `012_sparse_checkout.sh`: `.cross/worktrees/<remote>_<hash>` → `<remote>/<local_path>`; sparse assertions on `info/sparse-checkout`
- `013_real_world.sh`, `014_remove.sh`, `015_prune.sh` (prune→purge), `016_diff_context.sh` + `021` (diff = passthrough inside patch; no `--no-index`), `017`/`020`/`023` (cd/wt/completion/help — wt is passthrough now; `git cross wt` prints nothing — cd covers path printing), `024` (init→set; rerere now also per-gitdir)
- `test/run-all.sh`: add `025` + `026` to discovery if not automatic (NNN_* pattern — likely automatic)
- Update the repo's own `Crossfile` (drop `cross sync`, fix `cross patch git-cross:. vendor/git-cross` line to v2 semantics if desired)
- Run `SHELL=/bin/bash bash test/run-all.sh` and fix fallout until green (Rust tests excluded already)

## 5. Stage 3 — docs & release housekeeping

1. `README.md`: new architecture section (gitdir + in-repo work tree, diagram), usage: `use/patch/update/stat/compare/remove/purge/set/cd`, **`wt` + fallback passthrough** (incl. `git cross push` → upstream), `cross.depth`/`cross.filter` opt-ins, migration note ("rm -rf .cross; git cross update"), drop rsync/rsync-requirement mentions
2. `CHANGELOG.md`: 0.5.0 entry (breaking; command renames table; rsync removed)
3. `VERSION` → 0.5.0; rootCmd Version already "0.5.0"
4. `AGENTS.md`: file map (Justfile.cross recipe list), command table, coverage matrix (worktree→gitdir columns), implementation-details section rewrite (drop rsync/.git-mirror/crossignore paragraphs; add passthrough + env mechanics + gotchas §3 above)
5. `TODO.md`: mark v0.5.0 rollout items done; note open items below

## 6. Open items (post-0.5.0, decide with user)

- **.crossignore support dropped** in v2 (was filtering status/diff). Re-add via pathspec excludes (`git diff -- . ':(exclude)pat'`) or porcelain filtering if still wanted.
- Shell aliases/functions unavailable through the passthrough (gitconfig aliases only) — accepted; deeper fix ("change what actual git cmd is") acknowledged hard, deferred.
- `update` hint block text; `--depth` shorthand? (cross.depth config only for now)
- goreleaser/CI: check `.github/workflows` still build Go correctly (vendor removal + -mod=mod handled by common.sh pattern)
- Consider `git cross doctor` (self-heal: rewrite gitdir gitdir-file/absolute paths if repo moved) — low priority since nothing absolute is stored
- compare default tool still vim/nvim DirDiff (kept); `cross.diffTool` legacy fallback REMOVED (no backward compat) — verify no test uses it

## 7. Verification cheatsheet

```bash
SHELL=/bin/bash bash test/025_gitdir_patch.sh        # stage-1 gate (both impls)
CLEANUP=false SHELL=/bin/bash bash test/025_gitdir_patch.sh   # keep sandbox for manual poking
cd src-go && CGO_ENABLED=0 go build -mod=mod -o git-cross-go main.go && ./git-cross-go --help
just --justfile Justfile.cross --list                # parse check
SHELL=/bin/bash bash test/run-all.sh                 # full suite (after stage 2b)
```

## 1c. ADR-003 — update/resolve conflict handling (implemented)

`update` is now two phases: fetch **all** patches into their mirrors (innocent),
then per patch land upstream in the patch dir and re-apply the user's committed
version on top via one `cherry-pick -n` of a synthesized `BASE..THEIRS` delta
built in the user's repo (objects imported with a local `git fetch`).

- unstaged edits → refuse ("commit them in your repo first"); staged content is merged
- collisions → unmerged paths + markers stay in the user's repo (never overwritten)
- `git cross resolve` → list / `--continue` / `--abort`; the mirror advances only
  once the content landed
- `update --no-resolve` lands upstream as-is (upstream wins, no markers)
- rerere records/replays in `<repo>/.git/rr-cache`; the mirror is never merged into
- `stat` DIFF compares the mapped subtree (`remote_path`) via a throwaway index

Implementation traps found while building it: alternates-based object borrowing
corrupts the user's index (`unable to read tree`) → import instead; `diff-index`
does not refresh a throwaway index (`git diff --quiet HEAD` does); fish
`test -n (empty)` loses the argument; `@recipe` + shebang makes `just` echo the
whole script.

Tests: `src-go/update_resolve_test.go` (5) + `test/026_update_resolve.sh` (both
implementations) + rewritten 009/018/007. Full suite: 21 passes.
