# AGENTS

Instructions for AI agents working on this codebase.

## Architecture

**Core mechanism**: `git worktree` (vendoring) + `rsync` (syncing). Three parallel implementations exist with command parity.

| Layer | Location | Language | CLI Framework | Git Interface | Status |
|-------|----------|----------|---------------|---------------|--------|
| **Go** (primary) | `src-go/main.go` | Go | Cobra | `gogs/git-module` + `os/exec` | Production |
| **Just + Fish** | `Justfile.cross` | Fish/Bash | Just | `git` CLI + `jq` | Reference |
| **Rust** (experimental) | `src-rust/src/main.rs` | Rust | Clap | `git2` (minimal) + `duct` | WIP |

Both Go and Rust are single-file implementations (~1500 lines each). Justfile.cross is ~940 lines.

## File Map

```
Justfile              # Root wrapper: delegates `just cross <cmd>` to Justfile.cross
Justfile.cross        # Shell/Fish reference implementation (all commands)
Crossfile             # User-facing state: records use/patch commands for replay
src-go/main.go        # Go CLI (single file, Cobra-based)
src-go/go.mod         # Go module (go 1.23)
src-rust/src/main.rs  # Rust CLI (single file, Clap-based)
src-rust/Cargo.toml   # Rust dependencies
.git/cross/           # Internal state directory
  metadata.json       # Patch registry: {patches: [{remote, remote_path, local_path, worktree, branch}]}
  worktrees/          # Hidden git worktrees for each patch
test/common.sh        # Shared test helpers (setup_sandbox, create_upstream, assertions)
test/run-all.sh       # Test runner: discovers and executes test/NNN_*.sh files
test/001-017_*.sh     # Individual test files (see coverage matrix below)
```

## Commands (all implementations)

| Command | Args | Purpose |
|---------|------|---------|
| `use` | `<name> <url>` | Register remote, detect default branch |
| `patch` | `<remote[:branch]:path> [local_path]` | Sparse-checkout worktree, rsync to local |
| `sync` | `[path]` | Pull upstream, rebase, rsync back to local |
| `diff` | `[path]` | `git diff --no-index` between worktree and local (context-aware: auto-detects patch from CWD) |
| `list` | | Table of remotes and patches |
| `status` | | Health: local diffs, upstream divergence, conflicts |
| `push` | `[path]` | Rsync local to worktree, commit, push upstream |
| `replay` | | Re-execute Crossfile to reconstruct environment |
| `remove` | `<path>` | Delete patch, clean Crossfile and metadata |
| `prune` | `[remote]` | Remove remote and all its patches, prune stale worktrees |
| `exec` | `<cmd>` | Run arbitrary command (for Crossfile hooks) |
| `init` | | Create empty Crossfile |
| `cd` | `[path]` | Open shell in local_path (or fzf select + clipboard) |
| `wt` | `[path]` | Open shell in worktree (or fzf select + clipboard) |

## Implementation Comparison

### Quality Assessment

| Aspect | Just/Fish | Go | Rust |
|--------|-----------|-----|------|
| **Readability** | Best. Concise, intent-clear | Good. Cobra structure helps | Good. Match arms are clean |
| **Error handling** | Weak. Fish has no `set -e`; many unchecked returns | Weak. 14 `loadMetadata` errors silently discarded | Mixed. `anyhow`/`?` is good, but 12 `let _ =` suppressions |
| **Testability** | Tested via Just invocation | Self-contained binary | Self-contained binary |
| **Distribution** | Requires `just` + `fish` + `jq` + `rsync` | Single static binary + `rsync` | Single binary + `rsync` |
| **Maintainability** | Simple to modify, fast iteration | Single 1509-line file, needs decomposition | Single 1520-line file, needs decomposition |

### Key Discrepancies

