# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **P0: Sparse checkout broken on newer Git versions** - `git sparse-checkout set <path>` in `--no-cone` mode no longer reliably checks out directories without trailing `/`. Fixed across all three implementations (Go, Rust, Justfile.cross) by appending `/` to sparse-checkout patterns and using `git read-tree -mu HEAD` instead of bare `git checkout` (which can no-op after `--no-checkout`).
- **P0: Go build "inconsistent vendoring" in CI** - Tests that build the Go binary now remove stale `vendor/` directory and pass `-mod=mod` as a direct flag. Added `src-go/vendor/` to `.gitignore` to prevent accidental commits.
- **Whole-repo patching (`:/` and `:.`)** - `cross patch remote:/` and `cross patch remote:.` now correctly patch the entire upstream repo. Previously `/` was rejected as invalid, and `.` produced an empty worktree because sparse-checkout pattern `./` matched nothing. Fix: `/` is normalized to `.`, and `.` skips sparse-checkout entirely (full checkout).
- **Prune leaves orphaned `.cross/worktrees/` directories** - `cross prune` now scans `.cross/worktrees/` and removes directories not referenced in `metadata.json`. Previously only `git worktree prune` was called, which cleans git's internal registry but not the actual cross-managed directories.
- **test/014_remove.sh robustness** - Go binary is now reused if already built; gracefully skips Go tests when Go toolchain is unavailable.

### Added
- **AI-assisted coding / sandbox workflow documentation** - New README section explaining how git-cross integrates with AI coding tools and container-based development sandboxes (`sbx`, Docker sandbox). Covers subfolder scoping, `Crossfile` reproducibility, and bidirectional sync.
- **test/018_sbx_sandbox.sh** - End-to-end test for the AI sandbox workflow: vendor setup, sandbox isolation (no `.git`), AI file modifications, diff review, upstream push, Crossfile replay, and sync.

## [0.3.0] - 2026-03-28

### Added
- **Context-aware `cross diff`** - Auto-detects current patch from CWD when no path argument given
  - From inside `vendor/lib`: shows only that patch's diff
  - From repo root: shows all diffs (Go/Rust) or requires explicit path (Just/Shell)
  - From subdirectory of a patch: resolves to parent patch
  - Implemented across all three implementations (Just, Go, Rust)
  - New test `test/016_diff_context.sh` with 7 scenarios
- **Expanded test coverage** for Go and Rust CLIs
  - `diff`, `replay`, `remove`, `prune` commands now tested in `test/008_rust_cli.sh` and `test/009_go_cli.sh`
  - Output assertions for `list` and `status` commands
  - Re-enabled `test/006_push.sh` with 4 test scenarios (basic, custom message, named branch, force push)
  - Graceful skip on emulated ARM64 platforms where compiled binaries crash
- **P3 TODO item**: Auto-generate GitHub Release with changelog on version tags

### Fixed
- **Rust `exec` error handling** - Exit status is now properly propagated instead of silently discarded
- **Rust dead code cleanup** - Removed unused `--dry` flag and `shell-words` dependency
- **Go `go.mod` version** - Downgraded from unreleased 1.25.5 to 1.23 (matches CI workflow)
- **Justfile.cross `_resolve_context2`** - Fixed jq `startswith` logic (was checking wrong direction for parent path matching) and fixed `{{path}}` vs `$path` template/variable confusion
- **Justfile.cross CWD propagation** - Added `USER_CWD` env var to preserve caller's working directory through Just's CWD changes, enabling reliable CWD-based patch auto-detection
- **Justfile.cross push warning** - Changed stale "WORK IN PROGRESS" message to accurate "experimental" notice
- **Test 003** - Added missing `mkdir -p` for `src/lib2` upstream directory
- **Test 006** - Fixed Just positional parameter passing (bypasses `*ARGS` empty-string loss)
- **Test 017** - Fixed Go binary path (`git-cross` → `git-cross-go`) and Rust binary path (`release` → `debug`)

