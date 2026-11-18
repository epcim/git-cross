# AGENTS

Instructions for AI agents working on this codebase.

## Architecture

**Core mechanism**: per-patch standalone **bare gitdir** + a work tree that lives **inside the primary repo** at the patch path. No rsync, no linked worktrees, no remotes in the primary repo. The implementations are **no longer 1:1 (v0.5.1)**: Go is the primary and ONLY full implementation; the Just/Fish reference is a core-only prototyping/showcase tool. Rust was deleted from the repository.

| Layer | Location | Language | CLI Framework | Git Interface | Status |
|-------|----------|----------|---------------|---------------|--------|
| **Go** (primary — the only full implementation) | `src-go/main.go` | Go | Cobra | `os/exec` (`git` CLI) only | Production |
| **Just + Fish** (reference: CORE commands only) | `Justfile.cross` | Fish/Bash | Just | `git` CLI + `jq` | Prototyping / showcase |

Go is a single-file implementation and owns every command. Justfile.cross implements
the CORE only — `use`, `set`, `del`, `ls`, `cfg`/`init` and the git passthrough
(`just cross <git-args>` → `_gitcmd`). `update`, `resolve`, `wipe`, `comp`,
`shell-init`, `cd` and `wt` are Go-only placeholder stubs there: they print
`NOT IMPLEMENTED in Justfile version` to stderr and exit 1 (this is also the test
skip marker). The reference may be raw to the user — fail early, one stderr line,
no prompts, no chatty logging. Touch it only for `.cross/metadata.json` schema
changes or core-command fixes; the pre-split full reference is kept uncommitted
as `Justfile.cross.full-v0.5`.

```
primary-repo/
├── .cross/                                    # disposable state (gitignored)
│   ├── metadata.json                          # v2 registry (see ADR-001)
│   └── worktrees/<remote>/<local_path_slashed>/  # standalone BARE gitdir
└── vendor/docs/                               # THE PATCH: plain files, tracked by the primary
```

Upstream git operations run through `GIT_DIR=<gitdir>` + `GIT_WORK_TREE=<crossed dir>`.

Read `specs/003-gitdir-patches/adr-001-metadata-locations.md` (location fields) and
`adr-002-passthrough-requires-patch.md` (passthrough contract) before changing
metadata or the passthrough.

## File Map

```
Justfile              # Root wrapper: delegates `just cross <cmd>` to Justfile.cross;
                      # unknown names fall through to the git passthrough (_gitcmd)
Justfile.cross        # CORE-command reference (use/set/del/ls/cfg + passthrough);
                      # Go-only commands are NOT IMPLEMENTED stubs (v0.5.1)
Justfile.cross.full-v0.5  # uncommitted backup of the pre-split full reference
Crossfile             # User-facing declarations: records use/patch setup
src-go/main.go        # Go CLI (single file, Cobra-based) — the only full implementation
src-go/go.mod         # Go module
.cross/               # Internal state directory (disposable)
  metadata.json       # {remotes:[{name,url}], patches:[{remote,remote_url,remote_path,
                      #   local_path,worktree,gitdir,branch}]}
  worktrees/<remote>/<patch>/   # bare gitdir per patch (HEAD, config, objects/, info/sparse-checkout)
test/common.sh        # Shared test helpers (setup_sandbox, create_upstream, assertions, ensure_go_bin)
test/run-all.sh       # Test runner: discovers and executes test/NNN_*.sh files
test/001-027_*.sh     # Individual test files (see coverage matrix below)
.agents/skills/git-cross-test-update/SKILL.md   # procedure for updating tests to v0.5 semantics
specs/003-gitdir-patches/                       # plan, progress, ADR-001, ADR-002
```

## Commands (Go CLI; the Just/Fish reference implements the core subset)

