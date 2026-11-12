# AGENTS

Instructions for AI agents working on this codebase.

## Architecture

**Core mechanism**: sparse `git worktree` + `rsync`. Supported implementations are Go (primary) and Just/Fish (reference). Rust remains in the repository but is unsupported and unmaintained.

| Layer | Location | Language | CLI Framework | Git Interface | Status |
|-------|----------|----------|---------------|---------------|--------|
| **Go** (primary) | `src-go/main.go` | Go | Cobra | `gogs/git-module` + `os/exec` | Production |
| **Just + Fish** | `Justfile.cross` | Fish/Bash | Just | `git` CLI + `jq` | Reference |
| **Rust** (unsupported) | `src-rust/src/main.rs` | Rust | Clap | `git2` + `duct` | Unmaintained |

Go is a single-file implementation. Justfile.cross is the readable reference.

## File Map

```
Justfile              # Root wrapper: delegates `just cross <cmd>` to Justfile.cross
Justfile.cross        # Shell/Fish reference implementation (all commands)
Crossfile             # User-facing declarations: records use/patch setup
src-go/main.go        # Go CLI (single file, Cobra-based)
src-go/go.mod         # Go module (go 1.24)
src-rust/src/main.rs  # Rust CLI (single file, Clap-based)
src-rust/Cargo.toml   # Rust dependencies
.cross/               # Internal state directory
  metadata.json       # Patch registry: {patches: [{remote, remote_path, local_path, worktree, branch}]}
  worktrees/          # Hidden git worktrees for each patch
test/common.sh        # Shared test helpers (setup_sandbox, create_upstream, assertions)
test/run-all.sh       # Test runner: discovers and executes test/NNN_*.sh files
test/001-023_*.sh     # Individual test files (see coverage matrix below)
```

## Commands (all implementations)

| Command | Args | Purpose |
|---------|------|---------|
| `use` | `<name> <url>` | Register remote, detect default branch |
| `patch` | `<remote[:branch]:path> [local_path]` | Sparse-checkout worktree, rsync to local |
| `update` | `[path]` | Read Crossfile and update upstream patches; preserve local edits |
| `diff` | `[path]` | Console `git diff --no-index`; resolves patch via CWD auto-detect → fzf → rows + exit 1 |
| `list` | `[--raw] [--no-header]` | Table (default) or TSV rows of remotes and patches |
| `status` | | Health: local diffs, upstream divergence, conflicts |
| `compare` | `[path]` (alias `cmp`) | Open configured directory diff tool; exactly one patch, same resolution ladder as `diff` |
| `remove` | `<path>` | Delete patch, clean Crossfile and metadata |
| `prune` | `[remote]` | Remove remote and all its patches, prune stale worktrees |
| `init` | | Create empty Crossfile |
| `cd` | `[path]` | Print absolute local_path to stdout; real `cd` via `completion` wrappers (`crosscd`) |
| `wt` | `[path]` | Print absolute worktree path to stdout; `crosswt` wrapper |
| `completion` | `[fish\|bash\|zsh\|powershell]` | Print completions + `crosscd`/`crosswt` wrappers; shell defaults from `$SHELL` |
| `shell-init` | `[fish\|bash\|zsh]` | Hidden (kept for compatibility): prints the wrappers without completions |

Bare `git cross` prints one `local_path<TAB>worktree` row per patch to stdout (no hint line; TTY output is space-padded, piped output stays TAB-separated); `-h` prints the grouped help. Help grouping is Go-only CLI presentation — Just/Fish exposes the same behavior through recipes, not through a grouped help renderer.

## Implementation Comparison

### Quality Assessment

| Aspect | Just/Fish | Go | Rust (unsupported) |
|--------|-----------|-----|------|
| **Readability** | Best. Concise, intent-clear | Good. Cobra structure helps | Good. Match arms are clean |
| **Error handling** | Weak. Fish has no `set -e`; many unchecked returns | Weak. 14 `loadMetadata` errors silently discarded | Mixed. `anyhow`/`?` is good, but 12 `let _ =` suppressions |
| **Testability** | Tested via Just invocation | Self-contained binary | Self-contained binary |
| **Distribution** | Requires `just` + `fish` + `jq` + `rsync` | Single static binary + `rsync` | Single binary + `rsync` |
| **Maintainability** | Simple to modify, fast iteration | Single 1509-line file, needs decomposition | Single 1520-line file, needs decomposition |