| Topic | Just/Fish | Go | Rust |
|-------|-----------|-----|------|
| **Worktree hash** | `md5sum(local_path)` — branch NOT included | `SHA256(remote+path+branch)[:8]` — no field separator | `DefaultHasher(canonical+branch)[:8]` — **non-deterministic across Rust versions** |
| **Git interface** | Direct `git` CLI everywhere | Mixed: `gogs/git-module` + `os/exec` + `git.Open()` — 3 styles interleaved | `git2` for 2 commands only, `duct`/`run_cmd` for rest — git2 is dead weight |
| **Metadata `id` field** | Written via jq | **Not in struct** — silently dropped on save | Present with `#[serde(default)]` |
| **Crossfile removal** | `grep -v "patch"` — removes ALL lines with "patch" | `strings.Contains(line, "patch") && strings.Contains(line, localPath)` — fragile | Same as Go — fragile substring match |
| **`init` path** | CWD (no `pushd REPO_DIR`) | CWD (hardcodes `"Crossfile"`) | CWD (hardcodes `"Crossfile"`) |
| **`push` no-arg** | Requires explicit path or CWD in patch | Silently selects first patch | Silently selects first patch |

### What Each Implementation Does Best

- **Justfile.cross**: Clearest intent. `_resolve_context2` is elegant. `update_crossfile` is a 2-line recipe. The CWD-based auto-detection via `USER_CWD` + `jq` is the most correct approach.
- **Go**: `updateCrossfile()` has the best deduplication (3-way prefix matching). `resolvePathToRepoRelative()` handles macOS `/tmp` -> `/private/tmp` symlinks. `detectDefaultBranch()` has the most robust fallback chain.
- **Rust**: `parse_patch_spec()` handles the most edge cases. `anyhow` error context is better than Go's raw `fmt.Errorf`. `select_patch_interactive()` has the cleanest fzf integration.

### Known Systemic Issues (all implementations share)

1. **`cd`/`wt` code duplication**: Near-identical blocks in Go (80 lines) and Rust (56 lines). Should be a single parameterized function.
2. **`remove`/`prune` code duplication**: Prune copy-pastes remove logic. Should call a shared `removePatch()` helper.
3. **`sync` is a god-method**: 159 lines (Go), 192 lines (Rust), 166 lines (Just). Needs decomposition into: stash, sync-to-worktree, pull-rebase, detect-deletions, sync-from-worktree, unstash.
4. **Crossfile removal is fragile**: All three use substring matching that can corrupt unrelated lines.
5. **`loadMetadata` errors universally ignored**: Corrupted metadata.json silently treated as empty.

## Test Coverage

### Test Structure

Tests 001-007 form a chain for Shell/Just (001 is sourced by 002, etc.). Tests 008 (Rust) and 009 (Go) are self-contained monolithic tests. Tests 010-017 are focused feature tests.

### Coverage Matrix

| Command | Shell (tests) | Go (tests) | Rust (tests) |
|---------|:---:|:---:|:---:|
| `use` | 001 | 009 | 008 |
| `patch` | 002 | 009 | 008 |
| `sync` (basic) | 004 | 009 | 008 |
| `sync` (edge cases: conflicts, stash, deletion) | 004 | -- | -- |
| `diff` (basic) | 003 | 009 | 008 |
| `diff` (context-aware CWD) | 003, 016 | 016 | -- |
| `diff` (relative paths) | 003 | -- | -- |
| `list` | (017) | 009, 014 | 008, 014 |
| `status` (all states) | 007 | 009* | 008* |
| `push` (basic) | 006 | 009 | 008, 011 |
| `push` (custom msg/branch/force) | 006 | -- | 011 |
| `replay` | 005 | 009 | 008 |
| `remove` | 014 | 014 | 014 |
| `prune` | 015 | 009 | 008 |
| `cd`/`wt` | 017 | 017 | 017 |
| `exec` | 005* | -- | -- |
| `init` | -- | 009 | 008 |
| `sparse checkout` | 012 | 012 | 012 |

`*` = partial/basic assertions only. `--` = not tested.

### Gaps Worth Addressing

- **Go/Rust sync edge cases**: conflicts, uncommitted changes, file deletion — only tested in Shell.
- **Go push with custom message/branch/force**: only Shell and Rust test these.
- **Rust context-aware diff**: not tested (Go and Shell are).
- **`exec` command**: only tested indirectly through replay.
- **`list` for Shell**: no dedicated test.

## Agent Workflow

### Before Making Changes

1. **Read this file** and `TODO.md` to understand priorities and constraints.
2. **Run existing tests** to establish a baseline: `just cross-test` or `bash test/run-all.sh`.
3. **Understand the three implementations** — changes must land in all three unless the scope is explicitly limited (e.g., "fix Go only").
4. **Check the coverage matrix** above to know what's tested where.

