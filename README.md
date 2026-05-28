# git-cross

[![CI](https://github.com/epcim/git-cross/workflows/CI/badge.svg)](https://github.com/epcim/git-cross/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Version](https://img.shields.io/badge/version-0.3.0-blue.svg)](https://github.com/epcim/git-cross/blob/main/CHANGELOG.md)

`git-cross` is a small tool for pulling part of one Git repository into another with `git worktree` plus `rsync`.

It is for the cases where you want real files in your tree, not a gitlink, and still want a clean path back upstream.

## Why Use It

`git-cross` is useful when you want to:

- vendor only one subdirectory from another repository
- keep vendored code as normal files in your own repository
- pull upstream updates without converting your repo into a submodule setup
- push changes back to a fork or upstream project without manual worktree plumbing
- let AI tools work on a mounted subfolder instead of your full repository

Compared with submodules or subrepo-style flows, the tradeoff is simple: `git-cross` keeps files physical and visible in your repo, and tracks the upstream relationship separately through hidden worktrees and `Crossfile`.

## Common Use Cases

- Pull `docs/` from an upstream project into `vendor/docs`
- Keep a shared app template in `vendor/template` and customize it locally
- Work on an upstream library inside `vendor/lib` with normal editor tooling
- Let an AI sandbox mount only `vendor/lib` instead of the whole repo
- Publish your local combined result to your own `origin`, while still being able to send a clean PR or MR upstream later

## Status

The repository ships three implementations:

1. Go: primary production implementation
2. Just/Fish: readable reference implementation
3. Rust: experimental parity implementation

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

### Shell Reference

```bash
just install shell
```

### Rust CLI

```bash
just install rust
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
git cross sync vendor/docs
```

## How It Works

`git-cross` keeps four things in sync:

1. Your main repository
2. A hidden worktree for each upstream patch under `.cross/worktrees/`
3. A local physical directory such as `vendor/docs`
4. A `Crossfile` that records how to rebuild the setup

In practice:

- your editor sees normal files
- AI tools can work on normal files
- upstream history stays in the hidden worktree
- `git cross replay` can reconstruct the setup later

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

This is intentionally conservative. `.crossignore` entries are review signals, not a substitute for review before `sync` or `push`.

If you keep secrets or machine-local files in a patched directory, review them explicitly before sending changes upstream.

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

### 2. Send changes back to the upstream project

When you want to contribute upstream-managed changes back:

```bash
git cross diff vendor/app
git cross push vendor/app --message "Fix upstream bug"
```

Recommended pattern:

1. Track a writable fork with `git cross use`.
2. Patch from that fork into your local tree.
3. Keep local-only overlay files out of the upstream contribution.
4. Run `git cross push` for the vendored path.
5. Open a PR or MR from your fork branch to the original upstream project.

This lets your main repo keep its local opinionated result while the upstream contribution stays focused.

## Tutorials

- [Overview](docs/overview.md)
- [Tutorial: Local Overlays And Upstream Contribution](docs/tutorials/local-overlays-and-upstream.md)
- [Tutorial: Whole Upstream Into A Local Directory](docs/tutorials/whole-upstream-into-local-dir.md)
- [Tutorial: Migrate A Private Fork To git-cross](docs/tutorials/migrating-private-fork-to-git-cross.md)
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

### `sync`

```bash
git cross sync [path]
```

Pull upstream changes into the local patched directory.

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

### `push`

```bash
git cross push [path] [--force] [--message "msg"]
```

Sync local changes back into the worktree, commit them there, and push to the upstream remote.

### `replay`

```bash
git cross replay
```

Rebuild the full setup from `Crossfile`.

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
- Rust is parity-oriented and still experimental

Detailed architecture notes live in [docs/overview.md](docs/overview.md).

## License

MIT
