# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2026-11-11

### UX refresh — navigation, selection, listing, diff tool

#### Added
- **`git cross cmp`** - Short alias for `compare`; the canonical name is unchanged.
- **Grouped `--help` output** - Commands are listed under `Patch Lifecycle:`, `Repository:`, and `Inspect & Navigate:` instead of one flat list. `use` and `patch` appear first (in that order), and `cd`/`wt` stay adjacent. `git cross -h` still prints full help, and the help text documents `cross.diffTool` setup.
- **`completion`** - `git cross completion [fish|bash|zsh|powershell]` prints the shell completion script **plus** `crosscd`/`crosswt` functions that perform a real `cd` in the caller's shell (a child process cannot change it). The shell defaults to the basename of `$SHELL`; an unknown or undetectable shell exits 1 instead of guessing. fish uses `git cross completion fish | source` (multi-line `eval (...)` breaks in fish); `init` prints the matching one-liner for the caller's shell. `shell-init` is now hidden (kept for compatibility, wrappers only), and the clipboard fallback is no longer wired into `cd`/`wt`; its helper is kept isolated (unused) for possible reuse.
- **Conflict resolution memory (`rerere`)** - `init`, `patch`, and `update` enable Git's `rerere.enabled` in the shared repository config, so a conflict resolved once in a cross worktree is replayed automatically when the same conflict reappears on a later update. `init` announces the setting (and reports when it is already on), `patch` is silent, and `update` re-enables it for repositories set up before this change. `rerere.autoUpdate` is intentionally left unset (opt-in). Documented in README as "Conflict Resolution Memory (`rerere`)" and covered by `test/024_rerere.sh`, including a real resolve-then-replay scenario.
- **`list --raw` and `list --no-header`** - `--raw` emits tab-separated rows with no table borders and no `==>` banners; `--no-header` omits the header line. Raw column order is documented and fixed: `REMOTE_NAME<TAB>REMOTE_URL` first, then `REMOTE<TAB>REMOTE_PATH<TAB>LOCAL_PATH<TAB>WORKTREE<TAB>BRANCH`. Remote rows are sorted deterministically, remotes with distinct fetch/push URLs produce one row per URL without `(fetch)`/`(push)` suffixes, and the empty-state message goes to stderr in raw mode. On a terminal the columns are space-padded for readability; piped output stays TAB-separated.
- **Patch row listings** - Bare `git cross` prints one `local_path<TAB>worktree` row per patch to stdout instead of Cobra help (rows are aligned on a TTY, TAB-separated when piped; no hint line). Unresolved `compare` / `diff` / `remove` / `cd` / `wt` invocations print the same rows and exit 1 instead of dumping a usage block.
- **Tests 019, 020, 021, 023, 024** - Cover whole-repo patches plus row listings, grouped help and ordering, fzf-driven `diff`/`compare`, editor selection, `local_path` normalization, and `rerere` conflict-resolution memory.

#### Changed
- **BREAKING: `cd` / `wt` print a path instead of opening a shell** - Both commands print the absolute destination path to stdout (hints to stderr). They no longer start a subshell and no longer copy anything to the clipboard. Use `cd "$(git cross cd)"`, `cd "$(git cross wt)"`, or the `crosscd`/`crosswt` functions from `git cross completion`. Without an argument they auto-detect the current patch, then use `fzf`; if `fzf` is missing, rows plus a hint are printed and the command exits 1.
- **Behavior change: interactive `diff` selection** - With no path, `diff` resolves the patch via CWD auto-detect, then `fzf`, then rows + hint + exit 1. Previously, running `diff` from outside a patch directory dumped diffs for all patches.
- **`compare` selection ladder** - With no path, `compare` uses the same CWD auto-detect → `fzf` → rows + hint + exit 1 ladder and always operates on exactly one patch.
- **`cross.diffTool` template form** - The configured command may contain `{left}` / `{right}`, replaced with repo-relative paths while running with the repo root as cwd. The default is `nvim` when installed, otherwise `vim`, using `"+let g:DirDiffExcludes = '.git'" "+DirDiff {left} {right}"` (two `+cmd` arguments: `DirDiffIgnore=...` is not a vim command). `DIRDIFF_EXCLUDES` appends extra file/dir names to the exclusion list (`.git` is always ignored) and `DIRDIFF_IGNORE` ignores comma-separated keywords in diff content (converted to a very-nomagic `\V` regexp), e.g. `DIRDIFF_IGNORE=github.com,gitlab.com`. The legacy append form (for example `vim "+DirDiff"`) is deprecated.
- **Concise `update` warning** - Local edits now produce one relative, actionable line: `'<local_path>' differs from upstream; local copy preserved. Compare with: git cross diff <local_path>`. The `cross.diffTool` configuration hint and the broken DirDiff invocation are gone.
- **Simplified upstream workflow** - `git cross update [path]` reads declarative `use`/`patch` entries from `Crossfile`, fetches upstream, fast-forwards sparse worktrees, and installs only when the local copy has no edits. Local edits are preserved while the worktree advances for manual comparison.
- **Manual contribution workflow** - Retired `push`; use `wt`, `compare`, and ordinary Git commands to manually copy and commit desired changes in the sparse worktree. The comparison tool is configured with `cross.diffTool` (see the Directory Diff Tool section in `README.md`).
- **Retired replay and arbitrary Crossfile commands** - `update` interprets only `use` and `patch`; hooks and shell commands are no longer run from Crossfile.
- **Supported implementations** - Go remains primary and Just/Fish the reference. Rust source is retained but no longer maintained; release artifacts are Go-only.
- **Retired sync workflow** - The prior stash/copy/rebase logic is removed from the supported CLI and Just recipes.
- **`.crossignore` entry syntax** - Override review behavior uses plain non-comment `.crossignore` lines: basename entries such as `.env`, basename globs such as `*.env`, and directory entries such as `config/`. Full `.gitignore` semantics are still not supported.
- **README workflow guidance** - The current `.crossignore` behavior is documented as a review-oriented workflow for local overlay files layered on top of upstream-managed content.

