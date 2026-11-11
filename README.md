# git-cross

[![CI](https://github.com/epcim/git-cross/workflows/CI/badge.svg)](https://github.com/epcim/git-cross/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Version](https://img.shields.io/badge/version-0.3.0-blue.svg)](https://github.com/epcim/git-cross/blob/main/CHANGELOG.md)

`git-cross` is a small tool for pulling part of one Git repository into another with `git worktree` plus `rsync`.

It is for the cases where you want real files in your tree, not a gitlink, and want a simple way to refresh them from upstream.

## Why Use It

`git-cross` is useful when you want to:

- vendor only one subdirectory from another repository
- keep vendored code as normal files in your own repository
- pull upstream updates without converting your repo into a submodule setup
- manually compare local edits with the sparse upstream worktree when both have changed
- let AI tools work on a mounted subfolder instead of your full repository

Compared with submodules or subrepo-style flows, the tradeoff is simple: `git-cross` keeps files physical and visible in your repo, and tracks the upstream relationship separately through hidden worktrees and `Crossfile`.

## Common Use Cases

- Pull `docs/` from an upstream project into `vendor/docs`
- Keep a shared app template in `vendor/template` and customize it locally
- Work on an upstream library inside `vendor/lib` with normal editor tooling
- Let an AI sandbox mount only `vendor/lib` instead of the whole repo
- Publish your local combined result to your own `origin`

## Status

The repository supports two implementations:

1. Go: primary production implementation
2. Just/Fish: readable reference implementation

For normal usage, prefer the Go binary.

## Installation

### Go CLI

```bash
just install
```

Manual build:

```bash
cd src-go
go build -o git-cross-go main.go
git config --global alias.cross "!$(pwd)/git-cross-go"
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
git cross patch demo:docs vendor/docs

# 3. Inspect local state
git cross status
git cross diff vendor/docs

# 4. Pull new upstream changes later
git cross update vendor/docs
```

## How It Works

`git-cross` connects four things:

1. Your main repository
2. A hidden worktree for each upstream patch under `.cross/worktrees/`
3. A local physical directory such as `vendor/docs`
4. A `Crossfile` that records how to rebuild the setup

In practice:

- your editor sees normal files
- AI tools can work on normal files
- upstream history stays in the hidden worktree
- `Crossfile` records the `use` and `patch` declarations; `git cross update` reads them to refresh patches

## Local Custom Files On Top Of Upstream

One common pattern is to keep local-only files next to upstream-managed files.

Example:

```bash
git cross use app https://github.com/example/app.git
git cross patch app:src vendor/app

cat > vendor/app/.crossignore <<'EOF'
.env
compose.override.yaml
EOF
```

Rule of thumb:

- a plain basename entry such as `.env` matches that name in any subdirectory under the patch
- a directory entry such as `config` or `config/` matches that directory tree
- a basename glob such as `*.env` also matches anywhere under the patch
- this is intentionally simpler than full `.gitignore` semantics

What this does today:

- `git cross status` shows `Override` for that patch
- `git cross diff vendor/app` prints manual `git diff --no-index ...` commands for the override paths
- your local files stay in place for normal local work

This is intentionally conservative. `.crossignore` entries are review signals, not a substitute for review before updating.

If you keep secrets or machine-local files in a patched directory, review them explicitly before updating.

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

When you want to contribute upstream-managed changes back:

```bash
cd "$(git cross wt vendor/app)"   # or use the crosswt wrapper
git cross compare vendor/app
```

Recommended pattern:

1. Enter the sparse worktree with `git cross wt vendor/app` (or `crosswt vendor/app`).
2. Compare it with the local patch using `git cross compare vendor/app`, or print a console diff with `git cross diff vendor/app`.
3. Manually copy desired changes into the worktree, then commit and push with Git.

`compare` uses the command configured in `cross.diffTool`; see [Directory Diff Tool](#directory-diff-tool-crossdifftool).

This lets your main repo keep its local opinionated result while the upstream contribution stays focused.

## Tutorials

- [Overview](docs/overview.md)
- [Tutorial: Local Overlays And Upstream Contribution](docs/tutorials/local-overlays-and-upstream.md)
- [Tutorial: Whole Upstream Into A Local Directory](docs/tutorials/whole-upstream-into-local-dir.md)
- [Tutorial: Migrate A Private Fork To git-cross](docs/tutorials/migrating-private-fork-to-git-cross.md)
- [Tutorial: Split One Repo Into A Clean Upstream And A Private Overlay](docs/tutorials/split-repo-into-upstream-and-private.md)
- [Sandbox Kits](sbx-kits/README.md)

## Commands

`git cross --help` groups commands by intent:

```text
Repository:
  compare     Open the configured directory comparison tool for a patch
  init        Create an empty Crossfile
  list        Show all configured patches and remotes
  status      Show patch status
  update      Update patches from Crossfile declarations

Inspect & Navigate:
  cd          Print a patch local_path to cd into
  diff        Show changes between local and upstream
  wt          Print a patch worktree to cd into

Patch Lifecycle:
  patch       Create a patch from a remote path
  prune       Remove a remote and all its patches
  remove      Remove a patch
  use         Add a remote repository
```

`compare` also answers to the short alias `git cross cmp`.

Running `git cross` with no subcommand does not print help. It prints one row
per configured patch to stdout, `local_path<TAB>worktree`, and a hint to stderr:

```text
$ git cross
Patches (local_path <TAB> worktree). See: git cross --help
vendor/app	.cross/worktrees/app_1a2b3c4d
```

Rows are the machine-readable listing used throughout the tool: hints and
warnings go to stderr, so `git cross 2>/dev/null | cut -f1` yields local paths.
Use `git cross -h` or `git cross --help` for the grouped help shown above.

### `use`

```bash
git cross use <name> <url>
```

Register an upstream remote alias and detect its default branch.

### `patch`

```bash
git cross patch <remote>:<path> [local_dest]
```

Create or reuse a hidden worktree, sparse-check out the upstream path, and sync it into your local directory.

### `update`

```bash
git cross update [path]
```

Read `Crossfile`, fetch upstream updates, and update each patch.

If the local copy still matches the previously installed upstream content, `update` refreshes it in place. If the local copy has edits, `update` preserves it, advances the sparse worktree to the new upstream state, and prints a single warning:

```text
'vendor/docs' differs from upstream; local copy preserved. Compare with: git cross diff vendor/docs
```

Review the differences and merge manually. Whole-repository patches (`remote:.` and `remote:/`) take part in this check correctly: the worktree's `.git` pointer file is not counted as a local edit, so a clean whole-repo patch is updated instead of warned about.

### `compare`

```bash
git cross compare [path]
git cross cmp [path]
```

Open the configured directory comparison tool between one patch's local copy and its sparse worktree.

`compare` works on exactly one patch. With no path argument it resolves the patch the same way `diff` does: CWD auto-detect first, then an `fzf` selection. If no patch can be resolved (including when `fzf` is missing), it prints the available patches as rows, exits with status 1, and does not dump a usage block.

### `diff`

```bash
git cross diff [path]
```

Print a unified diff between local files and the hidden worktree copy on the console.

With no path argument, the patch is resolved in this order:

1. **CWD auto-detect** — if the current directory is inside a patch's `local_path`, that patch is used (and an auto-detect note is printed).
2. **`fzf` selection** — otherwise, if `fzf` is installed, pick a patch interactively.
3. **Rows + hint** — if `fzf` is not installed, print the available patch rows plus a hint to `cd` into a patch directory or pass a path, and exit 1.

Cancelling the `fzf` selection (Esc) exits 0 without doing anything.

**Behavior change:** `diff` with no path from outside a patch directory used to dump diffs for all patches. It is now interactive.

### Choosing between `diff` and `compare`

Both commands view the same pair of directories — the local copy and the sparse worktree — but they target different workflows:

| | `diff` | `compare` |
|---|---|---|
| Output | unified diff on stdout | the tool from `cross.diffTool` |
| Scope | one patch (from a path, CWD, or `fzf`) | exactly one patch (from a path, CWD, or `fzf`) |
| Unresolved patch | rows + exit 1 | rows + exit 1 |
| Typical use | quick review, scripting, CI | side-by-side editing in an editor |

`.crossignore` overrides are still review signals: `status` shows `Override`, and `diff` prints manual `git diff --no-index ...` commands for the override paths instead of a full diff.

### `list`

```bash
git cross list [--raw] [--no-header]
```

Show configured remotes and patches. Default output is a table with
`Configured Remotes:` / `Configured Patches:` banners and descriptive column
headers.

`--raw` switches to machine-readable output: tab-separated rows, no table
borders, and no banners. `--no-header` omits the header line in both table and
raw mode. In raw mode the section order is fixed — all remotes first, then all
patches:

```text
REMOTE_NAME	REMOTE_URL
REMOTE	REMOTE_PATH	LOCAL_PATH	WORKTREE	BRANCH
```

Each remote with a different fetch and push URL produces one row per URL; both
rows stay in the two-column schema, so the URL field is never decorated with
`(fetch)` / `(push)` suffixes. Remote rows are sorted by name. Header rows are
themselves tab-separated, so use `--no-header` in pipelines.

Parsing examples:

```bash
# Local paths only (patch rows have 5 fields, remote rows have 2)
git cross list --raw --no-header | awk -F'\t' 'NF == 5 { print $3 }'

# Worktree paths
git cross list --raw --no-header | awk -F'\t' 'NF == 5 { print $4 }'

# "<remote>:<branch>" for every patch
git cross list --raw --no-header | awk -F'\t' 'NF == 5 { print $1 ":" $5 }'

# Remote URLs
git cross list --raw --no-header | awk -F'\t' 'NF == 2 { print $2 }'
```

A plain `cut` works on the patch rows, but leaves blank lines for the
two-column remote rows:

```bash
git cross list --raw --no-header | cut -f3 | sed '/^$/d'
```

When nothing is configured, raw mode writes the empty-state message to stderr
so stdout stays a clean pipe.

### `status`

```bash
git cross status
```

Show local diff state, upstream divergence, and conflicts.

### `remove`

```bash
git cross remove <path>
```

Remove one patch and clean up local state.

### `prune`

```bash
git cross prune [remote]
```

Remove unused remotes, stale worktrees, or all patches for one remote.

### `cd` and `wt`

```bash
git cross cd [path]
git cross wt [path]
```

Print the absolute destination path for one patch: `cd` targets the local copy
(`local_path`), `wt` targets the hidden sparse worktree.

The path is the only thing written to stdout; hints and errors go to stderr.
These commands do not start a subshell and do not copy anything to the
clipboard; they print a path for your shell to `cd` into:

```bash
cd "$(git cross cd vendor/app)"      # local copy
cd "$(git cross wt vendor/app)"      # sparse worktree
```

For convenience, add wrappers to your shell configuration.

bash / zsh:

```bash
crosscd() { cd "$(git cross cd "$@")"; }
crosswt() { cd "$(git cross wt "$@")"; }
```

fish:

```fish
function crosscd; cd (git cross cd $argv); end
function crosswt; cd (git cross wt $argv); end
```

A child process cannot change the working directory of the shell that started
it, so the tool cannot `cd` for you. The wrapper does the `cd` in your shell
using the path the tool prints. Keeping stdout path-only also makes the output
composable in scripts (`dir=$(git cross cd vendor/app)`) and editor
integrations.

With an explicit path the patch is resolved directly. Without one, `fzf` is
used to select a patch. If `fzf` is not installed, the command prints the
available patch rows plus a hint to `cd` manually, and exits 1.

## Directory Diff Tool (`cross.diffTool`)

`compare` uses the command configured in `cross.diffTool`. Configure it
globally or per repository:

```bash
git config --global cross.diffTool '<command>'
```

### Template form (current)

If the command contains `{left}` or `{right}`, both placeholders are replaced
before the command is run:

- `{left}` — the patch's path inside the sparse worktree
- `{right}` — the patch's local copy

The substituted paths are **repo-relative**, and the command runs with the
repository root as its working directory. The default, used when
`cross.diffTool` is unset, is:

```text
vim "+DirDiffIgnore='.git' DirDiff {left} {right}"
```

To make it explicit:

```bash
git config --global cross.diffTool "vim \"+DirDiffIgnore='.git' DirDiff {left} {right}\""
```

A custom ignore list passes DirDiff a comma-separated list of names to skip:

```bash
git config --global cross.diffTool "nvim \"+DirDiffIgnore='ves.io,f5fed.com,volterra.us' DirDiff {left} {right}\""
```

In this form the paths are part of the vim `+` command string, which is where
DirDiff reads them. The repository default already ignores `.git`, so the
worktree's `.git` pointer file never appears in the comparison.

### Legacy append form (deprecated)

A command without `{left}` / `{right}` keeps the old behavior: the two absolute
paths are appended as trailing arguments.

```bash
# Deprecated: paths become vim file arguments, not DirDiff arguments.
git config --global cross.diffTool 'vim "+DirDiff"'
```

This form is deprecated because it does not invoke DirDiff correctly. Migrate
to the template form above.

## Safety Notes

- `remove` and `prune` now guard against deleting repo root contents when a patch targets `.`
- whole-upstream patching with `remote:.` and `remote:/` works for vendoring into local directories
- repository-root local targets are not supported by `update` yet
- override markers in `.crossignore` currently affect review surfaces: `status` and `diff`
- if you are experimenting with root-target overlay workflows, treat them as advanced usage and verify results carefully

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

- Just/Fish is the readable behavior reference
- Go is the main production CLI
- Rust source remains in the repository but is not maintained or supported

Detailed architecture notes live in [docs/overview.md](docs/overview.md).

## License

MIT