| Command | Args | Purpose |
|---------|------|---------|
| `use` | `<name> <url>` | Register a remote in metadata (**primary git remotes untouched**); validates reachability |
| `set` | `<remote[:branch]:path> [local_path]` | Set a cross directory: bare-clone into `.cross/worktrees/<remote>/<patch>`, sparse filter, materialize the work tree in the repo |
| `update` | `[path] [--no-resolve] [--force]` | Fetch all crosses, then land upstream in the crossed dir + re-apply your version (ADR-003); unstaged edits refuse, collisions are kept; lost `.cross` state (Go: y/N prompt, default No) / `--force` re-adopts |
| `resolve` | `[path] [--continue\|--abort]` | Finish an update conflict: list unmerged paths, gate `--continue`, revert with `--abort` |
| `del` | `<path>` | Delete a cross: gitdir + crossed dir + Crossfile/metadata entries |
| `wipe` | `[remote]` | Remove a remote and all its crosses, or sweep unused remotes + orphaned gitdirs. (v0.4 `prune`, 0.5.0 `purge`) |
| `cfg` | | Configure the repo: Crossfile + `rerere.enabled` + `.cross/` in `.gitignore` (`init` kept as alias) |
| `ls` | `[--raw] [--no-header]` | Tables (default) or TSV rows of remotes and crosses incl. DIFF + upstream SHA (`list` kept as alias) |
| `cd` | `[path]` | Hidden from help: print the crossed dir path; the `xcd` / `gx cd` wrapper does the real `cd` |
| `wt` | `[path]` | Hidden alias of `cd` (was the git passthrough in <=0.5.0) |
| `comp` | `[fish\|bash\|zsh\|powershell]` | Completions + `xcd`/`gx`/`cr` wrappers (`completion` kept as alias); optional `git x` alias hint |
| `shell-init` | `[fish\|bash\|zsh]` | Hidden (compat): wrappers only, no completions |
| *(any git command)* | `<git-args...>` | Falls through to the git passthrough (upstream context inside a crossed dir; fails early outside) |

- *(v0.5.1)* `stat` was **removed** — the health table moved into `ls` as the
  **DIFF** and **SHA** columns; `git cross stat` now falls through to the git
  passthrough (like `status` in 0.5.0). `del` is NOT affected.

- **No dedicated `diff`**: `git cross diff` is the passthrough — inside a crossed dir it is
  `git diff` against the cross's upstream worktree; at the repo root it **fails early**
  (ADR-002). `git cross status`/`log`/`push`/`pull -r` behave the same way.
- **The passthrough REQUIRES a crossed dir.** Outside one there is no `GIT_DIR`/`GIT_WORK_TREE`
  to configure, so it exits 1 with a hint instead of silently running git on the primary
  repo. Plain `git` is the tool for the primary repo.
- Bare `git cross` prints one `local_path<TAB>gitdir` row per patch (TTY output is
  space-padded; piped output stays TAB-separated); `-h` prints the grouped help.
  Help grouping is Go-only presentation.

**Just/Fish reference scope (v0.5.1):** of the commands above, the reference implements
`use`, `set`, `del`, `ls`, `cfg`/`init` and the git passthrough ONLY.
`update`, `resolve`, `wipe`, `comp`, `shell-init`, `cd` and `wt` are Go-only —
in the reference they are stubs printing `NOT IMPLEMENTED in Justfile version`
(exit 1).

## Implementation Comparison (v0.5.1: no longer 1:1)

| Aspect | Just/Fish reference | Go |
|--------|-----------|-----|
| **Role** | Prototyping / clean-code showcase | The ONLY full implementation (production) |
| **Scope** | Core commands only; the rest are `NOT IMPLEMENTED` stubs | Every command |
| **Readability** | Best. Concise, intent-clear | Good |
| **Error handling** | Raw by design: fail early, one stderr line, no prompts | Weak: some `loadMetadata` errors discarded |
| **Distribution** | Requires `just` + `fish` + `jq` | Single static binary |
| **Git interface** | `git` CLI everywhere + `jq` | `os/exec` only (one style) |
| **Passthrough args** | fish `$argv` (NOT `{{args}}` — that word-splits) | `exec.Command` argv |

