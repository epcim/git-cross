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

| Command | Purpose | Arguments |
|---------|---------|-----------|
| `use` | Add remote repository | `<name> <url>` |
| `patch` | Vendor subdirectory | `<remote>:<path> <local> [branch]` |
| `sync` | Update from upstream | None |
| `list` | Show all patches | None |
| `status` | Check patch status | None |
| `diff-patch` | Compare local vs upstream | `[remote:path] [local]` (inferred) |
| `push-upstream` | Push changes upstream | `[remote:path] [local]` (inferred) |
| `replay` | Restore from Crossfile | None |

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