### Implementing Features

**Order of implementation:**
1. **Justfile.cross first** — it's the simplest to iterate on, and serves as the reference for behavior.
2. **Go second** — primary production implementation. Ensure it matches the Just behavior.
3. **Rust third** — experimental. Port from Go since the structure is closer.
4. **Write/update tests** — at minimum, add assertions to 008 (Rust) and 009 (Go). For Shell, add to the relevant 00X test or create a new one.
5. **Update documentation** — `TODO.md`, `CHANGELOG.md`, this file if the change affects architecture.

**Order of verification:**
1. `bash test/NNN_specific.sh` — run the specific test for the feature.
2. `bash test/003_diff.sh` and `bash test/004_sync.sh` — most likely to regress.
3. `bash test/run-all.sh` — full regression.

### Implementing Bug Fixes

- Fix in all three implementations unless the bug is implementation-specific.
- If fixing a shared pattern (e.g., Crossfile removal), fix the pattern once and port to all three.
- Add a regression test.

### Code Quality Rules

**Do:**
- Propagate errors explicitly. Use `return err` (Go), `?` (Rust), `or exit 1` (Fish).
- Use the established helpers: `getRepoRoot()`/`get_repo_root()`, `loadMetadata()`/`load_metadata()`, `updateCrossfile()`/`update_crossfile()`.
- Use constants for paths: `.git/cross/worktrees/`, `Crossfile`, `.git/cross/metadata.json`.
- Match the existing code style of each implementation (Cobra commands in Go, Clap derive in Rust, Fish recipes in Just).

**Don't:**
- Add new dependencies to Rust (git2 is already dead weight — prefer `duct` CLI calls).
- Use `gogs/git-module` for new Go code (prefer `os/exec` for consistency — the mixed approach is a known problem).
- Make Justfile.cross more complex to accommodate programmatic concerns — keep it readable and concise.
- Silently discard errors with `_ =` / `let _ =` / ignoring return values. Log them at minimum.
- Duplicate logic between commands (especially `remove`/`prune` and `cd`/`wt`).

### Working with Tests

- Tests use `setup_sandbox` and `create_upstream` from `test/common.sh`.
- Shell tests may chain-source earlier tests (e.g., 003 sources 002 which sources 001).
- Tests 008/009 are self-contained and build their own binaries.
- To run a specific test: `bash test/NNN_name.sh`.
- To run all: `bash test/run-all.sh` or `just cross-test`.
- CI runs on `ubuntu-latest` and does NOT install Go/Rust toolchains — tests 008/009 must handle this gracefully (skip with message).

### Commit Conventions

- No partial implementations — all three must be updated in the same commit series.
- Test coverage required for new features.
- Update `CHANGELOG.md` for user-facing changes.
- Update `TODO.md` when completing or adding items.

## Implementation Details

- **Hidden worktrees**: `.git/cross/worktrees/<remote>_<hash>`.
- **Sparse checkout**: `git sparse-checkout set <path>` — only specified paths checked out.
- **Rsync**: `rsync -av --delete --exclude .git` for worktree-to-local sync. `--delete` removes files locally that were deleted upstream.
- **Crossfile format**: Lines like `cross use <name> <url>` or `cross patch <remote>:<branch>:<path> <local>`. Parsed as bash during `replay`.
- **Metadata format**: JSON at `.git/cross/metadata.json`. Schema: `{"patches": [{"id", "remote", "remote_path", "local_path", "worktree", "branch"}]}`.

## Refactoring Priorities

When time allows, these structural improvements would most benefit the codebase:

1. **Extract `removePatch()` helper** in Go and Rust — eliminates duplication between `remove` and `prune`.
2. **Unify `cd`/`wt`** into a single parameterized function in Go and Rust.
3. **Decompose `sync`** into sub-functions (stash, sync-to-wt, pull, detect-deletions, sync-from-wt, unstash).
4. **Fix Crossfile removal** — use structured parsing (split line, match local_path field) instead of substring matching.
5. **Stabilize Rust worktree hash** — replace `DefaultHasher` with SHA256 to match Go's deterministic behavior.
6. **Remove `git2` dependency** from Rust — it's used for 2 trivial operations that already have CLI fallbacks.
7. **Consolidate Go's git interface** — pick either `gogs/git-module` or `os/exec` and use it consistently.