Parity is NO LONGER a project rule (v0.5.1). The shared contract is limited to:
- the `.cross/metadata.json` schema (ADR-001) and the Crossfile format,
- the CORE commands' behavior (use/set/del/ls/cfg + passthrough): same messages
  and exit codes (asserted by tests 001-004, 009, 010, 012, 025),
- the passthrough contract (ADR-002).
Everything else (update, resolve, wipe, comp, shell-init, cd, wt and all NEW
features) lands in Go ONLY. The Just reference is touched for schema changes or
core-command fixes, nothing more.

## Test Coverage

### Test Structure

21 tests, all targeting v0.5.0+. There is no exclusion list any more: retired tests were
deleted with their commands (005 replay, 008/011 Rust, 021 compare); the Rust
implementation itself was deleted in v0.5.1.

**Just/Fish test separation (v0.5.1):** just-side sub-cases of Go-only commands SKIP
via the `just_ref_implements <cmd>` probe in `test/common.sh` (the stub answers
`NOT IMPLEMENTED`). A `SKIP (just)` line is expected output, NOT a failure.
Go-side coverage is the gate; a core-command change must keep BOTH sides green.

Tests 001-004 form a chain (`004` sources `002` which sources `001`, `003` sources
`002`); 014 sources 002 with `CLEANUP=false`. Test 009 is self-contained for Go,
010/012/017/023 exercise both implementations with an `exercise()` + `xc()` dispatcher,
and 025 is the v0.5.0 stage-1 gate (creation/checkout for both).

Names match the current command set: `007_ls_health`, `010_cd_wt_passthrough`,
`015_wipe`, `017_cd_shell_integration`.

Run a single test with `SHELL=/bin/bash bash test/NNN_*.sh` (never `run-all.sh` while
iterating — it shares `testdir`). To run everything quickly, use the grouped
parallel workflow in `.agents/skills/git-cross-parallel-tests/SKILL.md`
(~20s wall; `run-all.sh` remains the serial CI entry point).

**Before changing a test, verify the implementation is already v0.5.0 for that
command** — a failing assertion is not proof the test is right. Check the command,
its help text and its metadata output first.

### Where to put a test

| What you changed | Put the test in |
|---|---|
| update/resolve/apply semantics, metadata math, delta building | `src-go/*_test.go` (`go test ./src-go`) |
| a command's user-visible contract (units, exit codes, rows, prompts) | `test/NNN_*.sh` |
| a CORE command both implementations must do identically | `test/NNN_*.sh` with an `exercise()`/`xc()` dispatcher + `just_ref_implements` guards (as 010/019/023 do) |
| a bug that only shows through the recipe | `Justfile.cross` step comment + an integration test; do not "fix" it by changing the test |

`test/run-all.sh` is the serial CI gate (also runs `go test ./src-go`). For fast
iteration use the grouped parallel workflow in
`.agents/skills/git-cross-parallel-tests/SKILL.md`.

Procedure for updating a test to v0.5 semantics: `.agents/skills/git-cross-test-update/SKILL.md`.

### Coverage Matrix