### Historical implementation discrepancies

| Topic | Just/Fish | Go | Rust (unsupported) |
|-------|-----------|-----|------|
| **Worktree hash** | `SHA256(remote\0remote_path\0branch)[:8]` — Just reference | `SHA256(remote+path+branch)[:8]` — Go legacy mismatch | Rust used `DefaultHasher`; unsupported |
| **Git interface** | Direct `git` CLI everywhere | Mixed: `gogs/git-module` + `os/exec` + `git.Open()` — 3 styles interleaved | `git2` for 2 commands only, `duct`/`run_cmd` for rest — git2 is dead weight |
| **Metadata `id` field** | Written via jq | **Not in struct** — silently dropped on save | Present with `#[serde(default)]` |
| **Crossfile removal** | `grep -v "patch"` — removes ALL lines with "patch" | `strings.Contains(line, "patch") && strings.Contains(line, localPath)` — fragile | Same as Go — fragile substring match |
| **`init` path** | CWD (no `pushd REPO_DIR`) | CWD (hardcodes `"Crossfile"`) | CWD (hardcodes `"Crossfile"`) |

### What Each Implementation Does Best

- **Justfile.cross**: Clearest intent. `_resolve_context2` is elegant. `update_crossfile` is a 2-line recipe. The CWD-based auto-detection via `USER_CWD` + `jq` is the most correct approach.
- **Go**: `updateCrossfile()` has the best deduplication (3-way prefix matching). `resolvePathToRepoRelative()` handles macOS `/tmp` -> `/private/tmp` symlinks. `detectDefaultBranch()` has the most robust fallback chain.
- **Rust**: `parse_patch_spec()` handles the most edge cases. `anyhow` error context is better than Go's raw `fmt.Errorf`. `select_patch_interactive()` has the cleanest fzf integration.

### Known historical issues

1. **`cd`/`wt` duplication (resolved)**: Go now uses one parameterized `makeDirCmd`; Just has one recipe per target. Rust retains its own unsupported implementation.
2. **`remove`/`prune` code duplication**: Prune copy-pastes remove logic. Should call a shared `removePatch()` helper.
3. The retired `sync` flow rebased local changes. The supported `update` flow fetches upstream, fast-forwards a clean worktree, and preserves local files for manual review if they differ.
4. **Crossfile removal is fragile**: All three use substring matching that can corrupt unrelated lines.
5. **`loadMetadata` errors universally ignored**: Corrupted metadata.json silently treated as empty.

## Test Coverage

### Test Structure

Tests 001-007 form a chain for Just/Fish (001 is sourced by 002, etc.). Test 009 exercises Go. Rust, push, and replay legacy tests are excluded from the default runner. Tests 010-024 are focused feature tests; 019-023 cover the UX refresh (row listings and whole-repo patches, grouped help, fzf selection, `local_path` normalization) and 024 covers `rerere` conflict-resolution memory.

### Coverage Matrix

| Command / behavior | Just/Fish | Go |
|---------|:---:|:---:|
| `use` | 001 | 009 |
| `patch` | 002 | 009, 019, 023 |
| `update` (upstream/local edit behavior) | 004 | 009, 018, 019 |
| `diff` (basic) | 003 | 009 |
| `diff` (context-aware CWD) | 003, 016 | 016, 021 |
| `diff` (no path: fzf / rows ladder) | 021‡ | 021 |
| `diff` (relative paths) | 003 | -- |
| `list` (table) | -- | 009, 014 |
| `list --raw` / `--no-header` | -- | 009, 014 |
| `status` (all states) | 007 | 009*, 019, 023 |
| `compare` (incl. `cmp` alias) | -- | 009, 019, 021 |
| `remove` | 014 | 014, 023 |
| `prune` | 015 | 009 |
| `cd`/`wt` (print path) | 017 | 017, 023 |
| `completion` (scripts + wrappers, `$SHELL`) | 017‡ | 017, 020 |
| `shell-init` (hidden) | 017 | 017 |
| `init` | 024 | 009, 024 |
| `sparse checkout` | 012 | 012 |
| `sbx/update workflow` | -- | 018 |
| whole-repo patch (`.git` exclusion) | 019‡ | 019 |
| grouped `--help` | n/a | 020 |
| `local_path` normalization | 023‡ | 023 |
| `rerere` (config + resolution reuse) | 024 | 024 |

