# Overview

## What `git-cross` Actually Does

`git-cross` lets you borrow part of another repository without turning that repository into a submodule inside yours.

It does that by keeping:

- a hidden worktree with real upstream Git state
- a local copied directory with normal files in your repo
- a `Crossfile` that records how the setup was created

The local directory is what you edit. The sparse worktree holds the upstream version for updates and manual comparison.

## Mental Model

Each patch has four coordinates:

- remote alias, for example `demo`
- upstream branch, for example `main`
- upstream path, for example `src/lib`
- local path, for example `vendor/lib`

You can think of one patch as:

```text
upstream repo:path <-> hidden worktree:path <-> local directory
```

## Main Files And Directories

### `Crossfile`

Declarative list of upstream remotes and patches used by `update`.

Example:

```bash
cross use demo https://github.com/example/demo.git
cross patch demo:main:src/lib vendor/lib
```

### `.cross/worktrees/`

Hidden worktrees keyed by remote plus hash.

They hold upstream Git state and make `update` and manual comparison possible without turning your vendored directory into another Git repository.

### `.cross/metadata.json`

Internal patch registry.

It records the relationship between remote path, local path, worktree path, and branch.

## Command Flow

### `use`

Adds a named remote and detects the default branch.

### `patch`

Creates or reuses a hidden worktree, sparse-checks out the requested upstream path, and syncs it into the local directory.

### `update`

Reads `Crossfile`, fetches each upstream, and fast-forwards its sparse worktree. It installs files locally only when the local copy still matches the previously installed version. If local edits exist, it preserves the local directory, leaves the refreshed upstream in the worktree, and prints a manual comparison command.

### `compare`

Opens the configured directory diff tool for the local path and its sparse worktree. Default: `nvim` when installed else `vim`, invoked as `"+let g:DirDiffExcludes = '.git'" "+DirDiff {left} {right}"`. Override with `git config --global cross.diffTool '<command> {left} {right}'`.

### `diff`

Compares local files with the hidden worktree copy.

### `status`

Summarizes local modifications, upstream ahead/behind state, and conflict markers.

### `remove` and `prune`

Remove patch metadata, clean worktrees, and avoid unsafe deletion of repo-root content.

## Supported Implementations

### Go

Primary implementation.

Use this if you want the main supported binary.

### Just/Fish

Reference implementation.

Use this when you want the clearest behavior or fastest iteration inside the repo.

## Local Overlay Files

One practical pattern is to keep local-only files next to upstream-managed files.

Example:

```text
vendor/app/
  README.md                # upstream-managed
  src/...                  # upstream-managed
  .env                     # local-only
  compose.override.yaml    # local-only
  .crossignore
```

With:

```text
.env
compose.override.yaml
```

Current shipped behavior:

- `status` shows `Override`
- `diff` prints manual compare commands for those override paths

This gives you a visible review surface without pretending that local-only files are upstream content.

## Safety Model

`git-cross` is built around a few conservative ideas:

- keep upstream Git state separate from your main repo
- keep local files editable as plain files
- prefer explicit review over hidden automation around local-only files
- avoid deleting repo-root contents during cleanup commands

Important current boundary:

- override markers are currently a review aid in `status` and `diff`
- if local changes exist, `update` preserves them and asks you to review the local copy against the refreshed worktree

## Typical Collaboration Pattern

1. Patch an upstream directory into `vendor/...`
2. Edit files locally as normal
3. Commit the combined result to your own repo
4. Refresh upstream changes later with `update`
5. Manually compare and copy any desired contribution into the worktree, then use Git there

## AI And Sandbox Fit

`git-cross` works well with AI tools because vendored content is plain files.

That means you can:

- mount only `vendor/lib` into a sandbox
- keep `.git` and hidden worktrees on the host
- review AI changes with `git cross diff` and `git cross compare`

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