| Command / behavior | Just/Fish | Go |
|---------|:---:|:---:|
| `use` (metadata only, primary untouched) | 001, 025 | 009, 025 |
| `set` (bare gitdir, sparse, no `.git` in crossed dir, primary blob tracking) | 002, 012, 025 | 009, 012, 019, 023, 025 |
| `update` (land + re-apply, refusal, conflict kept) | — (Go-only; stub) | 009, 018, 019, 026 |
| `update --force` / re-adoption of lost crosses (y/N prompt + dirty guard) | — (Go-only; stub) | 027 |
| `resolve` (list, `--continue`, `--abort`) | — (Go-only; stub) | 009, 018, 026 |
| Go-level update/resolve tests (`go test ./src-go`) | — | 5 integration tests in `src-go/update_resolve_test.go` |
| `pull -r` in patch ctx (clean + conflicting rebase) | 004 | 004‡, 024 |
| `ls` health columns (DIFF/SHA) | 007, 019, 023 | 009, 019, 023 |
| git passthrough (`git cross <git-args>`): upstream ctx inside, fail-early outside | 003, 010, 016, 025 | 009, 010, 016, 025 |
| `cd` (path printing, CWD auto-detect) | — (Go-only; stub) | 017, 023 |
| `ls` table / `--raw` / `--no-header` (`list` alias) | 019‡ | 009, 014 |
| `del` (gitdir + crossed dir + entries) | 014, 023 | 009, 014, 023 |
| `wipe` (remote, multi-cross, orphan sweep, root guard) | — (Go-only; stub) | 009, 015 |
| `cfg` / `init` alias | 024 | 009, 024 |
| `comp` / hidden `shell-init` | — (Go-only; stub) | 017, 020 |
| grouped `--help` + configuration guidance | n/a | 020 |
| sparse checkout plumbing | 012 | 012 |
| whole-repo cross (no sparse, no `.git`) | 019‡ | 019 |
| `local_path` normalization / per-patch gitdirs | 023 | 023 |
| `rerere` (repo + gitdir config, resolution reuse) | — (update flow is Go-only; set/cfg parts still run) | 024 |

`--` = not tested. `‡` = variant guarded by Fish availability (skips gracefully when
`fish` is absent). **v0.5.1:** the Just/Fish column applies to CORE commands only —
just sub-cases of Go-only commands are guarded by `just_ref_implements` and SKIP.

### Gaps Worth Addressing

- **Ignore support** (`.crossignore` replacement) — retired in 0.5.0, untested and
  unimplemented; decide before reintroducing.
- **Deep gitdir recovery** (`doctor`): missing/moved gitdirs are only partly covered
  (015 orphan sweep, 024 self-heal).
- **`cross.depth`/`cross.filter`**: opt-in shallow/partial clone is exercised opportunistically
  (025 sets `cross.depth`), but there is no dedicated partial-clone test.
- **Fish-guarded variants** (010, 012, 017, 018, 019, 023, 024) skip silently when fish is
  missing; CI should keep fish installed (core-command parity needs it; Go-only
  sub-cases skip via `just_ref_implements` regardless).

## Agent Workflow

### Asking Questions & Escalating Problems

- **Ask the user to resolve problems.** When you hit a blocker, an unexpected failure, or an ambiguous requirement, do not guess or silently work around it — bring it to the user for resolution.
- **Question format: explain RC first, then ask for guidance.** Every question must first explain the root cause (RC) or the problem — what happened, what was expected, and the evidence — and only then ask for guidance on how to proceed.
- Applies to subagent workflows too: children report blockers to the parent session (with RC); the parent escalates to the user in this same format.

### Before Making Changes

1. **Read this file** and `TODO.md` to understand priorities and constraints.
2. **Run existing tests** to establish a baseline: `just cross-test` or `bash test/run-all.sh`.
3. **Implementation scope (v0.5.1)** — implement in Go (the primary and only full implementation). Touch `Justfile.cross` ONLY for `.cross/metadata.json` schema changes or CORE-command fixes (use/set/del/ls/cfg/passthrough). Rust was deleted — never resurrect it.
4. **Check the coverage matrix** above to know what's tested where.

### Implementing Features

**Order of implementation:**
1. **Go first** — the primary and, for non-core commands, the only implementation.
2. **Justfile.cross** — only when the change touches the metadata schema or a CORE command (use/set/del/ls/cfg/passthrough); keep it simple, short and clean.
3. **Write/update tests** — cover Go; add just-side assertions for core commands only (guard Go-only sub-cases with `just_ref_implements`).
4. **Update documentation** — `TODO.md`, `CHANGELOG.md`, this file if the change affects architecture.

