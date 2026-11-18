# Overview

## What `git-cross` Actually Does

`git-cross` lets you borrow part of another repository without turning that
repository into a submodule — and without copying files.

Each patch has two independent halves:

- a **standalone bare gitdir** at `.cross/worktrees/<remote>/<patch>/` holding the
  upstream `.git` content (objects, refs, remotes, sparse config, rerere)
- a **work tree inside your repository** at the patch path (`vendor/lib`), plain
  files tracked by your repo like any other file

The bare gitdir is where upstream state lives; the crossed directory is where you
edit. There is no `.git` pointer in the crossed directory, no linked worktree, and
no rsync step — the files you edit *are* the upstream checkout.

## Mental Model

Each patch has four coordinates:

- remote alias, for example `demo`
- upstream branch, for example `main`
- upstream path, for example `src/lib`
- local path, for example `vendor/lib`

```text
upstream repo:path  --(bare gitdir .cross/worktrees/demo/vendor_lib)-->  work tree vendor/lib
```

The upstream path is a **sparse filter only**: the crossed directory mirrors the
upstream *root*, so `patch demo:main:src/lib vendor/lib` materializes
`vendor/lib/src/lib/...` (D3 nesting). Whole-repo patches (`demo:.` or `demo:/`)
get every file.

Git operations split by context:

- **plain `git`** in the crossed directory = your repository (commit the files,
  branch, push to *your* origin)
- **`git cross <git-cmd>`** in the crossed directory = upstream context
  (`GIT_DIR` = the bare gitdir, `GIT_WORK_TREE` = the crossed dir):
  `git cross status | diff | log | push | pull -r`
- outside a crossed directory the passthrough **fails early** rather than acting on
  your repository (ADR-002)

## Main Files And Directories

### `Crossfile`

Declarative list of upstream remotes and patches used by `update`. Only
`cross use` and `cross patch` lines are interpreted — it is data, not a script.

```bash
cross use demo https://github.com/example/demo.git
cross set demo:main:src/lib vendor/lib
```

### `.cross/worktrees/<remote>/<patch>/`

The per-patch **bare gitdir**: upstream `objects/`, `refs/`, `config`, the
`origin` remote, `info/sparse-checkout`, and `rr-cache`. One per patch — two local
directories patching the same upstream path are fully independent.

### `.cross/metadata.json`

The patch registry (ADR-001). Each entry records every location explicitly:

```json
{"remote":"demo","remote_url":"...","remote_path":"src/lib",
 "local_path":"vendor/lib","worktree":"vendor/lib",
 "gitdir":".cross/worktrees/demo/vendor_lib","branch":"main"}
```

All paths are repo-relative; nothing absolute is stored. `worktree == local_path`
in 0.5.0, but they are separate fields because they are separate concepts.

`.cross/` is **disposable**: `rm -rf .cross && git cross update` rebuilds every
patch from `Crossfile`.

## Command Flow

### `use`

Registers a named remote in metadata and detects the default branch. Your
repository's git remotes are **not** touched.

### `set`

Clones upstream into the patch's bare gitdir (full by default; opt into
`cross.depth` / `cross.filter`), writes the sparse filter for the upstream path,
and materializes the work tree in place at the local path.

### `update`

Reads `Crossfile`, fetches **every** patch into its mirror (innocent: refs only),
then per patch lands upstream in the crossed directory and re-applies your committed
changes on top, in one three-way apply (ADR-003). Unstaged edits are refused;
staged content is merged. A collision is **kept**: markers plus unmerged paths in
your repo, finished with `git cross resolve --continue` (or dropped with
`--abort`). `rerere` records and replays in `<repo>/.git/rr-cache`. The mirror
branch advances only once the content landed, so the next run is incremental.
`update --no-resolve` lands upstream as-is (upstream wins every collision).

### `resolve`

`git cross resolve [path]` lists what is left; `--continue` verifies nothing is
unmerged and lets the mirror follow; `--abort` puts the crossed dir back to `HEAD`
(upstream stays fetched). It never invents merge logic and never commits.

### `pull -r` (upstream context)

Edit upstream? `cd` into the patch, then:

```bash
git cross pull -r            # fetch + rebase onto upstream
```

Clean → it just advances. Conflict → the rebase stops; resolve, then
`git cross add <file>` and `git cross rebase --continue`. `rerere` (enabled in
both the repo config and every gitdir) replays a resolution you already made.

### `diff`

No dedicated command: inside a crossed directory `git cross diff` is `git diff`
against upstream `HEAD`. Outside one it fails early (ADR-002).

### `ls` (health columns)

The crosses table carries the health columns (the old `stat`): DIFF
(Clean/Modified/Missing Files/Missing GD) and SHA (short upstream commit
checked out in the gitdir). `git cross status` and `git cross stat` are the
native passthrough now.

### `del` and `wipe`

`del` deletes one cross (gitdir + crossed dir + Crossfile/metadata entries).
`wipe <remote>` drops a remote and all its crosses; bare `wipe` sweeps unused
remotes and orphaned gitdirs. Both guard against deleting repo-root contents.
(`prune` was renamed — `git cross prune` is the native passthrough.)

### Removed in 0.5.0

`compare`/`cmp` (the crossed dir *is* upstream's work tree, so `git cross diff` is
the view), plus `cross.dirdifftool` and `DIRDIFF_EXCLUDES`/`DIRDIFF_IGNORE`;
`push`, `sync`, `replay`, `exec`; rsync; linked worktrees; `.crossignore`.

## Supported Implementations

- **Go** — primary implementation; use this for normal work.
- **Just/Fish** — reference implementation; clearest behavior, fastest iteration.

Rust source remains in the tree but is unsupported and unmaintained.

## Local Overlay Files

A practical pattern is local-only files next to upstream-managed ones:

```text
vendor/app/
  README.md                # upstream-managed
  src/...                  # upstream-managed
  .env                     # local-only
  compose.override.yaml    # local-only
```

They are simply files upstream does not know about: they never affect `update`,
never show up in the upstream-context diff, and behave like any other untracked
file in your repository. `.crossignore` was **removed in 0.5.0**; use your own
`.gitignore` if you need to hide them from `git status`.

## Safety Model

- upstream Git state is separate from your repository (bare gitdir vs work tree)
- local files are plain, editable files
- explicit review over hidden automation: `update` never overwrites local edits
- the passthrough refuses to guess — it requires a patch context
- cleanup commands guard against deleting repo-root contents
- `.cross/` is regenerable, so nothing there needs a backup

## Typical Collaboration Pattern

1. Patch an upstream directory into `vendor/...`.
2. Edit files locally as normal (plain `git add`/`commit` in your repo).
3. Commit the combined result to your own repository.
4. Refresh upstream later with `git cross update`.
5. Contribute upstream: `cd` the patch, `git cross diff`, stage only the
   upstream-worthy changes, `git cross commit`, `git cross push`.

## AI And Sandbox Fit

Vendored content is plain files, so AI tools see a normal tree:

- mount only `vendor/lib` into a sandbox
- keep `.cross/` (the gitdirs) on the host
- review AI changes with `git cross diff` inside the crossed directory

See:

- `sbx-kits/README.md`
- `docs/tutorials/local-overlays-and-upstream.md`

## Repo-Specific Skills

This repository ships role guidance for AI tools:

- `.agents/` for shared role definitions
- `.claude/` for Claude entrypoints
- `.opencode/skills/` for OpenCode-native skills

The main roles are:

- maintainer
- feature spec writer
- safety reviewer
- regression tester
