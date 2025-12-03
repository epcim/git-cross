# AGENTS

## Architecture

**Stack**: `just` (task runner) + `fish` (scripting) + `git worktree` (vendoring mechanism)

## Core Components

1. **`Justfile`**: Entry point for all commands
   - Commands: `use`, `patch`, `sync`, `list`, `status`, `diff-patch`, `push-upstream`, `replay`
   - Uses fish for complex logic (loops, string manipulation, conditionals)
   - Uses bash for simple checks (`check-deps`)

2. **`cross`**: Thin wrapper script for CLI ergonomics
   - Delegates to `just`
   - Sources `.env` for PATH setup

3. **Persistence**: `Crossfile`
   - Auto-records `use` and `patch` commands
   - `replay` command restores configuration

4. **Environment**:
   - `.envrc`: Direnv integration (auto-loads PATH)
   - `.env`: Manual sourcing alternative

## Commands

All commands are accessible via `just cross <command>` or `./cross <command>` wrapper:

### Core Workflow
- **`use <name> <url>`** - Add a remote repository with branch auto-detection
  - Auto-detects default branch (main/master) via `git ls-remote --symref`
  - Fetches detected branch automatically
  - Records in Crossfile

- **`patch <remote:path[:branch]> <local_path> [branch]`** - Vendor a directory from remote
  - Supports `remote:path:branch` syntax (branch in spec)
  - Alternative: `remote:path local_path branch` (branch as 3rd arg)
  - Creates worktree with sparse checkout
  - Syncs to local path with rsync
  - Creates intermediate directories automatically (`mkdir -p`)
  - Updates Crossfile only on success (idempotency)

- **`sync`** - Update all patches from upstream
  - Updates all worktrees via git pull --rebase
  - Checks for uncommitted changes in local paths
  - Prompts before overwriting local modifications
  - Executes `cross exec` commands from Crossfile

- **`replay`** - Re-execute all Crossfile commands
  - Processes each line sequentially
  - Supports `cross` prefix and legacy format
  - Skips comments and empty lines

### Inspection
- **`list`** - Show all configured patches in table format
- **`status`** - Show patch status (diffs, upstream sync, conflicts)
- **`diff [remote:path] [local_path]`** - Compare local vs upstream
  - Auto-infers from current directory if in tracked path

### Contribution
- **`push [remote:path] [local_path]`** - Push changes back to upstream
  - Syncs local to worktree
  - Shows git status
  - Interactive: Run (commit+push), Manual (subshell), Cancel
  - Auto-infers from current directory if in tracked path

### Automation
- **`exec <command>`** - Execute arbitrary shell commands
  - Used for post-hooks in Crossfile
  - Can call user's Justfile recipes
  - Example: `cross exec just posthook`

### Utilities
- **`help`** - Show usage and available commands
- **`check-deps`** - Verify required dependencies (fish, rsync, git, python3, jq, yq)
- **`setup`** - Auto-setup environment (direnv)

### Internal Helpers
- **`_resolve_context`** - Infer remote:path and local_path from CWD
- **`_sync_from_crossfile`** - Process Crossfile for sync operations
- **`update_crossfile`** - Append command to Crossfile (deduplicated)

## Testing

- **`test/verify_examples.sh`**: Basic smoke tests
- **`test/test_all_commands.sh`**: Comprehensive integration tests
  - Tests all commands including inference, interactive modes, stash/pop

## Code Style

1. **Conciseness**: Prefer `test ... && ...` for one-liners
2. **Fish syntax**: Use `if ... end` for complex blocks
3. **Variable naming**: Short, consistent names (`rspec`, `lpath`, `rpath`)
4. **Verbosity**: Minimal echo statements (1-2 per command)
5. **Self-contained**: Each recipe should be independent

## Implementation Notes

- **Hidden worktrees**: Stored in `.git/cross/worktrees/`
- **Sparse checkout**: Only specified paths are checked out
- **Rsync**: Syncs files between worktree and visible directory
- **Argument inference**: Uses `invocation_directory()` to detect context
- **Interactive prompts**: `push-upstream` offers Run/Manual/Cancel modes
