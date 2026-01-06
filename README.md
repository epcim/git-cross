# git-cross 🧬

[![CI](https://github.com/epcim/git-cross/workflows/CI/badge.svg)](https://github.com/epcim/git-cross/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Version](https://img.shields.io/badge/version-0.2.1-blue.svg)](https://github.com/epcim/git-cross/blob/main/CHANGELOG.md)

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

## What it is not

Git-cross is not a replacement for `git-subrepo` or `git-submodule`. -- It provides an alternative approach and simplifies otherwise manual and complex git workflow behind into intuitive commands.

Git-cross does not directly link external repositories to your main repository. -- It provides separate worktrees for each upstream patch, and help with sync to local repository.

## Implementation status

The project is still in early days and Work In Progress. Just/Golang versions are tested by the author on best-effort basis. Most of the commands and structure of "Crossfile" is already freezed.

The project provides three implementations, with **Go being the primary native version for production use.**

1.  **Go Implementation:** The most robust and feature-complete version. Recommended for general use.
2.  **Justfile/Fish:** The original functional version, great for integration-first workflows.
3.  **Rust Implementation:** Currently **EXPERIMENTAL / WIP**. High-performance alternative being refactored to use native libraries.

## Installation

### Method 1: Go CLI (Recommended)
The Go version is the primary implementation. Use the shortcut or follow manual steps.

**Automation:**
```bash
just install       # Installs Go CLI (default)
just install shell # Installs Just/Shell version
just install rust  # Installs Rust implementation (WIP)
```

**Manual steps:**
1. Download a pre-built binary from [GitHub Releases](https://github.com/epcim/git-cross/releases).
2. Or build locally:
   ```bash
   cd src-go && go build -o git-cross main.go
   # Setup git alias 'cross'
   git config --global alias.cross "!$(pwd)/git-cross"
   ```

### Method 2: Just (Vendoring)
The original functional version. Ideal for projects already using `just`.

**Manual steps (for vendoring in your project):**
1. Clone the repo: `git clone https://github.com/epcim/git-cross.git vendor/git-cross`
2. Install alias: `git config --global alias.cross-just "!just --justfile $(pwd)/vendor/git-cross/Justfile cross"`
3. Import in your `Justfile`: `import? 'vendor/git-cross/Justfile'`

### Method 3: Rust CLI (Experimental / WIP)
High-performance alternative for contributors or library interop testing.

**Manual steps:**
```bash
cd src-rust
cargo install --path .
# Setup git alias 'cross-rust' 
git config --global alias.cross-rust "!git-cross-rust"
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

#### `push` - Contribute Back
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

> **Note**: While `cross` is the standard prefix for `Crossfile` entries (ensuring portability), you can also use `git cross` or `just cross` if you prefer specific implementation behavior.

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

## Architecture

### Technical Implementation Analysis

`git-cross` provides three distinct implementation layers, ensuring the tool is available as a shell-based coordinator or a production-grade native CLI.

| Feature | Go (Primary) | Pure Justfile | Rust (Exp.) | winner |
| :--- | :---: | :---: | :---: | :---: |
| **Philosophy** | Porcelain Wrapper | Shell Coordination | Library-First | **Go** (for balance) |
| **CLI Ergonomics** | Cobra (Standard) | Task-based | Clap (Elegant) | **Rust** |
| **Git Interop** | Binary Wrapper | Direct CLI calls | Native Bindings | **Shell** (for transparency) |
| **Distribution** | Static (Zip/One) | Tool-dependent | Compiled (C-link) | **Go** |
| **Speed to Fix** | Fast | Instant | Medium | **Shell** |

### Verdict: The Multi-Layer Strategy
*   **Go (Primary):** The designated production version. It offers the best balance of distribution ease (zero-dependency binaries) and reliable Git orchestration.
*   **Justfile:** The original source of truth. It remains the fastest way to integrate `git-cross` into existing CI/CD pipelines that already use `just`.
*   **Rust (Experimental):** A high-performance alternative exploring native library integration (`libgit2`). Best for users who require memory safety and a premium CLI experience.

## License
MIT
