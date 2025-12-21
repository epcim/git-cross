# AGENTS

## Architecture

**Stack**:
1. **Core**: `git worktree` (vendoring mechanism) + `rsync` (syncing mechanism)
2. **Implementation Layers**:
   - **Rust (Recommended)**: High-performance, portable CLI located in `src-rust/`.
   - **Go**: Native CLI using `gogs/git-module` for cleaner Git interop, located in `src-go/`.
   - **Just + Fish (PoC)**: The original implementation in `Justfile.cross`, still fully functional for vendoring usecases.

## Core Components

1. **Native CLIs (`git-cross-rust` / `git-cross-go`)**:
   - Primary entry points for modern usage.
   - Command parity: `use`, `patch`, `sync`, `list`, `status`, `replay`, `push`, `exec`.
   - Mirror the original shell-based logic but are faster and easier to distribute.

2. **Justfile + Justfile.cross**:
   - `Justfile`: Root task runner delegating to `Justfile.cross` or native CLIs.
   - `Justfile.cross`: The canonical "source of truth" for the original logic.

3. **Persistence**: `Crossfile`
   - Plain-text record of `use` and `patch` commands.
   - Enables `replay` command to reconstruct the entire vendored environment.

4. **Metadata**: `.git/cross/metadata.json`
   - Internal state tracking (worktree paths, remote mappings).
   - Used by CLIs for faster lookups and status reporting.

## Commands

All implementations follow the same command structure:

### Core Workflow
- **`use <name> <url>`**: Register a remote and detect its default branch.
- **`patch <remote:path[:branch]> <local_path>`**: Sync a subdirectory from a remote to a local path using a hidden worktree.
- **`sync [path]`**: pull updates for all or specific patches. Uses rebase for clean history.
- **`replay`**: Re-run all commands found in the `Crossfile`.

### Inspection
- **`list`**: Tabular view of all configured patches.
- **`status`**: Detailed health check (dirty files, upstream divergence, conflicts).
- **`diff`**: Show changes between local files and their upstream source.

### Infrastructure
- **`exec <cmd>`**: Run arbitrary commands for post-patching automation.

## Testing

Testing is modular and targets each implementation:
- **Bash/Fish**: `test/run-all.sh` executes legacy shell tests.
- **Rust**: `test/008_rust_cli.sh` verifies the Rust port.
- **Go**: `test/009_go_cli.sh` verifies the Go implementation.

## Agent Guidelines

- **Consistency**: When adding features, ensure logic parity across `Justfile.cross`, Rust, and Go versions.
- **Hygiene**: Always protect the `.git/cross/` directory and ensure hidden worktrees are managed correctly.
- **Reproducibility**: Any state change that affects the environment must be recorded in the `Crossfile`.
- **Portability**: Native implementations should remain self-contained (using libraries where possible, like `grsync` in Go).

## Implementation Details
- **Hidden worktrees**: Stored in `.git/cross/worktrees/`.
- **Sparse checkout**: Only specified paths are checked out to save disk and time.
- **Rsync**: Used for the final sync to the local source tree to ensure physical files exist (unlike submodules).