**Order of verification:**
1. `bash test/NNN_specific.sh` — run the specific test for the feature.
2. `bash test/003_diff.sh` and `bash test/004_update.sh` — most likely to regress.
3. `bash test/run-all.sh` — full regression.

### Implementing Bug Fixes

- Fix in Go (the primary implementation).
- Fix the Just reference too only when the bug is in a CORE command or the metadata schema.
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
- Duplicate logic between commands (especially `del`/`wipe` and `cd`/`wt`).

### Working with Tests

- Tests use `setup_sandbox` and `create_upstream` from `test/common.sh`.
- Shell tests may chain-source earlier tests (e.g., 003 sources 002 which sources 001).
- Test 009 is self-contained and builds/reuses the Go binary.
- To run a specific test: `bash test/NNN_name.sh`.
- To run all: `bash test/run-all.sh` or `just cross-test`.
- CI runs on `ubuntu-latest`; optional Go tests must handle missing Go toolchains gracefully.
- Go binary builds must remove stale `src-go/vendor/` before building and pass `-mod=mod` directly as a flag (not via `GOFLAGS`). The vendor directory is gitignored but may exist locally.

### Commit Conventions

- No partial implementations — Go is complete by definition; core commands stay aligned in the Just reference.
- Test coverage required for new features.
- Update `CHANGELOG.md` for user-facing changes.
- Update `TODO.md` when completing or adding items.

## Implementation Details

- **Gitdir layout**: `.cross/worktrees/<remote>/<local_path with / → _>/` — a standalone
  `git clone --bare` per patch. No hash suffix, no shared base, no
  `git worktree` machinery. Two local dirs patched from the same upstream source get
  **independent** gitdirs (test 023).
- **Metadata (ADR-001)**: `local_path` (user key, dedup key), `worktree` (the crossed dir;
  equal to `local_path` in 0.5.0, stored explicitly), `gitdir` (the bare gitdir). All
  repo-relative; nothing absolute is ever stored. A missing `worktree` is read as
  `local_path` (Go) so older metadata keeps working.
- **Work tree materialization**: `git --git-dir=<gd> --work-tree=<patch> read-tree -mu HEAD`.
  The crossed dir must exist first. `core.worktree` is never used (relative resolves from
  the invocation CWD; absolute breaks portability) — the pair comes from the environment.
- **Sparse filter**: the gitdir is BARE, and `git sparse-checkout` refuses to run there,
  so the plumbing is written directly: `config core.sparseCheckout true` plus
  `info/sparse-checkout` containing `<remote_path>/` (trailing slash required).
  Whole-repo patches (`remote_path = "."`) get no sparse config and no sparse-checkout file.
- **D3 nesting**: the work tree mirrors the upstream ROOT; `remote_path` is only a sparse
  filter. `patch demo:main:docs vendor/docs` → `vendor/docs/docs/guide.md`.
- **No `.git` file in the crossed dir** — that is what lets the primary repo track the
  patched files as normal blobs (not a gitlink/submodule).
- **Upstream ops**: `GIT_DIR`/`GIT_WORK_TREE` are exported by the passthrough (the bare
  `git cross <git-args>` fall-through; `_gitcmd` in the reference — one of its core
  pieces). Plain `git` inside a crossed dir targets the primary repo.
- **Passthrough contract (ADR-002)**: requires a patch context; outside one it exits 1
  with a hint. It never falls back to plain git on the primary repo.
