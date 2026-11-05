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
git cross wt vendor/app
git config --global cross.diffTool 'vim "+DirDiff"'
git cross compare vendor/app
```

Recommended pattern:

1. Open the sparse worktree with `git cross wt vendor/app`.
2. Compare it with the local patch using `git cross compare vendor/app` or your own directory diff tool.
3. Manually copy desired changes into the worktree, then commit and push with Git.

This lets your main repo keep its local opinionated result while the upstream contribution stays focused.

## Tutorials

- [Overview](docs/overview.md)
- [Tutorial: Local Overlays And Upstream Contribution](docs/tutorials/local-overlays-and-upstream.md)
- [Tutorial: Whole Upstream Into A Local Directory](docs/tutorials/whole-upstream-into-local-dir.md)
- [Tutorial: Migrate A Private Fork To git-cross](docs/tutorials/migrating-private-fork-to-git-cross.md)
- [Tutorial: Split One Repo Into A Clean Upstream And A Private Overlay](docs/tutorials/split-repo-into-upstream-and-private.md)
- [Sandbox Kits](sbx-kits/README.md)

## Commands

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

Read `Crossfile`, fetch upstream updates, and update each patch. If the local copy differs from the previously installed upstream content, `update` preserves local files, advances the sparse worktree, and prints a comparison command for manual review. Configure a directory diff tool with `git config --global cross.diffTool 'vim "+DirDiff"'`.

### `compare`

```bash
git cross compare [path]
```

Open the configured directory comparison tool for a local patch and its sparse worktree.

### `diff`

```bash
git cross diff [path]
```

Compare local files with the hidden worktree copy.

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