### Changed
- **fzf selection UX** - Added `--select-1`, `--exit-0`, and custom `--prompt` to Justfile fzf invocations; added `--header` and `--border` to Go/Rust fzf for consistent, cleaner selection UI

## [0.2.1] - 2026-01-06

### Added
- **`prune` command** - Clean up unused remotes and stale worktrees
  - `cross prune`: Interactive removal of remotes with no active patches
  - `cross prune <remote>`: Remove all patches for a specific remote
  - Excludes 'origin' and 'git-cross' from cleanup
  - Runs `git worktree prune` to clean stale worktrees
  - Implemented across all three implementations (Just, Go, Rust)
  - Full test coverage in `test/015_prune.sh`

### Fixed
- **Sync command file deletion logic** - Only delete tracked files removed upstream
  - Previously would delete ALL files including user's untracked customizations
  - Now uses `git ls-files` to only check tracked files
  - Preserves untracked local files (config files, notes, etc.)
  - Fixes data loss risk for local customizations in patched directories
- **Sync command data preservation** - Complete stash/restore workflow
  - Preserves uncommitted changes during sync operations
  - Handles untracked files properly with `--include-untracked`
  - Detects and removes files deleted upstream
  - Graceful conflict handling with user feedback

### Changed
- **Agent guidelines** - Added critical implementation requirements in AGENTS.md
  - All three implementations must be updated together
  - No partial commits allowed
  - Test coverage required for all features
  - Command parity must be maintained

### Testing
- Enhanced `test/004_sync.sh` with 6 comprehensive scenarios
- Added `test/015_prune.sh` with 3 test scenarios
- All tests pass for Just, Go, and Rust implementations

## [0.2.0] - 2025-12-01

### Added
- `list` command to display all configured patches
- `status` command to show patch status (diffs, upstream divergence, conflicts)
- `push` command (formerly `push-upstream`) with interactive workflow
- `diff` command (formerly `diff-patch`)
- Argument inference for `diff` and `push` (auto-detect context from CWD)
- Auto-update local paths in `sync` command (no need to re-run patch)
- Stash/pop support in `sync` to preserve local modifications
- Comprehensive README with comparison tables and usage guide
- Split test files for easier debugging
- CONTRIBUTING.md with project philosophy and coding standards

### Changed
- Renamed `diff-patch` to `diff`
- Renamed `push-upstream` to `push`
- Variable naming standardization (`rspec`, `lpath`, `rpath`)
- Reduced verbosity in command output
- Updated all examples to use `just cross` pattern
- Enhanced `sync` to automatically rsync changes to local paths

### Fixed
- Argument passing in fish scripts using `{{invocation_directory()}}`
- Git push refspec for worktrees with different branch names
- Test environment path resolution issues

## [0.1.0] - 2024-11-29

### Added
- Initial Justfile implementation
- `use` command to add remote repositories
- `patch` command to vendor subdirectories using hidden worktrees
- `sync` command to update from upstream
- `diff-patch` command to compare local vs upstream
- `replay` command to restore from Crossfile
- Crossfile auto-persistence
- Basic test suite
- OSS preparation (LICENSE, README, examples) replacing the original bash script.
- `cross` wrapper script for backward compatibility and ease of use.
- `diff-patch` command to view differences between local and upstream.
- `push-upstream` command to sync changes back to the hidden worktree for upstream contribution.
- `sync` command to update local patched paths from upstream (first pull to local hiddne worktree)
- `replay` command to restore state from `Crossfile`.
- Automatic `Crossfile` persistence for `use` and `patch` commands.
- Fish shell optimization for complex targets.
- `.env` and `.envrc` for environment configuration.
- Comprehensive test suite in `test/`.

### Changed
- Migrated from pure Bash script to `just` + `fish` architecture.
- Improved "Hidden Worktree" implementation for better reliability.