- **Crossed-dir recognition is path-segment aware**: a CWD/path matches a cross only on
  an exact `local_path` or a `<local_path>/...` prefix (longest match wins). A sibling
  directory that merely shares a name prefix (`infra/ipxex` next to `infra/ipxe`) is
  NOT patch context; any depth inside the crossed dir is. Git `!`-aliases (the
  `git cross` entry point) run from the repo ROOT — the caller's real CWD is
  recovered from git's `GIT_PREFIX` env (Go `cwdRepoRelative`; the Just root
  wrapper feeds it into `USER_CWD`). `git cross --debug <git-args>` (or
  `CROSS_DEBUG=1`) prints the resolved context + the exact git invocation.
- **`update` / `resolve` (ADR-003, three phases)**: 
  1. fetch EVERY patch into its mirror (`git --git-dir=<gd> fetch origin
     +refs/heads/<b>:refs/remotes/origin/<b>`; bare clones have no tracking refspec).
     Fetching is innocent: refs only, no work tree.
  2. per patch, in order: `git -C <repo> ls-files -u -- <P>` (pending conflict → skip),
     `git -C <repo> diff --name-only -- <P>` (unstaged edits → refuse; staged ones are
     safe because the apply merges into the index).
  3. import the mirror's objects into the USER's repo (`git -C <repo> fetch <gd> <ref>`,
     FETCH_HEAD only) — **never** `GIT_ALTERNATE_OBJECT_DIRECTORIES`, which makes the
     user's index reference blobs it does not own (`fatal: unable to read tree`).
     Then a local `git fetch <gd> <ref>`, two throwaway-index trees
     (`read-tree --prefix=<P>/ {BASE,THEIRS}` → `commit-tree` = BASE + DELTA), and
     `git -C <repo> cherry-pick -n DELTA`: land upstream + re-apply the user's work in
     one 3-way apply. `--no-resolve` adds `-X theirs` (upstream wins, no markers).
     On success only, `git --git-dir=<gd> update-ref refs/heads/<b> <THEIRS>`.
  A collision leaves markers + unmerged paths **in the user's repo**; `rerere` records
  and replays there. 30 local changes cost ONE resolution round (the upstream side is
  what gets squashed). `cherry-pick -n` needs no identity and writes **no**
  `CHERRY_PICK_HEAD` — pending state is `ls-files -u`.
- **`resolve`**: thin wrapper — list unmerged paths; `--continue` refuses while
  `ls-files -u` is non-empty, else advances the mirror and tells the user to commit;
  `--abort` = `git -C <repo> checkout -f HEAD -- <P>`. It never invents merge logic and
  never commits. (Go-only since v0.5.1; the Just reference has a stub.)
- **`update` is all-patches-at-once**: a conflict does not stop the run; remaining
  patches still land and the summary counts `updated` / `skipped` / `need attention`.
- **`ls` DIFF** compares the crossed dir against the mirror HEAD through a throwaway
  index and `git diff --quiet HEAD -- <remote_path>` (**not** `diff-index`, which does
  not refresh the stat cache and reports everything modified). Only the mapped subtree
  is compared, because the mirror index is sparse and written once at `set` time.
  The mirror is BARE — the diff MUST name the work tree (`--work-tree=<crossed dir>`;
  without it git refuses with "must be run in a work tree"), and a failing diff
  reports `Error`, never a silent `Clean` (v0.5.1 bugfix).
- **`update` (incl. its re-adoption y/N prompt) is Go-only** (v0.5.1): Go owns the
  prompt (`Delete '<abs path>' and re-adopt it from upstream? [y/N]:`, default No;
  `--force` auto-applies the yes — with the uncommitted-changes guard). The Just
  reference has no `update` at all (stub); the whole update/resolve flow lives in
  Go. With `wipe` also Go-only, the reference has NO interactive prompts left.
- **Stdin on recipe chains**: any stdin-capable command (git `ls-remote`/`clone`/
  `fetch` via ssh, or `jq`/`grep`/`cat` without a file argument) silently drains
  piped input before a later `read` can see it; redirect `</dev/null` where
  stdin is not needed. A `while read ... end < file` loop also hands that file
  to every command inside the loop — nested recipes never see the outer stdin.
