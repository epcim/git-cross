# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.2] - 2026-01-22

### Added
- **Independent worktree support** across Just, Go, and Rust implementations
  - Automatically resolves the shared `.git` directory when running from `git worktree` checkouts
  - Honors `CROSSDIR` / `METADATA` environment overrides for automation and tests
  - Synchronizes metadata and worktrees into the primary repository rather than the linked worktree
- **Historical coverage** for worktree usage via `test/019_patch_worktree.sh`, executed for all implementations

### Fixed
- `git cross patch` (Go/Rust) now builds worktree paths from the shared git directory instead of assuming `.git/`
- `Justfile.cross` sync, diff, and push targets normalize paths to absolute locations, eliminating rsync failures inside worktrees

### Documentation
- README highlights worktree support and environment overrides introduced in v0.2.2
- Updated release instructions and agent docs to reference v0.2.2

### Testing
- Reworked `test/019_patch_worktree.sh` to provision branches safely, reuse helper utilities, and validate all three implementations from independent worktrees

## [0.2.1] - 2026-01-06

### Added
- **`prune` command** - Clean up unused remotes and stale worktrees
  - `cross prune`: Interactive removal of remotes with no active patches
  - `cross prune <remote>`: Remove all patches for a specific remote
  - Excludes 'origin' and 'git-cross' from cleanup
  - Runs `git worktree prune` to clean stale worktrees
  - Implemented across all three implementations (Just, Go, Rust)
  - Full test coverage in `test/030_prune.sh`

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
- Added `test/030_prune.sh` with 3 test scenarios
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
