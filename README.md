# git-cross 🧬

[![CI](https://github.com/epcim/git-cross/workflows/CI/badge.svg)](https://github.com/epcim/git-cross/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Version](https://img.shields.io/badge/version-0.2.0-blue.svg)](https://github.com/epcim/git-cross/blob/main/CHANGELOG.md)

**Git's CRISPR.** Minimalist approach for mixing "parts" of git repositories using `git worktree` + `rsync`.

## Why git-cross?

| Feature | git-cross | Submodules | git-subrepo |
|---------|-----------|------------|-------------|
| **Physical files** | ✅ Yes | ❌ Gitlinks only | ✅ Yes |
| **Easy to modify** | ✅ Direct edits | ⚠️ Complex | ✅ Direct edits |
| **Partial checkout** | ✅ Subdirectories | ❌ Entire repo | ❌ Entire repo |
| **Upstream sync** | ✅ Bidirectional | ⚠️ Complex | ⚠️ Merge commits |
| **Commit visibility** | ✅ In main repo | ❌ Separate | ✅ In main repo |
| **Reproducibility** | ✅ Crossfile | ⚠️ .gitmodules | ⚠️ Manual |
| **Native CLI** | ✅ Rust | ❌ N/A | ❌ Bash |

## Installation

### Method 1: Rust CLI (Recommended)
The native CLI is the fastest and most ergonomic way to use `git-cross`.
```bash
# Install from source
cargo install --path .

# Configure Git alias
git config --global alias.cross '!git-cross'
```

### Method 2: Go CLI (Native)
If you prefer Go, you can build and install the Go version:
```bash
cd src-go
go install .
```
Then setup the git alias as above.

### Method 3: Just (Vendoring)
You can also include `git-cross` directly in your project's `Justfile`.
```bash
git clone https://github.com/epcim/git-cross.git vendor/git-cross
```
In your `Justfile`:
```just
import? 'vendor/git-cross/Justfile'
```

## Quick Start

```bash
# Setup upstream
git cross use demo https://github.com/example/demo.git

# Vendor a subdirectory
git cross patch demo:docs vendor/docs

# Pull updates
git cross sync

# Check status
git cross status
```

## Core Commands

#### `use` - Add Upstream
```bash
git cross use <name> <url>
```
Adds a remote repository and autodetects the default branch.

#### `patch` - Vendor Directory
```bash
git cross patch <remote>:<path> [local_dest]
```
Creates a sparse-checkout worktree and syncs files locally.

#### `sync` - Pull Updates
```bash
git cross sync [path]
```
Fetches latest changes from upstream and updates local vendored files.

#### `status` - Check Health
```bash
git cross status
```
Shows if files are modified locally, behind upstream, or have conflicts.

#### `list` - Show Patches
```bash
git cross list
```
Displays all configured patches in a table.

#### `push` - Contribute Back (WIP)
```bash
git cross push [path] [--force] [--message "msg"]
```
Syncs local changes back to the worktree, commits, and pushes to upstream.

#### `replay` - Restore State
```bash
git cross replay
```
Re-executes all commands in `Crossfile` to recreate the vendored environment.

## Advanced Features

### Custom Hooks
You can use the `exec` command in your `Crossfile` for post-patching tasks:
```bash
# Crossfile
cross patch demo:src vendor/src
cross exec "npm install && npm run build"
```

### Just Integration
If using `just`, you can override targets to add pre/post hooks:
```just
@cross *ARGS:
    echo "Before..."
    just --justfile vendor/git-cross/Justfile.cross {{ARGS}}
    echo "After..."
```

## How It Works
1. **Worktrees**: Maintains hidden worktrees in `.git/cross/worktrees/`.
2. **Sparse Checkout**: Only checks out the specific directories you need.
3. **Rsync**: Efficiently syncs changes between worktree and your source tree.
4. **Crossfile**: A plain-text record of all active patches for easy sharing.

## License
MIT
