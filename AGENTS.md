# AGENTS

## Architecture

**Stack**:
1. **Core**: `git worktree` (vendoring mechanism) + `rsync` (syncing mechanism)
2. **Implementation Layers**:
   - **Go (Recommended/Primary)**: Native CLI using `gogs/git-module` and `grsync`, located in `src-go/`.
   - **Just + Fish**: The original implementation in `Justfile.cross`, still fully functional and widely used.
   - **Rust (Experimental / WIP)**: Native CLI in `src-rust/`, being refactored to use `git2` and `duct`.

## Core Components

1. **Native CLIs (`git-cross-rust` / `git-cross-go` preferred)**:
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
- **Integration Coverage**: Every new test must execute against all implementations (Justfile.cross, Go CLI, Rust CLI). Use the `just cross-test <id>` harness and mirror the multi-implementation pattern from tests like `test/019_patch_worktree.sh`.

For known issues and planned enhancements, see [TODO.md](TODO.md).

## Agent Guidelines

### CRITICAL: Complete Implementation Requirement

**When implementing any feature or bug fix:**
1. **ALL THREE implementations MUST be updated** - Justfile.cross, Go (src-go/), and Rust (src-rust/)
2. **NO partial commits** - All implementations must land in the same commit or commit series
3. **Test coverage required** - Each new feature/fix MUST have test coverage in test/XXX_*.sh
4. **All implementations tested** - Tests must verify behavior across Just, Go, and Rust implementations
5. **Command parity maintained** - All implementations must provide identical functionality and behavior

**Workflow:**
- Implement in Justfile.cross first (reference implementation)
- Port to Go (primary production implementation)
- Port to Rust (experimental implementation)
- Create/update test case (test/XXX_*.sh)
- Verify all three implementations pass the same test
- Document in TODO.md and commit message
- Only then commit

### Other Guidelines

- **Consistency**: When adding features, ensure logic parity across `Justfile.cross`, Rust, and Go versions.
- **Command Parity**: All implementations (Just, Go, Rust) **MUST** implement the same set of core commands to ensure a consistent user experience regardless of the implementation layer used. 
- **Tool Hygiene**: Installation and Git alias management MUST be handled through distribution (e.g., `Justfile`), keep binaries focused on functional command implementation.
- **Hygiene**: Always protect the `.git/cross/` directory and ensure hidden worktrees are managed correctly.
- **Reproducibility**: Any state change that affects the environment must be recorded in the `Crossfile`.
- **Portability**: Native implementations should remain self-contained (using libraries where possible, like `grsync` in Go).

## Implementation Details
- **Hidden worktrees**: Stored in `.git/cross/worktrees/`.
- **Sparse checkout**: Only specified paths are checked out to save disk and time.
- **Rsync**: Used for the final sync to the local source tree to ensure physical files exist (unlike submodules).
