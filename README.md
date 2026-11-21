# git-cross

[![CI](https://github.com/epcim/git-cross/workflows/CI/badge.svg)](https://github.com/epcim/git-cross/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Version](https://img.shields.io/badge/version-0.5.3-blue.svg)](https://github.com/epcim/git-cross/blob/main/CHANGELOG.md)

`git-cross` is a small tool for pulling part of one Git repository into another and keeping it as **real files** in your tree — no submodule, no gitlink, no copying step.

It is for the cases where you want real files in your tree, not a gitlink, and want a simple way to refresh them from upstream.

## Why Use It

`git-cross` is useful when you want to:

- vendor only one subdirectory from another repository
- keep vendored code as normal files in your own repository
- pull upstream updates without converting your repo into a submodule setup
- manually compare your local edits with the upstream state when both have changed
- let AI tools work on a mounted subfolder instead of your full repository

Compared with submodules or subrepo-style flows, the tradeoff is simple: `git-cross` keeps files physical and visible in your repo, and tracks the upstream relationship separately through a per-cross gitdir and `Crossfile`.

## Common Use Cases

- Pull `docs/` from an upstream project into `vendor/docs`
- Keep a shared app template in `vendor/template` and customize it locally
- Work on an upstream library inside `vendor/lib` with normal editor tooling
- Let an AI sandbox mount only `vendor/lib` instead of the whole repo
- Publish your local combined result to your own `origin`

## Status

Version **0.5.3** — the current release (0.5.1/0.5.2 were the breaking scope
split: Go is the only full implementation, the Just/Fish reference carries core
commands only, Rust was deleted; plus the `ls` DIFF and crossed-dir recognition
fixes). The 0.5.0 architecture underneath is unchanged: crosses are
a **standalone gitdir per cross with the work tree inside your repo** — no
migration path; `.cross/` is disposable (`rm -rf .cross && git cross update`).
See [CHANGELOG.md](CHANGELOG.md).

The repository supports two implementations (no longer 1:1 since v0.5.1):

1. **Go** — the primary and ONLY full implementation: every command, production use
2. **Just/Fish** — a CORE-only reference (`use`, `set`, `del`, `ls`, `cfg`/`init`
   and the git passthrough) for prototyping and as a readable code showcase;
   `update`, `resolve`, `wipe`, `comp`, `shell-init`, `cd` and `wt` answer
   `NOT IMPLEMENTED in Justfile version` there

The Rust implementation was deleted from the repository (v0.5.1).
For normal usage, prefer the Go binary.

## Installation

### Go CLI

```bash
just install
```

Manual build (remove a stale vendor dir first; `-mod=mod` for the module path):

```bash
cd src-go && rm -rf vendor
CGO_ENABLED=0 go build -mod=mod -o git-cross-go main.go
git config --global alias.cross "!$(pwd)/src-go/git-cross-go"
```

### Just/Fish Reference

```bash
just install shell
```

## Quick Start

```bash
# 1. Register upstream
git cross use demo https://github.com/example/demo.git

# 2. Materialize one directory locally
git cross set demo:docs vendor/docs

# 3. Commit the vendored files in YOUR repo (they are normal files)
git add vendor/docs && git commit -m "vendor: docs"

# 4. Inspect local state
git cross ls                      # crosses + health (DIFF, upstream SHA)
cd vendor/docs && git cross diff   # upstream-context diff (your edits vs upstream)

# 5. Later: fetch upstream, land it, and re-apply your changes
git cross update vendor/docs
#    collision? resolve it in your repo, then:
git cross resolve --continue
```

## How It Works

`git-cross` connects four things:

1. Your main repository (the patched files are **tracked by it as normal files**)
2. A standalone **bare gitdir** per patch under `.cross/worktrees/<remote>/<patch>/`
   holding the upstream `.git` content (objects, refs, remotes, sparse config, rerere)
3. A crossed directory such as `vendor/docs` — this **is** the upstream work tree
4. A `Crossfile` that records how to rebuild the setup

On disk:

```text
your-repo/
├── Crossfile                          # declarative use/set records
├── .cross/                            # disposable state (gitignored)
│   ├── metadata.json                  # local_path + worktree + gitdir + branch + remote_url
│   └── worktrees/
│       └── <remote>/<patch>/          # BARE gitdir: HEAD, config, objects/, info/sparse-checkout
└── vendor/docs/                       # THE WORK TREE: plain files, no .git, tracked by your repo
```

There is no `.git` file in the crossed directory, no linked worktree, and no rsync:
the work tree lives in your repository, and the upstream `.git` content lives in
`.cross/`.

### The key trick: one directory, two git contexts

The crossed directory has **no `.git` of its own**, so the same files belong
to two repositories at once — which one you talk to depends on how you invoke
git:

| You run (inside `vendor/docs`) | git operates on | Why |
|---|---|---|
| `git status` | **your** repository | no `.git` in the crossed dir → git walks up to your repo root |
| `git cross status` | **upstream** repository | git-cross runs git with `GIT_DIR=<gitdir>` + `GIT_WORK_TREE=<crossed dir>` |

That is the whole mechanism. `git cross <git-cmd>` is plain `git` with two
environment variables set for the child process:

```text
GIT_DIR=.cross/worktrees/<remote>/<patch>       # the bare upstream gitdir
GIT_WORK_TREE=<repo>/<local_path>               # the crossed directory
```

Or as a shell function — this is essentially all `git cross` is inside a
crossed directory:

```bash
xup() {           # "upstream git": git cross <cmd> inside vendor/docs, minus the bookkeeping
  GIT_DIR="$repo/.cross/worktrees/demo/vendor_docs"   # the hidden upstream gitdir
  GIT_WORK_TREE="$repo/vendor/docs"                   # the crossed directory
  exec git "$@"
}
```

To git it looks exactly like standing in a normal clone of upstream whose
working tree is `vendor/docs`: `status`, `diff`, `log`, `add`, `push`,
`pull -r` all operate on **upstream**, while your own repo keeps tracking the
same files as plain blobs. No second checkout exists — the crossed directory
*is* the upstream work tree.

Both repositories keep **independent histories** over the same files, and
nothing is auto-synced between them:

- `git cross add` + `git cross commit` (+ `git cross push`) lands the change
  in **upstream** — your repo still shows the file as modified until you
  commit it there too, with plain `git`.
- `git cross pull -r` (or `git cross update` from anywhere in your repo)
  changes the files on disk — your repo simply sees them as changes to commit.

### Under the hood: what `git cross set` does

`git cross set demo:docs vendor/docs` performs that whole setup in one
command. Stripped of the bookkeeping it is:

```bash
gd=.cross/worktrees/demo/vendor_docs          # 1. hidden home for upstream's .git
git clone --bare https://github.com/example/demo.git "$gd"   #  (full clone by default;
git --git-dir="$gd" config core.sparseCheckout true           #   shallow/partial is opt-in:
echo 'docs/' > "$gd/info/sparse-checkout"                     #   git config cross.depth 1)
GIT_DIR="$gd" GIT_WORK_TREE=vendor/docs \
  git read-tree -mu HEAD                       # 2. materialize the work tree, as plain files
```

Fetch-first, work-tree-second: the clone goes **only** into the hidden gitdir,
then the work tree is written into `vendor/docs/`. A `.git` file is **never
created** in the crossed directory — that is what makes your repo track the
files as normal blobs instead of a submodule.

### Example run

A complete first cycle — register, materialize, edit, update (output captured
from a real run):

```bash
$ git cross use demo https://github.com/example/demo.git
==> Remote demo registered (https://github.com/example/demo.git).

$ git cross set demo:docs vendor/docs
==> Autodetecting default branch...
==> Using branch: main
==> Setting cross demo:main:docs -> vendor/docs
==> Cloning upstream into .cross/worktrees/demo/vendor_docs (bare)...
Cloning into bare repository '.cross/worktrees/demo/vendor_docs'...
==> Cross set successfully.

$ ls vendor/docs/docs            # the crossed dir mirrors the upstream ROOT
guide.md

$ git add vendor/docs            # normal files — tracked by YOUR repo
$ git commit -m "vendor: demo docs"

$ echo "My local tweak." >> vendor/docs/docs/guide.md    # edit with any tool

$ cd vendor/docs
$ git cross status               # UPSTREAM context (GIT_DIR/GIT_WORK_TREE)
On branch main
Changes not staged for commit:
        modified:   docs/guide.md
no changes added to commit (use "git add" and/or "git commit -a")

$ git status --short             # plain git, SAME directory: your repo
 M docs/guide.md

$ git cross diff --stat          # your edits vs upstream HEAD
 docs/guide.md | 1 +
```

Days later, upstream published something new:

```bash
$ git cross update               # from anywhere in your repo
==> Updated vendor/docs

$ git cross ls
==> Configured crosses:
┌────────┬─────────────┬────────────┬────────────┬──────────────────────────────┬────────┬───────┬────────┐
│ REMOTE │ REMOTE PATH │ LOCAL PATH │  WORKTREE  │            GITDIR            │ BRANCH │ DIFF  │  SHA   │
├────────┼─────────────┼────────────┼────────────┼──────────────────────────────┼────────┼───────┼────────┤
│ demo   │ docs        │ vendor/docs │ vendor/docs │ .cross/worktrees/demo/vendor_docs │ main │ Clean │ c0448a9 │
└────────┴─────────────┴────────────┴────────────┴────────────────────────────┴────────┴───────┴────────┘

$ git status --short             # upstream landed, staged, in YOUR repo
A  vendor/docs/docs/extra.md
```

`update` refuses to run over unstaged edits under the crossed path
(`==> WARNING: 'vendor/docs' has modified files; commit them in your repo first`),
and a collision is kept as conflict markers you finish with
`git cross resolve`. Cross never commits for you.

In practice:

- your editor, `git add`, and CI see normal files
- AI tools can work on normal files
- upstream git operations run in the cross's own context:
  `cd vendor/docs && git cross status | log | diff | push | pull -r`
- plain `git` still means *your* repository (that is how you commit patched files)
- `Crossfile` records the `use` and `set` declarations; `git cross update` reads them

Two docs hold the decisions:
`specs/003-gitdir-patches/adr-001-metadata-locations.md` (location fields) and
`adr-002-passthrough-requires-patch.md` (the passthrough needs a patch context).

## Design Notes: Bare Gitdir vs `git worktree`

Why a **standalone bare gitdir per cross** instead of one clone of upstream plus
`git worktree add`? The deciding constraint is the core feature:

> The crossed directory must contain **no `.git`** — only then does the primary
> repo track the patched files as **normal blobs** instead of a gitlink/submodule.

Every alternative that puts `.git` (or a `.git` file) into the crossed directory
is disqualified by that one rule:

| Approach | `.git` in crossed dir? | Files tracked by your repo | Isolation |
|---|---|---|---|
| submodule | yes (its own) | no — gitlink, not blobs | separate repo, init/update dance |
| full clone in `vendor/x` | yes | no — nested repo/gitlink | independent, but never your blobs |
| linked `git worktree` | yes (`.git` **file**) | no — nested repo/gitlink | bound to a full clone of upstream + shared refs |
| **git-cross bare gitdir** | **no** | **yes — plain blobs** | fully standalone gitdir |

A linked `git worktree` also needs a full clone of upstream somewhere inside
your repo and couples every cross to that clone: one shared object store and one
shared refs namespace mean two crosses from the same upstream fight over branch
state, and deleting the main clone orphans the worktrees.

What the gitdir-per-cross design gives up is shared object storage: each cross
keeps its own copy of upstream objects. In exchange every cross is an island —
own objects, own refs, own `rerere` — which is exactly what enables:

- the **same upstream patched into several local directories** with different
  branches, each pair fully independent (`.cross/worktrees/<remote>/<patch>/`)
- different upstream **repos** side by side (one gitdir per cross, trivially)
- `.cross/` being **disposable**: `rm -rf .cross && git cross update` rebuilds
  every cross from `Crossfile`

Disk duplication is the whole trade-off, and it is opt-in mitigable:
`git config cross.depth 1` / `cross.filter blob:none` shrink each gitdir.
Since v0.6 a subdirectory cross's gitdir holds a **synthesized subtree
branch** (its tree IS the upstream subdirectory, re-rooted) plus two
`refs/cross/*` markers and pre-rebase/pre-push guard hooks; the sparse
checkout config of v0.5 is gone (whole-repo crosses never had it).

## Conflict Resolution Memory (`rerere`)

`git-cross` enables Git's **rerere** ("reuse recorded resolution") so that
conflict resolutions survive across updates — you resolve the same update
conflict once, not every time:

- `git cross cfg` (or the `init` alias) turns `rerere.enabled` on and tells you so.
- `git cross set` enables it silently **in the cross's own gitdir**.
- `git cross update` re-ensures it on both sides, so older setups self-heal.

The usual conflicting-update loop — `update` itself replays what it remembers:

```bash
git cross update               # fetch + land + re-apply; conflict stays in your repo
# ... edit the marked files ...
git add <files>
git cross resolve --continue   # then commit
git commit -m "vendor: resolve upstream"
```

The manual alternative, when you want to drive the upstream side yourself:

```bash
cd vendor/app                  # the crossed directory IS the upstream work tree
git cross pull -r              # fetch + rebase against upstream
git cross add <file>
git cross rebase --continue
```

Either way Git records the resolution; when the same conflict reappears, the next
apply replays it (`Resolved '<file>' using previous resolution`).

Notes:

- The setting lives in **two** places: your repository's config (the patched
  files are tracked by it) and **every cross gitdir**. A cross gitdir is a
  standalone repository — it does not inherit your config.
- Recorded resolutions are per-repository: `update`/`resolve` record and replay in
  **your** repo (`<repo>/.git/rr-cache`), while the manual `pull -r` flow records in
  the cross gitdir. Each cross therefore has its own conflict memory on both sides.
- `rerere.autoUpdate` is deliberately **not** enabled. Replayed resolutions are
  applied to the working tree but not staged, so a rebase still stops for
  `git add` + continue. Opt in with `git config rerere.autoUpdate true`.
- `git cross update` is where rerere pays off: the re-apply is a real three-way
  apply in your repo, so a conflict you already resolved is replayed instead of
  asked again.

## Local Custom Files On Top Of Upstream

The common pattern is local-only files next to upstream-managed ones:

```bash
git cross use app https://github.com/example/app.git
git cross set app:src vendor/app

echo "API_KEY=..." > vendor/app/.env        # local-only, next to upstream files
```

**v0.5.0 removed `.crossignore`** (the v0.4 status/diff override filter). Local
extra files are simply untracked-by-upstream files in the crossed directory:

- they never affect `git cross update` (only tracked upstream paths are applied),
- they do not appear in the cross's upstream-context `git cross diff`
  (`git diff` shows tracked changes only),
- they will appear in `git status` of **your** repository, exactly like any other
  new file you did not commit — add them to your `.gitignore` (or commit them
  deliberately) if that matters.

If you keep secrets or machine-local files in a crossed directory, review them
explicitly before publishing.

## Publish To Your Own Repo And Upstream

There are two separate publish flows.

### 1. Publish the combined result to your own `origin`

This is just normal Git in your main repository:

```bash
git add vendor/app
git commit -m "Update vendored app and local overlays"
git push origin main
```

Your own repository stores the final combined result, including local overlay files if you choose to commit them there.

### 2. Manually contribute changes upstream

The crossed directory **is** the upstream work tree, so contributing is just git
in the crossed-directory context:

```bash
xcd vendor/app             # or: gx cd vendor/app  (see shell integration)
git cross diff              # line diff of your copy against upstream HEAD
git cross status            # git status IN THE UPSTREAM context (plain `git` = YOUR repo)
git cross add -p            # stage just your fixes
git cross commit -m "fix: ..."
git cross push              # pushes to the PATCH's upstream, not your repo
```

`git cross status` here is the passthrough — plain `git status` run with the
cross's `GIT_DIR`/`GIT_WORK_TREE`. The cross overview (with DIFF + upstream
SHA) is `git cross ls`, runnable from anywhere in the repo.