#### Fixed
- **DirDiff invocation** - `compare` passed the two paths as vim file arguments, where DirDiff never saw them. Paths now go inside the vim `+` command string.
- **`.git` false positives in comparisons** - The worktree's `.git` pointer file (never present in the local copy) counted as a local deletion. Boolean checks now use `rsync -rlcn --delete --exclude=.git --itemize-changes`; the visual diff runs `git diff --no-index` against a temporary `.git`-free mirror (pathspec excludes are rejected by older git versions). As a result, whole-repo patches (`remote:.`) no longer always report `Modified` in `status` or always warn in `update`; clean whole-repo patches now update.
- **`local_path` normalization** - A local path such as `./mxc2` was stored verbatim and broke CWD auto-detection (`compare`, `diff`, `cd`/`wt`, `remove`). Paths are normalized on ingestion, normalized defensively during matching, and self-healed on metadata load; the `Crossfile` keeps the user's original spelling.
- **Deterministic `list` ordering** - Remotes are sorted instead of following Go map iteration order.
- **Root `Justfile` argument forwarding** - `just cross …` passed arguments through the shell unquoted, so values containing `;`, `(`, `)`, `<`, `>`, or `|` broke. Arguments are now forwarded with `"$@"` and `[positional-arguments]`.
- **Migration tutorial backup command** - Removed the broken recommendation to call the internal Just `_crossignore_overrides` recipe during private-fork migration. The backup step expands `.crossignore` against the real working tree with `git ls-files --ignored --exclude-from=.crossignore` piped into `rsync`, so globs and not-yet-present paths no longer cause `rsync --files-from` failures.
- **Rust override diff build failure** - Renamed a Rust loop variable that used the reserved keyword `override`, restoring Rust CLI builds and regression execution on current toolchains.
- **Just override warning output** - Removed a shell-breaking semicolon from the override review warning so `just cross diff` prints the manual review commands correctly.
- **P0: Sparse checkout broken on newer Git versions** - `git sparse-checkout set <path>` in `--no-cone` mode no longer reliably checks out directories without a trailing `/`. Fixed across all implementations by appending `/` to sparse-checkout patterns and using `git read-tree -mu HEAD` instead of bare `git checkout`.
- **P0: Go build "inconsistent vendoring" in CI** - Tests that build the Go binary now remove a stale `vendor/` directory and pass `-mod=mod` as a direct flag. `src-go/vendor/` is gitignored.
- **Whole-repo patching (`:/` and `:.`)** - `cross patch remote:/` and `cross patch remote:.` now correctly patch the entire upstream repo. `/` is normalized to `.`, and `.` skips sparse-checkout entirely (full checkout).
- **Prune leaves orphaned `.cross/worktrees/` directories** - `cross prune` scans `.cross/worktrees/` and removes directories not referenced in `metadata.json`, not just git's internal worktree registry.
- **test/014_remove.sh robustness** - The Go binary is reused if already built, and Go tests skip gracefully when the toolchain is unavailable.
- **Test harness defects** - `setup_sandbox` pins `REPO_ROOT` (no drift on repeated calls), `TESTDIR` defaults for standalone runs, and test 016's Go smoke gate uses a real repository.

#### Documentation
- **User documentation refresh** - Clearer top-level README, a user-facing architecture overview, and tutorials for local overlays, publishing to your own origin, and sending changes back upstream.
- **Repo-local `sbx` starter kits** - `sbx-kits/opencode` and `sbx-kits/claude` plus `sbx-kits/README.md`, so `git-cross` can be tried in a versioned sandbox setup.
- **AI skill documentation pointers** - Docs point users and agent tools at `.agents/`, `.claude/`, and `.opencode/skills/`.
- **Whole-upstream tutorial** - Second tutorial showing how to vendor an entire upstream repository with `remote:.` or `remote:/`.
- **Private fork migration tutorial** - Guarded tutorial for migrating an existing private fork or derivative repo to a repo-root `git-cross` patch, with explicit backup and override review steps.
- **Repo split tutorial** - `docs/tutorials/split-repo-into-upstream-and-private.md`, walking through splitting one original repo into a clean secret-free upstream plus a private `git-cross`-managed fork using one shared `.crossignore` selection for both directions.
- **AI-assisted coding / sandbox workflow documentation** - README section covering subfolder scoping, `Crossfile` reproducibility, bidirectional sync, and container-based development sandboxes (`sbx`, Docker sandbox).
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