`*` = partial/basic assertions only. `--` = not tested. `‡` = variant guarded by Fish availability (skips gracefully when `fish` is absent).

### Gaps Worth Addressing

- **Just update behavior**: requires Fish to be installed; run `test/004_update.sh` in an environment with Fish.
- **Just `list` output**: no dedicated test; `test/019` exercises patch row listings when Fish is available.
- **Just variants**: `test/019`, `test/021`, `test/023`, `test/024`, and `test/017` include Fish-guarded variants that skip when `fish` is absent; `test/020` is Go-only (grouped help is a Go CLI rendering concern). CI should keep Fish present to avoid silent gaps.

## Agent Workflow

### Before Making Changes

1. **Read this file** and `TODO.md` to understand priorities and constraints.
2. **Run existing tests** to establish a baseline: `just cross-test` or `bash test/run-all.sh`.
3. **Understand supported implementations** — implement shared behavior in Just/Fish first and Go second. Do not update Rust.
4. **Check the coverage matrix** above to know what's tested where.

### Implementing Features

**Order of implementation:**
1. **Justfile.cross first** — it's the simplest to iterate on, and serves as the reference for behavior.
2. **Go second** — primary production implementation. Ensure it matches the Just behavior.
3. **Write/update tests** — cover Just/Fish and Go; Rust tests are excluded from supported verification.
5. **Update documentation** — `TODO.md`, `CHANGELOG.md`, this file if the change affects architecture.

**Order of verification:**
1. `bash test/NNN_specific.sh` — run the specific test for the feature.
2. `bash test/003_diff.sh` and `bash test/004_update.sh` — most likely to regress.
3. `bash test/run-all.sh` — full regression.

### Implementing Bug Fixes

- Fix in supported implementations (Just/Fish and Go).
- If fixing a shared pattern (e.g., Crossfile removal), fix the pattern in Just/Fish and Go.
- Add a regression test.

### Code Quality Rules

**Do:**
- Propagate errors explicitly. Use `return err` (Go), `or exit 1` (Fish).
- Use the established helpers: `getRepoRoot()`/`get_repo_root()`, `loadMetadata()`/`load_metadata()`, `updateCrossfile()`/`update_crossfile()`.
- Use constants for paths: `.cross/worktrees/`, `Crossfile`, `.cross/metadata.json`.
- Match the existing code style of each supported implementation (Cobra commands in Go, Fish recipes in Just).

**Don't:**
- Use `gogs/git-module` for new Go code (prefer `os/exec` for consistency — the mixed approach is a known problem).
- Make Justfile.cross more complex to accommodate programmatic concerns — keep it readable and concise.
- Silently discard errors with `_ =` / `let _ =` / ignoring return values. Log them at minimum.
- Duplicate logic between commands (especially `remove`/`prune` and `cd`/`wt`).

### Working with Tests

- Tests use `setup_sandbox` and `create_upstream` from `test/common.sh`.
- Shell tests may chain-source earlier tests (e.g., 003 sources 002 which sources 001).
- Test 009 is self-contained and builds/reuses the Go binary.
- To run a specific test: `bash test/NNN_name.sh`.
- To run all: `bash test/run-all.sh` or `just cross-test`.
- CI runs on `ubuntu-latest`; optional Go tests must handle missing Go toolchains gracefully.
- Go binary builds must remove stale `src-go/vendor/` before building and pass `-mod=mod` directly as a flag (not via `GOFLAGS`). The vendor directory is gitignored but may exist locally.

### Commit Conventions

- No partial implementations — supported Just/Fish and Go behavior should stay aligned.
- Test coverage required for new features.
- Update `CHANGELOG.md` for user-facing changes.
- Update `TODO.md` when completing or adding items.

## Implementation Details

