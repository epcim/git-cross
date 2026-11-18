---
name: git-cross-test-update
description: Use when migrating or fixing git-cross test/*.sh files for the v0.5.0 gitdir architecture (bare gitdir + in-repo work tree). Covers the v0.4→v0.5 assertion mapping table, the update procedure, test-running commands, and the gotchas that make tests fail for the wrong reason.
---

# Updating git-cross tests for v0.5.0

Read `AGENTS.md` and `specs/003-gitdir-patches/progress.md` first. This skill is the
mechanical procedure for turning a v0.4-era test green against v0.5.0 **without
changing the behavior under test**.

## 1. Decide: update in place vs rewrite

Keep the test file and its intent. Rewrite only a section whose *behavior was
deliberately retired* (see §4). Never delete a test because it is red.

## 2. The v0.4 → v0.5 assertion mapping

| v0.4 assertion | v0.5 replacement |
|---|---|
| `git remote show \| grep ^name$` (primary got a remote) | `jq` `.remotes[]` in `.cross/metadata.json`; **plus** assert `git remote` does NOT contain it |
| `.cross/worktrees/<remote>_<hash8>/` | `.cross/worktrees/<remote>/<local_path with / → _>/` (bare gitdir: `HEAD`, `config`, `objects/`) |
| `metadata.json .patches[].worktree` = separate worktree dir | `.patches[].worktree` = the **crossed dir**, always equal to `local_path`; `.patches[].gitdir` = the bare gitdir (ADR-001) |
| `metadata.json .patches[].worktree` | `.patches[].gitdir` (field renamed; no `.worktree`, no `.id`) |
| file at `<patch>/<file>` (rsync'd flat copy) | `<patch>/<remote_path>/<file>` — **D3 nesting**: the crossed dir mirrors the upstream ROOT, `remote_path` is only a sparse filter |
| `<patch>/.git` pointer exists / `.git`-mirror dance | no `.git` in the crossed dir at all; `[ ! -e <patch>/.git ]` |
| `just cross status` | `just cross stat` (v0.5 renamed it; `status` is now the **native git passthrough**) |
| `just cross prune` | `just cross purge` |
| `just cross init` | `just cross set` (`init` still works as an alias) |
| `just cross diff <path>` | `git cross diff` **passthrough**: inside the crossed dir = `git diff` vs upstream; outside = plain `git diff` on the primary. No `--no-index`, no dedicated command |
| `rsync -rlcn` / "worktree differs" checks | `GIT_DIR=<gitdir> GIT_WORK_TREE=<patch>` `git status --porcelain`, or `git --git-dir=<gd> rev-list --count HEAD..refs/remotes/origin/<br>` |
| `git -C "$wt" fetch <remote>` | bare gitdir has **no tracking refspec**: `git --git-dir=<gd> fetch origin "+refs/heads/<br>:refs/remotes/origin/<br>"` |
| `git -C "$wt" commit` (0.4 worktree) | `cd <patch> && git cross commit -m ...` (passthrough, upstream ctx) |
| `stat` value `Missing WT` | `Missing GD` (gitdir missing); `Missing Files` = crossed dir missing |
| update advances worktree HEAD while local diverges | superseded by **ADR-003**: `update` lands upstream in the crossed dir and re-applies the user's committed work (one three-way apply); a collision is KEPT as unmerged paths + markers, finished by `git cross resolve --continue` (`--abort` reverts). Only unstaged edits refuse. See `specs/003-gitdir-patches/adr-003-update-conflict-handling.md` |
| `list --raw` header `… LOCAL_PATH GITDIR BRANCH` | `REMOTE REMOTE_PATH LOCAL_PATH WORKTREE GITDIR BRANCH` (ADR-001; `cut -f3` is still `local_path`) |

## 3. Procedure (one test at a time)

1. `rm -rf testdir && SHELL=/bin/bash bash test/NNN_*.sh > /tmp/tNNN.log 2>&1; echo $?`
   Never use `run-all.sh` while iterating (shared `testdir`).
2. Read the **first** failure only. Classify it with the table above.
3. Fix that assertion. Re-run. Repeat. Do not batch-guess several sections.
4. Chained tests (004→002→001, 003→002→001) re-run the whole chain each time —
   budget the runtime, and check the inherited sections first when a later
   section reports a missing file.
5. When a failure is not in the table: reproduce the flow manually in a scratch
   dir (copy `Justfile` + `Justfile.cross` into a fresh `git init`'d repo, make a
   `file://` upstream) before touching the test. A test bug and an
   implementation gap look identical from inside a chained run.

## 4. Retired behavior — rewrite the section, don't chase it

- `.crossignore` / `Override` status state — dropped in v0.5 (open item).
- `.git`-pointer exclusion for whole-repo patches — no pointer exists now.
- `diff --no-index` output shapes (`a/… b/…` against a mirror) — now plain `git diff`.
- shallow/sparse/`read-tree` internals live in the gitdir: assert
  `info/sparse-checkout` (with the trailing `/`) and the `shallow` file.

## 5. Gotchas that make a test fail for the wrong reason

- **`set -o pipefail` + `xc ... | head -1` kills the run silently** (exit 141/SIGPIPE
  from the child, no assertion message). Capture the full output and use
  `assert_contains` instead of truncating with `head`.
- **`assert_grep` / `assert_file_exists` / `assert_dir_exists` resolve against
  `$SANDBOX`**, not the current directory. Inside a subdirectory, pass
  `sub/dir/.cross/metadata.json`.
- **`compare`/`cmp` are REMOVED (0.5.0)** — test 021 was retired with them. Do not
  resurrect directory-diff assertions; `git cross diff` inside a crossed dir is the view.
  A leftover `cross.dirdifftool` config key must be ignored (009/019 assert this).
- (**Historical, pre-removal**) `compare`'s left side was a temp export deleted on return — a test tool had to
  snapshot the directory listing while it runs, not afterwards.
- **`SHELL=/bin/bash` must be exported** for `just` (Justfile.cross sets `SHELL := env("SHELL")`).
- Local fixtures need **`file://` URLs** — `--depth` is ignored (warning only) on plain paths.
- The standalone gitdir has **no git identity**: `git cross commit` there fails with
  `empty ident`. Set it via the passthrough: `git cross config user.email …`,
  `git cross config user.name …`. Never write the user's global config.
- `git cross pull -r` refuses to start with **uncommitted changes** — commit in the
  patch context first when the test needs a real rebase conflict.
- `just cross <native-git-cmd>` **inside** a patch = upstream context; **outside** it
  = plain git on the primary. Assertions that expect upstream data must `cd` in first.
- Multi-word passthrough args are handled: the Just `wt` recipe uses fish `$argv`
  (not `{{args}}` interpolation). If a commit message gets split into a pathspec,
  that regression is back.
- `read-tree` needs the work-tree dir to exist; sparse config is manual
  (`core.sparseCheckout` + `info/sparse-checkout`), because `git sparse-checkout`
  refuses on a bare repo.
- Go binary: `ensure_go_bin` in `test/common.sh` removes stale `src-go/vendor` and
  builds with `-mod=mod`. When building by hand for a probe, write the binary
  somewhere private (`/tmp/...`), not `src-go/git-cross-go`.

## 6. Test-authoring rules for new v0.5 tests

- One `exercise_*()` function per concern; dispatch with `IMPL=just` then
  `IMPL=go` via a small `xc()` helper (see `test/025_gitdir_patch.sh`).
- Assert behavior, not implementation: presence of a gitdir, absence of `.git` in
  the crossed dir, upstream context correctness, `stat` rows, exit codes.
- Prefix a v0.5-specific line with a `# v2:` comment stating the *why* (nesting,
  renamed field, retired mechanism) so the next reader does not "fix" it back.

## 7. Verification gate

```bash
rm -rf testdir
SHELL=/bin/bash bash test/0NN_*.sh        # the test you touched
SHELL=/bin/bash bash test/025_gitdir_patch.sh   # v0.5 stage-1 gate must stay green
SHELL=/bin/bash bash test/run-all.sh      # full suite when the chain is green
```

Report failures with RC first (what happened, what was expected, the evidence),
then the question — per `AGENTS.md` → "Asking Questions & Escalating Problems".