- **Opt-in shallowness**: `git config cross.depth N` / `cross.filter blob:none`; the plain
  default is a full clone. Local test fixtures need `file://` URLs (depth is ignored on
  plain local paths).
- **`compare` is GONE (0.5.0)**: the crossed directory *is* upstream's work tree, so
  there is no second checkout to compare against — `git cross diff` inside the patch
  already diffs local edits vs upstream `HEAD`. Removed with it: the `compare`/`cmp`
  commands, `cross.dirdifftool` ({left}/{right} placeholders, the `nvim`/`vim` DirDiff
  default), `DIRDIFF_EXCLUDES`/`DIRDIFF_IGNORE`, and the temp `git archive` export.
  A leftover config key is ignored; `git cross compare` now falls through to the
  passthrough. Test 021 was retired with the command (017 keeps the fzf ladder,
  009/019 assert the retirement).
- **`rerere` in TWO places**: the primary repo config (patches are primary-tracked, and
  the ADR-003 apply runs there, so `update` REPLAYS recorded resolutions from
  `<repo>/.git/rr-cache`) and EVERY patch gitdir (standalone — does not inherit, keeps
  its own `rr-cache`, used by the manual `pull -r` flow). `set`/`init` announces it,
  `set` enables it silently, `update` re-ensures it in each gitdir. `rerere.autoUpdate`
  is deliberately left unset (a replay still stops for review).
- **Shell integration (Go-only since v0.5.1; `xgit` removed)**: `cd`/`wt` are hidden
  from help (a subprocess cannot cd the caller's shell); they print only the path
  (hints/rows → stderr). `comp` defines the `xcd` wrapper (plus `gx`/`cr`) that does
  the real `cd` — and `gx cd [path]` cds too (`gx` is a shell function; `git x cd`
  cannot). fish needs `git cross comp fish | source` (fish joins multi-line
  substitutions with spaces). `set` prints the shell-appropriate one-liner.
  powershell gets completions only.
- **Interactive picker** (Go-only since v0.5.1; the reference's `_select_patch` was
  removed with `cd`): `selectPatchInteractive` (Go) serves `cd`/`del`-miss. Rows are
  `<local_path padded><TAB><local_path>` with
  `width = max(len(local_path)) + 2` clamped to 16-48; the visible label is
  `remote:remote_path` (+ `(branch)` when not `main`). fzf runs with
  `--delimiter \t --with-nth=1`; the selection is the last TAB field.
- **Patch rows**: bare `git cross` and path-miss cases print `local_path<TAB>gitdir`;
  hints go to stderr and the command exits 1 where nothing was resolved.
- **`list --raw` schema (ADR-001)**: remotes first (`REMOTE_NAME<TAB>REMOTE_URL`), then
  patches (`REMOTE<TAB>REMOTE_PATH<TAB>LOCAL_PATH<TAB>WORKTREE<TAB>GITDIR<TAB>BRANCH`);
  `LOCAL_PATH` stays field 3. No banners, no borders, deterministic order.
- **Crossfile format**: `cross use <name> <url>` and `cross set <remote>:<branch>:<path> <local>`.
  `update` is STRICT: any other command line is an error (which is why the repo's own
  Crossfile must not contain retired commands). `del` deletes Crossfile lines by
  structured field matching (last field == local_path).
- **Retired in 0.5.0**: `.crossignore` filtering, the `.git`-mirror diff, rsync,
  `push`/`sync`/`replay`/`exec`, linked worktrees, primary-repo remotes.

## Refactoring Priorities

1. **Split `src-go/main.go`** (~2000 lines) into command files — it is the only full
   implementation now; all new work lands there.
2. **Restore ignore support** (`.crossignore` replacement) via pathspec excludes in the
   passthrough if the feature is still wanted.
3. **`git cross doctor`** — self-heal metadata/gitdir mismatches (repo moved, gitdir
   deleted, stale sparse patterns).