Recommended pattern:

1. `cd` into the crossed directory (`xcd vendor/app`).
2. `git cross diff` for a line diff against upstream `HEAD`.
3. Stage and commit only the upstream-worthy changes, then `git cross push`.
4. Keep the rest as your local result: commit it in your own repository with
   plain `git add` / `git commit` (the files are normal repo files).

Directory-level comparison is no longer a cross command: the crossed directory is
already the upstream work tree, so `git cross diff` / `--stat` is the natural
view. See [Directory Comparison](#directory-comparison).

## Tutorials

- [Overview](docs/overview.md)
- [Tutorial: Local Overlays And Upstream Contribution](docs/tutorials/local-overlays-and-upstream.md)
- [Tutorial: Whole Upstream Into A Local Directory](docs/tutorials/whole-upstream-into-local-dir.md)
- [Tutorial: Migrate A Private Fork To git-cross](docs/tutorials/migrating-private-fork-to-git-cross.md)
- [Tutorial: Split One Repo Into A Clean Upstream And A Private Overlay](docs/tutorials/split-repo-into-upstream-and-private.md)
- [Sandbox Kits](sbx-kits/README.md)

## Commands

`git cross --help` groups commands by intent (Go CLI):

```text
Crossed paths/dir operations:
  use         Register an upstream remote in metadata (your git remotes are not touched)
  set         Set a cross directory: vendor an upstream path into your repo (bare gitdir + in-repo work tree)
  del         Delete a cross: gitdir + crossed dir + Crossfile/metadata entries
  cfg         Configure the repo for git-cross: Crossfile + rerere + .gitignore (init kept as alias)
  update      Fetch upstream and land it in the crossed dir, re-applying your changes
  resolve     Finish an update conflict: report unmerged paths, or continue/abort

git cross overview:
  ls          Show all configured remotes and crosses (with DIFF + upstream SHA)
  comp        Print shell completions + wrappers (xcd, gx, cr) to evaluate
  wipe        Remove unused remotes (metadata + gitdirs), or all crosses of a specific remote
  help        Help about any command
```

**Cross never shadows native git.** Any command name that is not a cross command
falls through to the passthrough: `git cross status`, `git cross log`,
`git cross push`, `git cross pull -r` run **git in the cross's upstream context**
when you are inside a crossed directory. Outside one they fail early with a hint —
they never silently operate on your own repository. Use plain `git` for that.

Running `git cross` with no subcommand does not print help. It prints one row
per configured cross to stdout:

```text
$ git cross
vendor/app        .cross/worktrees/app/vendor_app
vendor/lib        .cross/worktrees/lib/vendor_lib
```

The listing is the machine-readable row format used throughout the tool:
when stdout is a terminal the first column is space-padded for readability;
when piped, rows stay `local_path<TAB>gitdir` so
`git cross 2>/dev/null | cut -f1` yields local paths. `==> WARNING:`/`==> ERROR:` lines and hints go to stderr
(status `==>` lines stay on stdout, so pipes carry data only). Use `git cross -h` or `git cross --help` for the grouped
help shown above.

### `use`

```bash
git cross use <name> <url>
```

Register an upstream remote alias in `.cross/metadata.json` (and `Crossfile`).
The URL is verified as reachable. **Your repository's git remotes are not
touched** — upstream remotes live in each cross's gitdir.

Re-running `use` with a **new URL re-points** the remote: the existing
Crossfile line is rewritten (exactly one `use` line per remote name), the
metadata remote and every cross's `remote_url` are updated, and `origin` in
each of that remote's gitdirs is re-pointed — so `update` stops fetching the
retired URL. A Crossfile that declares the same remote name twice (e.g. an old
and a new URL) is a **validation error** in `git cross update`: a remote name
maps to exactly one URL.

Prefer a full re-creation over re-pointing? `git cross wipe <remote>` (gitdirs
+ metadata go, **crossed dirs stay**), then `git cross update` — every cross is
re-adopted from the new URL and the re-adoption prompt offers to preserve local
content (`p`; uncommitted changes are stashed first, `--force` skips the
question).

### `set`

```bash
git cross set <remote>:<branch>:<path> [local_dest]
```

Clone the upstream `.git` content into a standalone bare gitdir at
`.cross/worktrees/<remote>/<local_dest>/`, sparse-filter `<path>`, and materialize
the work tree **in place** at `local_dest` (no copy step).

`<path>` is **the subdirectory**: setting `app:src` into `vendor/app` checks
out the CONTENT of `app`'s `src` at `vendor/app/` directly — no `src/`
prefix inside the crossed dir (v0.6, ADR-004). The gitdir carries a
synthesized subtree branch (original upstream authorship, deterministic —
`git cross log` inside the cross shows only the commits that touched your
subdirectory), so the cross context (`status`, `diff`, `pull -r`, `push`)
stays sane against the re-rooted layout. Whole-repo crosses (`app:.` or
`app:/`) keep the v0.5 behavior: the upstream root, everything included.

Every cross owns its own gitdir, so the same upstream source set into
several local directories is fully independent:

```bash
git cross set app:src vendor/app
git cross set app:src vendor/app-copy   # separate gitdir, separate work tree
```

`set` never overwrites silently: when `local_dest` exists but is not
registered, it refuses with a hint (`refusing to overwrite it (add it to
Crossfile and run: git cross update --force — or remove the directory)`). The
hint names both remedies because `update` only walks `Crossfile`: without a
`set` line, `--force` has nothing to adopt.

Opt in to a smaller clone:

```bash
git config cross.depth 1          # shallow
git config cross.filter blob:none # partial (blobless)
```

### Several subdirectories from one upstream

The standard shape: one `use`, one `set` per subdirectory — declared once in
the `Crossfile` and driven by `git cross update`:

```bash
cross use infra https://forgejo.example/infra/infra.git
cross set infra:main:ipxe      infra/ipxe
cross set infra:main:proxmox   infra/proxmox
cross set infra:v2.0:talos     infra/talos     # another branch, same remote
```

Two crosses may even point at the same upstream path — every cross is fully
independent (own gitdir, own refs, own `rerere`), so `del infra/talos` never
touches `infra/ipxe`, and `rm -rf .cross && git cross update` rebuilds
everything from the `Crossfile`.

What this setup deliberately does **not** do:

- **No shared base clone.** Each cross is a standalone bare gitdir
  (`.cross/worktrees/<remote>/<local_path>/`); a shared object store + shared
  refs namespace is the design git-cross rejects — see
  [Design Notes: Bare Gitdir vs `git worktree`](#design-notes-bare-gitdir-vs-git-worktree).
  The cost is disk duplication per cross; mitigate with `cross.depth` /
  `cross.filter` above.
- **`git cross worktree list` is the passthrough.** It runs `git worktree list`
  against the cross's bare gitdir and prints that one gitdir as `(bare)` —
  crosses are not linked worktrees and `worktree list` will not print multiple
  paths. The crossed directories hold no `.git` at all; that is what lets your
  repo track their files as plain blobs.
- **A cross tracks a branch, not a SHA.** `update` lands the tip of
  `origin/<branch>`; pinning a cross at a tag/commit is not supported (backlog).

**Pull/push contract inside a subdirectory cross (v0.6):** `git cross pull -r`
works (fetch → synthesis → same-shape rebase; real conflicts, rerere,
`rebase --continue`) and `git cross push` delivers ONLY your subdirectory to
upstream via the graft — never anything outside it. Plain `git pull -r` /
`git push` in the cross context are refused by the gitdir's guard hooks with
a hint (they would mix the subtree history with the real upstream); read
commands (`status`/`diff`/`log`/`blame`) and local commits work normally.
Whole-repo crosses keep the plain passthrough for everything. The full
plain-git audit lives in ADR-004.

**Implementation note:** the Just/Fish reference implements whole-repo
crosses only — its `set` refuses subdir crosses with a Go-only hint (the
reference stays simple by design). The Go CLI owns all subtree machinery;
the gitdir hooks still guard plain git through the reference's passthrough on
Go-created crosses.

### Full git functionality, no graft: whole-repo cross + symlink

While the subtree machinery (synthesis, intercepted `pull -r`, graft `push`)
is being verified in practice, the pattern with **zero limitations** — every
git command works exactly as in v0.5 — is to cross the whole repo into a
`vendor/<remote>/<set>/` layout and symlink your local name onto the full
upstream path inside it:

```bash
# one whole-repo cross per SET under vendor/<remote>/ (a set can be a branch,
# a purpose — whatever distinguishes it; independent gitdirs per set)
git cross set mxc:main:. vendor/mxc/cluster-test

# the local name -> the full upstream path inside the cross (relative link:
# its depth is counted from the symlink's OWN directory)
ln -s ../vendor/mxc/cluster-test/demo/cluster-flux mxc-clusters/cluster-test
```

The layout that gives you:

```
vendor/mxc/cluster-test/            ← the whole-repo cross (upstream ROOT)
vendor/mxc/cluster-test/demo/cluster-flux/...   ← the full upstream path
mxc-clusters/cluster-test -> ../vendor/mxc/cluster-test/demo/cluster-flux
```

Verified properties: the cross context resolves **through the symlink**
(`cd mxc-clusters/cluster-test && git cross status` answers the whole-repo
cross), plain `git pull -r` fast-forwards inside it, `push` works, no guard
hooks exist, your repo tracks the cross content as plain blobs plus the
symlink as a symlink blob (commit it, or gitignore the alias) — and the
link **never goes stale**: `update` refreshes the vendor tree, the symlink
always points at the live files. Trade-offs: the whole repo is vendored
(disk + primary tracks everything under `vendor/<remote>/<set>/`), and the
local name is a link rather than a real directory (some tools dislike
symlinks).

**Advanced:** a rerere-replay wind-back (reset your repo + roll the mirror back
to replay a recorded resolution) must now roll back three refs:
`refs/heads/<branch>`, `refs/cross/synthesized/<branch>` and
`refs/cross/upstream/<branch>`.

### `update`

```bash
git cross update [path] [--no-resolve] [--force]
```

Two phases, in this order:

1. **Fetch every patch** into its mirror (`.cross/worktrees/<remote>/<patch>/`).
   Fetching is innocent: it only writes `refs/remotes/origin/<branch>`, never a
   work tree.
2. **Land upstream and re-apply your version** in your repo:
   - **unstaged** changes under the crossed path → refuse
     (`'<path>' has modified files; commit them in your repo first`). Only
     unstaged edits can be lost: the apply merges into your index, so staged
   - **untracked** files the incoming delta would overwrite → refuse early
     (0.6.1): `untracked files would be overwritten by the update` + the
     colliding paths, with the `git add`+commit (or remove) remedy — git's
     own cherry-pick safety surfaced BEFORE any work instead of a raw
     `would be overwritten by merge` error. Purely local untracked files
     (paths upstream never touches) never block an update.
     content (e.g. files `set` just added) is safe.
   - **pending conflict** under the crossed path → skip and tell you to run
     `git cross resolve`.
   - otherwise: upstream lands in the crossed directory and your committed changes
     are re-applied on top, in one three-way apply. Clean → the merged result is
     staged, report `Updated <path>`, and the mirror follows. Collision →
     **kept**: conflict markers plus unmerged paths in *your* repo, and `rerere`
     records/replays the resolution (`.git/rr-cache`).
   - `--no-resolve` lands upstream as-is (upstream wins every collision, no
     markers); your version stays in your history for a later `git cross resolve`.
   - `--resolve` is accepted for symmetry with `--no-resolve` (it is the
     default, and hidden from `--help`).

**Lost `.cross` state.** When a crossed directory exists but its registration
is gone — the whole `.cross/` deleted, or only its gitdir — `update` will not
silently overwrite your files. The same flow heals **pre-0.6 subdir gitdirs**
(0.6.1): a v0.5 sparse-layout mirror has no `refs/cross/*` markers, so the
next `update` drops the stale registration + gitdir (both disposable
`.cross/` state) and runs the re-adoption prompt — one `git cross update` is
the whole 0.5→0.6 migration, and `[p]`/`[y]` preserve or stash your local
content (see below).

- **Go** (the only `update` implementation since v0.5.1) asks:
  `'<abs path>' exists but its .cross state is lost. Re-initialize how?`
  with `[y] re-initialize from upstream (existing dir wiped)` and
  `[p] re-initialize but preserve local (existing dir backed up, then copied
  back)`; a dirty dir prompts `[y] … uncommitted changes stashed first`
  instead. The default is **No** (empty/EOF): the cross is skipped untouched
  and counted in a summary warning (`<n> cross(es) not adopted: not confirmed
  (use --force to adopt without asking).`). `--force` auto-applies the `y`.

Re-adoption deletes a directory, so the wipe is guarded — **uncommitted work
is never destroyed**:

- `[y]` on a **dirty** dir stashes first (`git stash push -u` scoped to the
  path; restore with `git stash apply "stash@{0}"` — the entry is kept as
  the safety net), `[p]` needs no stash (the whole dir is copied back), and
  `--force` on a dirty dir stashes too — it only skips the question. If a
  path is still dirty after stashing, the update refuses outright
  (`still has uncommitted changes after stashing; refusing to delete them`).
- `[p]` (preserve) backs the dir up under `.cross/backup-*/`, re-creates the
  cross from upstream, copies your content back over the fresh tree (local
  wins, files new upstream survive), re-stages and removes the backup; on
  failure the backup is kept and its path is in the error.
- **Declined vs aborted**: a declined cross is skipped and the run continues
  (other crosses still update).
- `--force` on a **healthy** registered cross is a **no-op** — it only appears
  in the lost-state branches and never wipes a registered cross.
- `git cross update <path>` with a declined prompt reports the skip
  (`<n> cross(es) not adopted: …`) and exits 0; the hard error
  `no Crossfile cross found for path: <path>` is reserved for paths genuinely
  absent from `Crossfile`.

Cross never commits for you: after a clean update you commit the staged result as
usual (`git add` / `git commit`).

### `resolve`

```bash
git cross resolve                     # list pending conflicts across all crosses
                                      # (or the one you are standing in); exit 0
git cross resolve [path]              # same, scoped to one cross
git cross resolve --continue [path]   # verify resolved, let the mirror follow
git cross resolve --abort [path]      # crossed dir back to HEAD (upstream stays fetched)
```

With no path outside a crossed directory, `resolve` **lists**:
`Crosses with unresolved conflicts:` plus a count per cross and
`run: git cross resolve <local_path>`, or `No pending conflicts.` — exit 0
either way (it is a report, like `git status`). `--continue`/`--abort` change
state, so with several crosses and no context they are ambiguous: they print
the rows plus `run: git cross resolve --continue <local_path>` and exit 1.

Resolution is ordinary git in your repo: edit the marked files, `git add` them,
`git commit`. `resolve` only reports, gates, and cleans up; it never invents merge
logic and never commits. `--continue` refuses while `git ls-files -u` still lists
paths under the patch.

Because the apply is **one** three-way diff of `BASE..THEIRS` against your `HEAD`,
thirty local changes cost one resolution round, not thirty — the upstream side is
what gets squashed, not your commits.

### `ls`

```bash
git cross ls [--raw] [--no-header]
```

Show configured remotes and crosses. Default output is a table with
`Configured Remotes:` / `Configured crosses:` banners and descriptive column
headers. The crosses table carries the health columns (the old `stat`):
**DIFF** — `Clean`, `Modified`, `Missing Files`, `Missing GD` — and **SHA**,
the short upstream commit the cross has checked out (per gitdir; no fetch).

`--raw` switches to machine-readable output: no table borders and no banners.
When stdout is a terminal, columns are space-padded so they line up; when
piped, rows are plain `TAB`-separated values. `--no-header` omits the header
line in both table and raw mode. In raw mode the section order is fixed — all
remotes first, then all patches:

```text
REMOTE_NAME  REMOTE_URL
REMOTE  REMOTE_PATH  LOCAL_PATH  WORKTREE  GITDIR  BRANCH  DIFF  SHA
```

`LOCAL_PATH` is the user-facing key, `WORKTREE` the crossed directory git operates
on (equal to `LOCAL_PATH` in 0.5.0), and `GITDIR` the bare upstream repository
under `.cross/worktrees/`. Remote rows are sorted by name. In pipes, header rows
are themselves tab-separated, so use `--no-header` in pipelines.

Parsing examples:

```bash
# Local paths only (patch rows have 6 fields, remote rows have 2)
git cross ls --raw --no-header | awk -F'\t' 'NF == 8 { print $3 }'

# Worktree (patch) directories
git cross ls --raw --no-header | awk -F'\t' 'NF == 8 { print $4 }'

# Bare gitdirs (upstream .git content)
git cross ls --raw --no-header | awk -F'\t' 'NF == 8 { print $5 }'

# "<remote>:<branch>" for every patch
git cross ls --raw --no-header | awk -F'\t' 'NF == 8 { print $1 ":" $6 }'

# Remote URLs
git cross ls --raw --no-header | awk -F'\t' 'NF == 2 { print $2 }'
```

A plain `cut` works on the patch rows, but leaves blank lines for the
two-column remote rows:

```bash
git cross ls --raw --no-header | cut -f3 | sed '/^$/d'
```

When nothing is configured, raw mode writes the empty-state message to stderr
so stdout stays a clean pipe.

### `del`

```bash
git cross del <path>
```

Remove one patch: its gitdir, the crossed directory (a visible deletion in your
repository), the `Crossfile` line, and the metadata entry.

### `wipe`

```bash
git cross wipe [remote]
```

- `git cross wipe <remote>` removes the remote record, every cross of that
  remote, and the remote's gitdir directory.
- `git cross wipe` (no argument) offers to remove remotes that no cross uses,
  then sweeps orphaned gitdirs that metadata does not reference.

> v0.4 called this `prune`, 0.5.0 `purge`; now `wipe`. `git cross prune` and
> `git cross purge` fall through to the git passthrough.

### `cd` (hidden from help)

```bash
git cross cd [path]
```

Print the absolute crossed directory — the only thing written to stdout (hints
and errors go to stderr). Run directly, the command only prints a path: a child
process cannot change your shell, which is why `cd`/`wt` are hidden from
`git cross --help`. The real directory change lives in the wrappers:
`xcd [path]` and `gx cd [path]`.

`wt [path]` is a hidden alias of `cd` (kept from <=0.5.0, where it was the
upstream git passthrough — that role now lives only on the bare
`git cross <git-args>` fall-through).

### Shell integration (real `cd`)

A child process cannot change the working directory of the shell that started
it — no CLI can. Tools that appear to do it (yazi, zoxide, autojump) all use
the same pattern: the program prints the destination, and a small **shell
function** captures it and runs `cd` in your shell. `git cross comp`
prints that function pair together with the completion script:

```fish
# fish (~/.config/fish/config.fish, or a file in ~/.config/fish/functions/)
git cross comp fish | source

# shell auto-detected from $SHELL:
git cross comp | source
```

```bash
# bash / zsh (~/.bashrc, ~/.zshrc)
eval "$(git cross comp)"

# or force a shell:
eval "$(git cross comp bash)"
```

That defines these functions, which take the same optional path (and `fzf`
selection) as the commands themselves:

```bash
xcd vendor/app         # cd into the crossed directory
gx cd vendor/app       # same — gx is a shell function, so it CAN cd
gx add ./file          # short alias for git cross
cr log --oneline       # short alias for git cross
```

`git cross cfg` (alias: `git cross init`) prints the matching one-liner for your
`$SHELL` when it creates a `Crossfile`. For an even shorter git-level alias:

```bash
git config --global alias.x '!git cross'    # then: git x add ./file
```

Prefer to install the wrappers by hand? Copy the function into your shell's
function directory (fish) or profile (bash/zsh); they are plain wrappers, not
special builtins:

```fish
# ~/.config/fish/functions/gx.fish
function gx --description 'short alias for git cross (gx cd changes directory)'
    if begin; test (count $argv) -ge 1; and test $argv[1] = cd; end
        set -l rest $argv
        set -e rest[1]
        xcd $rest
    else
        git cross $argv
    end
end
```

```bash
# ~/.bashrc / ~/.zshrc
xcd() { local p; p="$(git cross cd "$@")" || return; [ -n "$p" ] && cd "$p"; }
gx() { if [ "$1" = "cd" ]; then shift; xcd "$@"; else git cross "$@"; fi; }
```

`xcd` is already the short, idiomatic name — `x` as cross (like `git x` and
`gx`), so `xcd` reads as "cross cd". No further aliasing is needed; if the
name ever collides with something in your shell, wrap it instead of renaming
it (`my-xcd() { xcd "$@"; }`).

Keeping stdout path-only is deliberate: it makes the output composable in
scripts (`dir=$(git cross cd vendor/app)`) and safe to capture in a function.

With an explicit path the patch is resolved directly. Without one, `fzf` is
used to select a patch. The picker puts `LOCAL_PATH` first, then
`REMOTE:REMOTE_PATH`, and appends the branch in parentheses only when it is not
`main`; columns are padded so long remote names cannot run into the next field:

```text
  vendor/mxcsrc    mxc-library:src
  vendor/mxcpkg    mxc-library:pkg (feature)
  vendor/docs-src  docs:src
  3/3
──────────────────────────────────────────────
LOCAL_PATH       REMOTE:REMOTE_PATH
Select patch>
```

If `fzf` is not installed, the command prints the available patch rows plus a
hint to `cd` manually, and exits 1.

## Directory Comparison

`compare` (and its `cmp` alias) was **removed in 0.5.0**. In v0.4 it diffed two
directories — a hidden worktree and your copy. In 0.5.0 the crossed directory *is*
the upstream work tree, so there is no second checkout: the comparison is a
normal upstream-context git diff.

```bash
cd vendor/app
git cross diff --stat        # your changes vs upstream HEAD
git cross diff               # the same as a line diff
git cross log --oneline -5   # upstream history
```

Against a different upstream revision, fetch it into the gitdir and diff two
trees explicitly:

```bash
cd vendor/app
git cross fetch origin
git cross diff origin/main -- .
```

`cross.dirdifftool`, its `{left}`/`{right}` placeholders, the built-in
`nvim`/`vim` DirDiff default, and the `DIRDIFF_EXCLUDES` / `DIRDIFF_IGNORE`
variables went with the command. A leftover setting is ignored — remove it with
`git config --unset cross.dirdifftool`.

## Safety Notes

- `remove` and `purge` guard against deleting repository-root contents when a
  patch targets `.`.
- Whole-upstream patches (`remote:.` and `remote:/`) are supported: no sparse
  filter is written and every upstream file is materialized.
- Repository-root local targets (`local_path = "."`) are not supported by `update`.
- The git passthrough requires a crossed directory. Outside one it exits 1 instead
  of running git against your repository (ADR-002).
- `.cross/` is disposable state. Deleting it and running `git cross update`
  rebuilds every cross from `Crossfile`.
- The crossed directory is tracked by your repository. `git cross del` therefore
  shows up as a deletion in your working tree — review before committing.
- `.crossignore` overrides were removed in 0.5.0; local-only files simply stay
  untracked/ignored by your own `.gitignore`.
- `update` never overwrites your committed work: a collision is left as unmerged
  paths + markers in your repo. It does refuse to run over **unstaged** edits, so
  commit (or stash) before updating.
- While a conflict is unresolved, `git add -A` in your repo would stage the
  markers. Resolve first, then stage: `git cross resolve` lists exactly what is
  left.
- `update --no-resolve` takes upstream as-is (upstream wins every collision). Your
  version is not lost — it is still in your history — but the crossed dir no longer
  reflects it; re-run `git cross resolve` after restoring what you want.

## AI Tooling And Skills

This repo already includes agent guidance for AI coding tools:

- shared repo roles in `.agents/`
- Claude-facing entrypoints in `.claude/`
- OpenCode-native skills in `.opencode/skills/`

Current shared roles:

- maintainer
- feature spec writer
- safety reviewer
- regression tester

If you want an AI agent to work only on a vendored subtree, mount just that subtree in a sandbox and keep the main `.git` state on the host.

## Docker `sbx` Starter

This repo includes repo-local starter kits under `sbx-kits/`.

Examples:

```bash
sbx run opencode --kit ./sbx-kits/opencode
sbx run claude --kit ./sbx-kits/claude
```

Why use a kit:

- safer trial path for people who do not want to install a new tool globally first
- reproducible sandbox setup checked into the repository
- easy place to add sandbox-local agent config later

See [sbx-kits/README.md](sbx-kits/README.md) for the structure, starter kits, and intended workflow.

## Architecture Summary

High level:

- One **bare gitdir per patch** under `.cross/worktrees/<remote>/<patch>/` holds the
  upstream `.git` content (objects, refs, remotes, sparse config, rerere).
- The **work tree is the crossed directory inside your repository** — plain files,
  tracked by your repo, no `.git` pointer, no rsync.
- Upstream git runs through `GIT_DIR`/`GIT_WORK_TREE` — the bare `git cross <git-args>`
  fall-through, only from inside a crossed directory (cd/wt are hidden path-printers).
- `.cross/metadata.json` records `local_path`, `worktree`, `gitdir`, `branch` and
  `remote_url` (ADR-001).
- Go is the primary and only full implementation; Just/Fish is the core-only
  prototyping reference (Go-only commands are `NOT IMPLEMENTED` stubs there).
  Rust was deleted (v0.5.1).

Decisions: `specs/003-gitdir-patches/adr-001-metadata-locations.md`,
`adr-002-passthrough-requires-patch.md`. Design notes: [docs/overview.md](docs/overview.md).

## License

MIT