- **Hidden worktrees**: `.cross/worktrees/<remote>_<hash>` (verified in `src-go/main.go`; Justfile.cross uses the same path).
- **`.git` exclusion**: a worktree root contains a `.git` pointer file that never exists in the local copy (rsync uses `--exclude .git`). Boolean tree comparisons use `rsync -rlcn --delete --exclude=.git --itemize-changes`; the visual diff (`git diff --no-index`) is run against a temporary `.git`-free mirror of the worktree, because pathspec excludes like `:(exclude).git` are rejected by older git versions with a usage error. Without both exclusions, whole-repo patches always look modified.
- **Sparse checkout**: `git sparse-checkout init --no-cone` + `git sparse-checkout set <path>/` + `git read-tree -mu HEAD`. The trailing `/` on the pattern is required for reliable directory matching in `--no-cone` mode on newer Git versions (2.43+). `read-tree -mu HEAD` explicitly materializes the worktree (bare `git checkout` can no-op after `--no-checkout`).
- **Rsync**: `rsync -av --delete --exclude .git` for worktree-to-local sync. `--delete` removes files locally that were deleted upstream.
- **Directory diff tool**: `cross.diffTool` supports `{left}`/`{right}` placeholders substituted with repo-relative paths, run with cwd = repo root. Default: `nvim` when installed, else `vim`, using `"+let g:DirDiffExcludes = '.git'" "+DirDiff {left} {right}"` (two separate `+cmd` arguments; `DirDiffIgnore=...` is not a vim command). When unset, env vars extend the default: `DIRDIFF_EXCLUDES` appends names to the exclusion list (`.git` stays permanent) and `DIRDIFF_IGNORE` adds `g:DirDiffIgnore` with a very-nomagic (`\V`) alternation of the comma-separated keywords. Empty/unset vars omit the corresponding argument. Configs without placeholders fall back to appending both absolute paths (legacy, deprecated — it never invoked DirDiff correctly).
- **Clipboard helper (parked)**: `copyToClipboard` (Go) / `_clip` (Just) remain implemented but are intentionally unused — `cd`/`wt` print a path and `completion` provides the real `cd`, which made the clipboard workflow obsolete. Reuse rather than reimplement if a clipboard feature returns.
- **Shell integration**: `cd`/`wt` print only the path to stdout (hints/rows go to stderr), so a parent-shell wrapper can capture it. `git cross completion [fish|bash|zsh|powershell]` emits the Cobra completion script plus the `crosscd`/`crosswt` functions (fish first in usage/errors); the shell defaults to the basename of `$SHELL`, and an unknown/undetectable shell exits 1 instead of guessing. fish must use `git cross completion fish | source` because fish joins multi-line command substitution with spaces (`eval (...)` breaks); `init` prints the shell-appropriate one-liner. `shell-init` is hidden but kept for compatibility and emits only the wrappers. powershell gets completions only. Just emits the wrappers only (Cobra scripts are a Go CLI concern).
- **Patch rows**: bare `git cross`, and path-miss cases in `compare`/`diff`/`remove`/`cd`/`wt`, print `local_path<TAB>worktree` rows to stdout; hints go to stderr and the command exits 1 where nothing was resolved.
- **`list --raw` schema**: remotes first (`REMOTE_NAME<TAB>REMOTE_URL`), then patches (`REMOTE<TAB>REMOTE_PATH<TAB>LOCAL_PATH<TAB>WORKTREE<TAB>BRANCH`); no banners, no borders, deterministic remote order.
- **`rerere` (conflict resolution memory)**: `ensureRerere` (Go) / an inline `git config rerere.enabled true` (Just) runs in `init` (announces, and says "already enabled" on repeat), `patch` (silent), and `update` (announces only when it newly enables it, which self-heals older repos). The key is written to the shared repository config, so the main repo and every cross worktree see it; each worktree records resolutions in its own `rr-cache`. `rerere.autoUpdate` is intentionally left unset (opt-in, users enable it themselves). Just's `init` resolves the repo root explicitly so it never writes global config.
- **Crossfile format**: Lines like `cross use <name> <url>` or `cross patch <remote>:<branch>:<path> <local>`. `update` interprets only these declarative commands; arbitrary shell commands are not executed.
- **.crossignore**: Located in the root of each local_path, uses gitignore-style patterns to exclude files from status and diff comparisons. Implemented by filtering directory trees using git add and git clean to remove ignored files before comparison.

## Refactoring Priorities

When time allows, these structural improvements would most benefit the codebase:

1. **Extract `removePatch()` helper** in Go and Rust — eliminates duplication between `remove` and `prune`.
2. **Fix Crossfile removal** — use structured parsing (split line, match local_path field) instead of substring matching.
3. **Consolidate Go's git interface** — pick either `gogs/git-module` or `os/exec` and use it consistently.
