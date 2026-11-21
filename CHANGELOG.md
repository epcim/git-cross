# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.1]

### Fixed

- **`update` refuses untracked collisions EARLY** (was a raw cherry-pick
  error). When files the incoming delta would write sit UNTRACKED in the
  crossed dir (e.g. cross content that was never committed to the primary
  repo), `update` used to fail mid-flight with git's `untracked working tree
  files would be overwritten by merge`. It now refuses before any work:
  `untracked files would be overwritten by the update` + the colliding paths
  + the remedy (`git add <paths> && git commit`, or remove). Purely local
  untracked files still never block an update; porcelain-collapsed
  `?? dir/` entries are matched by prefix.
- **`update` heals pre-0.6 subdir gitdirs in place.** A v0.5 sparse-layout
  mirror (no `refs/cross/*` markers) is now treated like lost `.cross` state:
  warn, drop the stale registration + gitdir (disposable `.cross/` state —
  a stale mirror would poison a fresh `set` with its sparse config), then the
  re-adoption prompt (`[p]` preserves local content, `[y]`/`--force` stash
  dirty dirs first). **One `git cross update` is the whole 0.5→0.6
  migration.** The previous hint (`git cross del <path> && git cross update`)
  was wrong: `del` also deletes the crossed dir's content and the Crossfile
  line, so nothing would have been re-created.
- Hints corrected accordingly: the passthrough/`pull -r` pre-0.6 refusal now
  points at `git cross update` (which re-adopts); the orphaned-gitdir `set`
  hint now says `rm -rf <gitdir>` + `git cross update` with the Crossfile
  line intact, or `git cross wipe` (orphan sweep).
- Tests: 026 (untracked early refusal + recovery once tracked), 027 (pre-0.6
  heal: prompt, preserve, markers restored, follow-up update clean).

## [0.6.0]

### Changed — BREAKING: subdirectory crosses are subtree-rooted (ADR-004, D3(c))

- **The crossed directory IS the upstream subdirectory.**
  `git cross set mxc:main:demo/cluster-flux mxc-clusters/cluster-test` now checks
  out the CONTENT of `demo/cluster-flux` at `mxc-clusters/cluster-test/` —
  no `demo/` (or any other upstream path prefix) inside the crossed dir.
  (v0.5 mirrored the upstream root with `remote_path` as a sparse filter —
  the reported "demo/ root dir" behavior.) Whole-repo crosses (`remote:.`)
  are **byte-for-byte unchanged**.
- **How it works (both implementations, same messages):** each subdir gitdir
  carries a **synthesized subtree branch** (`refs/heads/<b>`, original
  authorship+dates — deterministic, outside-only commits skipped) plus two
  markers (`refs/cross/synthesized/<b>`, `refs/cross/upstream/<b>`), and the
  sparse config is gone — HEAD's tree already is the filter. `update` lands
  upstream through the same cherry-pick delta, now fed with subtree hashes;
  the mirror index is refreshed on every advance (also fixes stale-index noise
  in cross-ctx `git status` after updates).
- **`git cross pull -r` works inside a subdir cross** (intercepted:
  fetch → incremental synthesis → same-shape rebase; real conflicts, rerere,
  `rebase --continue`). Plain `git pull -r` / `git push` in the cross context
  are **refused by gitdir hooks** with actionable hints (`use: git cross
  pull -r` / `use: git cross push`) — strictly safer than v0.5, where a plain
  push silently pushed the mirror branch. The full plain-git audit:
  ADR-004 (read/blame/commit/rebase -i etc. all work; only the two history-
  mixing ops are guarded; raw `reset --hard origin/<b>`-style re-points are
  detected by a lineage check and recovered via re-adoption).
- **`git cross push` in a subdir cross = the graft**: upstream's tree with
  ONLY your subdirectory replaced, committed on top of the fetched upstream
  tip and pushed normally — never touches paths outside the subtree, refuses
  when upstream also changed it ("pull -r first, then push").
- **Migration (one-time per subdir cross):** re-create them — `git cross del
  <path> && git cross update` (or `git cross wipe <remote>` first). The
  re-adoption prompt preserves local content; your repo records the layout
  move as delete+add, committed once.
- **rerere-replay wind-backs** must now roll back three refs:
  `refs/heads/<b>` + both `refs/cross/*` markers (the up-to-date check reads
  the upstream marker).
- File-level `remote_path` (`set remote:main:path/to/file <local>`) is
  explicitly refused for now (0.6.1 backlog; the primitive is lab-validated).
- **The Just/Fish reference stays simple**: its `set` refuses subdir crosses
  with a Go-only hint (whole-repo crosses keep working in the reference);
  `ls`/`del`/the passthrough still operate on Go-created crosses, and the
  gitdir hooks guard plain git through the reference's passthrough too.
- **Zero-limitation alternative while the graft flow is verified in
  practice**: whole-repo cross at the original path layout + a relative
  symlink onto the upstream subpath (`set mxc:main:. vendor/mxc-src` +
  `ln -s ../vendor/mxc-src/demo/cluster-flux mxc-clusters/cluster-test`) —
  plain `pull -r`/`push` work through the link with no hooks (README:
  "Full git functionality, no graft").

## [Unreleased]

### Added

- **Crossfile validation: one declaration per key.** `git cross update` now
  rejects a Crossfile that declares the same remote **name** twice (`cross use
  mxc <urlA>` + `cross use mxc <urlB>` — the two URLs silently fought over
  which upstream a fetch means) and duplicate `set` lines for the same
  `local_path`. The error names both lines (number, URL/spec) and the remedy.
  Comments and blank lines stay legal.
- **`use` re-points a remote instead of duplicating it.** `git cross use mxc
  <new-url>` on an already-registered remote rewrites the existing Crossfile
  line (exactly one `use` line per remote name), updates the metadata remote +
  every cross's `remote_url`, and re-points `origin` in each gitdir of that
  remote — without this, `update` kept fetching the retired URL. Announced as
  `Re-pointing remote <name>: <old> -> <new> (metadata, Crossfile and gitdir
  origins follow)`.

### Fixed

- **A lost Crossfile no longer silences `update`.** When the Crossfile is
  missing or emptied while crosses are still registered in
  `.cross/metadata.json`, `update` fails loudly with recovery guidance instead
  of quietly printing "No crosses to update." — no git-cross command deletes
  records (`del` removes only its own `set` line), but a `git
  checkout`/`restore`/`clean` of an uncommitted Crossfile made the loss
  invisible while every later update silently did nothing. The whole records
  lifecycle (del -> re-declare -> update, idempotent re-runs, duplicate
  rejection, re-pointing) is pinned by `test/029_crossfile_records.sh`.

### Added

- **`git cross env` — an explicit upstream git context for plain `git`.**
  Run inside a crossed directory (any depth) or name one:

  ```sh
  eval "$(git cross env)"            # bash/zsh
  git cross env --fish | source      # fish
  ```

  It prints `export GIT_DIR='<gitdir>'`, `export GIT_WORK_TREE='<crossed dir>'`,
  `export CROSS_ACTIVE='<local_path>'` and `export CROSS_REMOTE='<remote>'` for the cross at `$PWD` (or for the
  `[path]` argument). Plain `git` in that shell then speaks the cross's
  **upstream** — `log`, `diff`, `status`, `push` — which is what third-party
  tools (editor git integrations, `gh`, `lazygit`) need; `git cross <args>` /
  `gx` / `cr` keep covering the shell. `--fish` prints `set -gx ...`, `--unset`
  the inverse, `--json` / `--gitdir` / `--worktree` / `--local-path` / `--remote`
  bare values for scripting. No cross or a missing gitdir is a hard error (exit 1, empty
  stdout) instead of a half-working environment.
- **`gxenv` wrapper** (printed by `git cross comp` / `shell-init`, bash+zsh+fish).
  `gxenv` loads the context into the **current** shell (`gxenv -u` unloads,
  `gxenv -s` gives the opt-in isolated nested shell). Nothing is written to disk
  — no `.envrc`, no chpwd/direnv hook.
- **The prompt is marked `[cross:<remote>] ` while the context is loaded** (e.g.
  `[cross:infra] `), so a modified terminal is obvious at a glance — no rc edit
  needed. The style is a template in `GIT_CROSS_MARKER`: `%r` expands to the
  remote (falling back to the local path), `%l` to the local path, default
  `[cross:%r]`; a value without placeholders is used verbatim
  (`GIT_CROSS_MARKER='[cross]'` restores the plain marker). Mechanically: bash appends to
  `PS1`; zsh appends from a `precmd` hook (registered on the built-in
  `precmd_functions`, so powerlevel10k/starship/oh-my-zsh cannot wipe it); fish
  wraps `fish_prompt`. `gxenv -u` removes the marker and restores the prompt
  exactly. `git cross env` also exports `CROSS_REMOTE` (and `--remote`) for
  hand-rolled prompts. Caveat: a bash `PROMPT_COMMAND` theme that rebuilds `PS1`
  wholesale hides the marker.
- **`xcd -` escapes**, and **bare `xcd` always asks** (`git cross cd --pick`
  skips the CWD auto-detect, so running it inside a cross no longer silently
  re-selects that cross). `--pick` keeps stdout for the chosen path: the
  fzf-missing fallback listing goes to stderr. Ctrl-D needs no handling — it ends
  the shell, so the context dies with it (use `gxenv -s` if you want a nested
  shell you can exit).
- **`xcd` now loads the context and leaving the dir unloads it.** `xcd <path>`
  cds *and* sets the upstream env (opt out with `GIT_CROSS_NO_AUTOENV=1`), and
  the env is dropped as soon as `$PWD` leaves the crossed dir — zsh via
  `chpwd_functions`, fish via `--on-variable PWD`, bash via an appended
  `PROMPT_COMMAND` (interactive shells). The leave-check is a single shell
  pattern match, no subprocess. `cd`-ing into a *different* cross only unloads;
  use `xcd`/`gxenv` to load there.

### Fixed

- **git-cross keeps working with the upstream context loaded.** Repo discovery
  now ignores a `GIT_DIR` pointing into `.cross/worktrees/` (previously
  `git cross ls` inside an `env`-loaded shell said "No crosses configured"
  because git answered the crossed dir as the toplevel), and `GIT_PREFIX` from
  the `git cross` git-alias is re-based onto the crossed dir, so the passthrough
  and `git cross env` stay idempotent in that shell.

### Note

- Keep the context process-scoped (that is what `gxenv` is for). Exporting it
  from `xcd` would outlive the `cd`: plain git anywhere in the shell would then
  target the mirror, and `add`/`commit` made there land on the mirror branch —
  invisible to your repo and overwritten by the next successful `update`.
### Added

- **`update`: re-adoption can now preserve local content** (`p` at the prompt).
  When a crossed dir exists but its `.cross` state is lost (whole registry gone,
  or only its gitdir), the old `Delete '<abs path>' and re-adopt it from
  upstream? [y/N]:` prompt is replaced by a 3-way choice:

  ```
  '<abs path>' exists but its .cross state is lost. Re-initialize how?
    [y] re-initialize from upstream (existing dir wiped)
    [p] re-initialize but preserve local (existing dir backed up, then copied back)
  Choice [y/p/N]:
  ```

  - `y` keeps the previous behavior (wipe + re-create from upstream).
  - `p` (new) moves the crossed dir aside under `.cross/backup-*/`, re-creates
    the cross from upstream, copies the backup back over the fresh work tree
    (local files win; files that are new upstream survive), re-stages it and
    removes the backup. On failure the backup is KEPT and its path is in the
    error, so local content is never lost.
  - `N`/EOF/anything else skips the cross (default, unchanged).
  `--force` still auto-applies the wipe without prompting; a preserved cross
  re-registers with DIFF=Modified and the upstream SHA.

- **`update`: a lost cross with uncommitted changes is no longer a hard error.**
  The old refusal (`<path> has uncommitted changes; commit or stash them first`)
  fired before the prompt, even with `--force`. Now the prompt is always reached
  and offers lossless paths:

  ```
  '<abs path>' exists but its .cross state is lost and it has uncommitted changes. Re-initialize how?
    [y] re-initialize from upstream (uncommitted changes stashed first)
    [p] re-initialize but preserve local (existing dir backed up, then copied back)
  Choice [y/p/N]:
  ```

  - `y` stashes the dirty work first (`git stash push -u -m "git-cross: changes
    in <path> before re-adoption" -- <path>`) and only then wipes; restore it with
    `git stash apply "stash@{0}"`. `-u` is required because a lost-registry dir
    is usually untracked.
  - `p` needs no stash: the whole dir goes through the backup/copy-back flow.
  - `--force` on a dirty dir stashes first as well — it skips the question, never
    the user's uncommitted work. If the work tree is still dirty after stashing,
    the update aborts instead of deleting anything.
  - Declining (`N`/EOF) leaves the dirty dir exactly as it was; no stash is
    created.

## [0.5.3] - 2026-11-18

### Fixed

- **GitHub Actions release workflow**: the goreleaser `before` hook ran
  `go mod tidy .`, which git rejects (`go: 'go mod tidy' accepts no
  arguments`) — every `v*` tag build aborted with `hook failed`. The hook was
  removed (go.sum is committed; goreleaser builds fine without tidying) and
  the invalid `setup-go` `cache-path` input was replaced with the correct
  `cache-dependency-path` (the cache was never restored before).
  `.goreleaser.yaml` deprecations were cleaned up too
  (`snapshot.name_template`, `archives.format`).

### Changed

- **`cd`/`wt` are hidden from `git cross --help`** (still functional): a subprocess
  cannot change the caller's shell, so advertising them invited the wrong
  expectation. The shell wrapper is renamed — **`xcd`** replaces `crosscd`
  (`git cross comp`) — and **`gx cd [path]` now actually changes directory**
  (`gx` is a shell function, so it can; `git x cd` / `git cross cd` still print the
  path + hint by design). The passthrough's missed-context hint points at `xcd`.
- Retired planning docs removed: `specs/001-cross-test-strategy/`,
  `specs/002-root-overlay-patching/`, `scripts/` (unimplemented fixture stub)
  and `implementation-plan-release.md` (pre-v0.5 Rust-era plan).
  `specs/003-gitdir-patches/` stays as the living ADR set (see `specs/README.md`).

### Fixed

- **`git cross <git-args>` via the usual `git` alias failed with "not inside a
  crossed directory" everywhere** — even from inside the crossed dir: git runs
  `!`-aliases from the REPO ROOT (not the caller's CWD), so the CLI always saw
  the repo root. The passthrough and every CWD auto-detect (`cd`, `resolve`) now
  resolve the user's real directory through git's `GIT_PREFIX` env (both
  implementations; the Just root wrapper feeds it into `USER_CWD`).

### Added

- **`--debug` / `CROSS_DEBUG=1` for the passthrough**: prints the resolved
  working directory, the matched cross, the `GIT_DIR`/`GIT_WORK_TREE` git will
  get and the exact git command — for troubleshooting alias/context issues:
  `git cross --debug status` or `CROSS_DEBUG=1 git cross status` (Go CLI);
  `CROSS_DEBUG=1` in the Just reference.

## [0.5.1] - 2026-11-18

### Changed: implementation scope — Go is the ONLY full implementation (no longer 1:1)

- **Go** (`src-go`) is the primary and only full implementation; all new features
  land there.
- **Just/Fish** (`Justfile.cross`) is a CORE-only prototyping / clean-code
  showcase reference: `use`, `set`, `del`, `ls`, `cfg`/`init` and the git
  passthrough. `update`, `resolve`, `wipe`, `comp`, `shell-init`, `cd` and `wt`
  are placeholder stubs printing `NOT IMPLEMENTED in Justfile version` (stderr,
  exit 1) — the same string is the test skip marker (`just_ref_implements` in
  `test/common.sh`): just-side sub-cases of Go-only commands SKIP; Go is the gate.
- **Rust** was deleted from the repository (`src-rust/` is gone).
- The `xgit` shell wrapper was removed from `comp`/`shell-init` output
  (`crosscd`, `gx`, `cr` remain; the optional `git x` alias hint is unchanged).

### Added: `update --force` + re-adoption of lost crosses

When a crossed directory exists but its `.cross` state is gone (the whole
registry deleted, or only its gitdir), `update` no longer silently overwrites:

- **Go** (primary) prompts `Delete '/abs/path' and re-adopt it from upstream? [y/N]:`
  — default **No** (empty/EOF input), `y`/`Y` adopts (wipe + re-create from
  upstream). Declined crosses are skipped untouched and counted in a summary
  warning. `--force` auto-applies the yes without prompting and also covers the
  gitdir-only-loss case (stale registration dropped, cross re-set).
- **Just/Fish** (reference): no `update` at all since the v0.5.1 scope split —
  it is a `NOT IMPLEMENTED` stub there (see the scope note above).
- Direct `git cross set` on an existing-but-unregistered directory now refuses
  with a hint instead of overwriting (both implementations).
- Unsafe local paths in Crossfile declarations (`../outside`) are a hard error
  in both implementations — nothing is deleted.
- Re-adoption **refuses to destroy uncommitted work**: the crossed dir is checked
  with `git status --porcelain -- <path>` before the wipe, and anything staged or
  unstaged refuses the run
  (`<path> has uncommitted changes; commit or stash them first (refusing to delete them)`).
  `--force` does not override it — a wipe is irreversible and lost `.cross` state
  gives cross nothing to replay the edits from. Both implementations abort the run
  on that refusal (nothing is deleted); a *declined* prompt is different — Go
  skips that cross and continues with a summary, Just/Fish aborts (they never prompt).
- `--force` on a healthy, registered cross is a **no-op** (it only appears in the
  lost-state branches).
- `update <path>` with a declined y/N prompt reports the skip
  (`<n> cross(es) not adopted: …`) and exits 0 instead of claiming
  `no Crossfile cross found for path: <path>`.
- The `set` refusal hint names a remedy that works without a `Crossfile` line:
  `(add it to Crossfile and run: git cross update --force — or remove the directory)`.

### Fixed

- **`ls` DIFF could never report `Modified` in the Go CLI** (always `Clean`):
  the health diff ran against the BARE mirror without naming a work tree, so git
  refused it (`fatal: this operation must be run in a work tree`, exit 128) and
  the error was swallowed. The diff now passes `--work-tree=<crossed dir>`, and a
  failing diff reports `Error` instead of a silent `Clean` (both implementations;
  the Just reference already named the work tree).
- **Crossed-dir recognition in the Just/Fish reference used a plain string
  prefix**: a sibling directory that merely shares a name prefix (`infra/ipxex`
  next to `infra/ipxe`) was wrongly treated as inside the cross. Matching is now
  path-segment aware (exact match or `<cross>/...`, longest match wins), like the
  Go CLI; any depth inside the crossed dir still resolves (`a/b/c/d`).

### Changed

- `update --resolve` is hidden from `--help` (it is the default and kept only
  for symmetry with `--no-resolve`, which now documents its real meaning:
  collisions resolve in upstream's favor, `-X theirs`).
- Justfile.cross no longer requires `SHELL` to be exported: it falls back to
  `bash` when the variable is unset (`env_var_or_default`).
- Stdin hygiene in Justfile.cross: ssh-spawning git commands
  (`ls-remote`/`clone`/`fetch`) run with `</dev/null` so they cannot drain
  piped stdin.

### BREAKING: command renames + crossed-directory terminology

Commands are renamed so cross never shadows git commands and the vocabulary
matches what the tool does ("cross" / "crossed directory", not "patch").
Old names fall through to the git passthrough and fail with a hint.

| old | new | notes |
|---|---|---|
| `patch` | **`set`** | set a cross directory (registers, bare-clones, materializes) |
| `remove` | **`del`** | delete a cross |
| `set` | **`cfg`** | configure the repo: Crossfile + rerere + `.gitignore` (`.cross/`); `init` kept as alias |
| `list` | **`ls`** | `list` kept as hidden alias |
| `completion` | **`comp`** | `completion` kept as hidden alias; help lists only `comp` |
| `wt <git-args>` | *removed* | the upstream git passthrough is the BARE `git cross <git-args>` fall-through only; `wt [path]` is now an alias of `cd` |
| `stat` | *removed* | health moved into `ls`: the crosses table (and `--raw` rows) gained **DIFF** (Clean/Modified/Missing Files/Missing GD) and **SHA** (short upstream commit per gitdir) columns; `git cross stat` falls through to the git passthrough |
| `purge` | **`wipe`** | same behavior (remote + all its crosses, unused-remote sweep, orphaned gitdir sweep); `prune`/`purge` fall through to the git passthrough |

Other changes in this batch:

- Help regrouped: **Crossed paths/dir operations** (`use set del cfg update resolve`)
  and **git cross overview** (`stat ls cd wt comp purge`); the "working inside a
  crossed directory" help text is now a plain sentence: inside a crossed dir,
  `git cross <git command>` performs its upstream git operations; anywhere else,
  plain `git` behaves as it would in your repo — `git cross` is a wrapper for
  crossed directories.
- `comp` now defines `xgit`, `gx`, `cr` (aliases for `git cross`, e.g. `gx add ./file`)
  next to `crosscd`; the `crosswt` wrapper is removed. `just install` also registers
  the git alias `git x` (`git x add ./file`).
- `git cross cd` prints a stderr hint when stdout is a TTY (a subprocess cannot cd
  your shell — use `crosscd`); piped output stays path-only.
- Crossfile declarations are now `cross set <remote>:<branch>:<path> <local>`;
  `update` still accepts legacy `cross patch ...` lines.
- Bug fix (Go): crossed-directory detection failed when the repo was reached
  through a symlinked path (`os.Getwd()` logical vs `git rev-parse --show-toplevel`
  physical); CWD is now resolved with `filepath.EvalSymlinks` — `git cross status`
  inside a crossed dir via a symlink works again.
- `cfg` now also ensures `.cross/` is in `.gitignore`.
- Clearer passthrough errors: a **mistyped cross command** now says so and
  suggests the closest one (`git cross commp` → `'commp' is not a git-cross
  command (did you mean: comp?)`), while real git commands keep the
  crossed-directory hint. `==> ERROR:` and `==> WARNING:` lines now go to
  **stderr** (stdout carries data only — `git cross comp fish | source` can no
  longer feed an error line to the shell).
- Bug fix (Go, reported on a pre-0.5 repo): stale v0.4 metadata whose `worktree`
  pointed into `.cross/worktrees/<name>_<hash>` made `git cross cd` print the
  hidden gitdir instead of the crossed directory. Stale worktrees are now
  self-healed to `local_path` on load (ADR-001); the `cd` hint is also
  shell-aware (fish users get the `git cross comp fish | source` form).
- Terminology sweep across code, tests, and docs: "patch(ed) directory" →
  "crossed directory", "patch(es)" → "cross(es)", messages updated accordingly.
  The metadata JSON schema (`patches` key, ADR-001) is unchanged.

### Docs

- README: new "The key trick: one directory, two git contexts" subsection — the
  `GIT_DIR`/`GIT_WORK_TREE` mechanism explained with a side-by-side table
  (plain `git` = your repo, `git cross <cmd>` = upstream context in the same
  directory).
- README: "Example run" — a complete first cycle (`use` → `patch` → edit →
  `git cross status`/`diff` → `update` → `stat`) with output captured from a
  real run.
- README: the key-trick section now shows the essence of `git cross` as a tiny
  `xgit()` wrapper function (`GIT_DIR` + `GIT_WORK_TREE` + `exec git`), plus a
  note that both repositories keep independent histories over the same files
  (commit via `git cross` → upstream; your repo still needs its own commit).
- README: new "Under the hood: what `git cross patch` does" — the fetch-first
  flow (bare clone into the hidden gitdir → sparse config → `read-tree -mu`
  into the crossed dir) showing that a `.git` file is never created in the
  crossed directory.
- README: new "Design Notes: Bare Gitdir vs `git worktree`" section documenting
  why the v0.5.0 design is a standalone bare gitdir per patch (no `.git` in the
  patch dir → normal blobs in your repo) instead of a linked `git worktree`,
  including the shared-objects trade-off and the `cross.depth`/`cross.filter`
  mitigation.

## [0.5.0] - 2026-11

### BREAKING: gitdir patches — no rsync, no linked worktrees

Each patch is now a **standalone bare gitdir** under `.cross/worktrees/<remote>/<patch>/`
holding the upstream `.git` content, while the **work tree is the patch directory inside
your repo**. The patched files are plain files tracked by your repository — not a gitlink,
and there is no `.git` pointer in the patch directory.

What this changes for users:

- **No rsync anywhere.** The patch directory *is* the upstream checkout; `update`
  fast-forwards it in place and never copies files.
- **Upstream git commands run in the patch's own context.** Inside a patch directory,
  `git cross <any-git-command>` (or the explicit `git cross wt <args>`) operates on the
  patch's upstream: `git cross status`, `log`, `diff`, `push`, `pull -r`, `rebase`.
- **Plain `git` still means your repository.** Committing the patched files, branching
  your project, etc. work exactly as before.
- **Your repo's git remotes are untouched.** `use` records the URL in `.cross/metadata.json`.
- **The passthrough requires a patch directory.** Outside one it fails early with a hint
  instead of silently running git on your repo (so `git cross pull -r` at the repo root
  can no longer pull the wrong repository). See `specs/003-gitdir-patches/adr-002-*.md`.
- **No migration path.** `.cross/` is disposable: `rm -rf .cross && git cross update`
  rebuilds everything from your `Crossfile`.

#### Command renames (cross must not shadow native git)

| v0.4 | v0.5 |
|---|---|
| `status` | **`stat`** (`git cross status` is now the native passthrough) |
| `prune` | **`purge`** (`git cross prune` is now the native passthrough) |
| `init` | **`set`** (`init` kept as an alias — native `git init` is unobtainable inside a repo) |
| `diff` (dedicated command) | **passthrough**: `git cross diff` = `git diff` vs upstream inside a patch |
| `push` / `sync` / `replay` / `exec` | removed; `git cross push` inside a patch pushes to **upstream** |

#### Added
- **`Metadata v2`** (ADR-001): every location is recorded explicitly — `local_path`
  (user key), `worktree` (the patch dir, equal to `local_path`), `gitdir` (the bare
  gitdir) — all repo-relative, with `remote_url` so remotes survive without the
  primary repo's git config.
- **`git cross pull -r` workflow**: edit upstream, `cd` into the patch, `git cross pull -r`;
  a conflict stops the rebase and you resolve it with `git cross add` +
  `git cross rebase --continue`.
- **`git cross resolve`**: update no longer refuses-or-overwrites. It fetches every
  patch first, then lands upstream in the patch dir and re-applies your committed
  changes on top (one three-way apply, so N local changes cost one resolution).
  Collisions are kept as normal unmerged paths + markers in *your* repo and finished
  with `git cross resolve --continue` (`--abort` reverts). `rerere` records and
  replays in `<repo>/.git/rr-cache`. `update --no-resolve` lands upstream as-is.
- **`rerere` in every patch gitdir** (each keeps its own `rr-cache`) in addition to the
  repo config, so resolutions are reused on both sides.
- **Opt-in shallow/partial clones** via `git config cross.depth N` / `cross.filter <f>`.
- **`list --raw`** patch columns: `REMOTE, REMOTE_PATH, LOCAL_PATH, WORKTREE, GITDIR, BRANCH`.
- `cross.filter` / `cross.depth` and the passthrough contract documented in `--help`.

#### Changed
- `compare` compares the **upstream export** (temp dir) against the patch directory;
  `{left}` may be absolute when it lies outside the repo.
- `update` refuses only **unstaged** edits (`'<path>' has modified files; commit them
  in your repo first`): staged content is merged, never lost. On success the mirror
  branch follows the landed revision, so the next run is incremental.
- Just/Fish `wt` passes arguments as fish `$argv`, so multi-word values
  (`commit -m "a b"`) reach git intact.

#### Removed
- **`compare` and the `cmp` alias.** The patch directory *is* upstream's work tree now,
  so there is no second checkout to diff against — `git cross diff` inside a patch
  already shows local edits vs upstream `HEAD`. Removed with the command:
  `cross.dirdifftool`, its `{left}`/`{right}` placeholders, the built-in
  `nvim`/`vim` DirDiff default, `DIRDIFF_EXCLUDES`/`DIRDIFF_IGNORE`, and the temp
  `git archive` export. A leftover `cross.dirdifftool` setting is ignored.
- `rsync` dependency (and its `check-deps` requirement).
- Linked `git worktree` machinery, the `.git`-mirror diff, and `git diff --no-index`.
- `.crossignore` filtering (status/diff overrides) — feature dropped in 0.5.0.
- The legacy `cross.diffTool` fallback (no backward compatibility).
- `gogs/git-module` and `zloylos/grsync` Go dependencies.

#### Fixed
- Go `remove` deleted the *next* patch's gitdir when removing a shared-source patch
  (slice pointer invalidation).
- Go `update <path>` exited with "no Crossfile patch found" after a preserved conflict.
- Go `compare` relativized the temp export against the repo root (`../../cross-cmp-…`).
- Just `update` never re-enabled `rerere` in a gitdir whose key was absent
  (`test (cmd) != true` lost the empty substitution in fish).

#### Tests
- Test suite trimmed to v0.5.0 only — 19 tests, no exclusion list in `run-all.sh`:
  deleted `005_replay.sh` (replay), `008_rust_cli.sh` + `011_rust_push.sh` (Rust is
  unsupported), `021_fzf_diff_compare.sh` (`compare` removed; the fzf ladder lives in
  017, 009/019 assert the retirement). Renamed to match the current command set:
  `007_stat.sh`, `010_cd_wt_passthrough.sh`, `015_purge.sh`,
  `017_cd_shell_integration.sh`.
- Updated 001-004, 007, 009-020, 023, 024 for v0.5 semantics; 010 rewritten to cover
  `cd`/`wt`/passthrough for both implementations, 025 remains the stage-1 gate.
  `SHELL=/bin/bash bash test/run-all.sh` → all 21 suites pass (20 shell + `go test`).

## [0.4.0] - 2026-11-11

### UX refresh — navigation, selection, listing, diff tool

#### Added
- **`git cross cmp`** - Short alias for `compare`; the canonical name is unchanged.
- **Grouped `--help` output** - Commands are listed under `Patch Lifecycle:`, `Repository:`, and `Inspect & Navigate:` instead of one flat list. `use` and `patch` appear first (in that order), and `cd`/`wt` stay adjacent. `git cross -h` still prints full help, and the help text documents `cross.dirdifftool` setup.
- **`completion`** - `git cross completion [fish|bash|zsh|powershell]` prints the shell completion script **plus** `crosscd`/`crosswt` functions that perform a real `cd` in the caller's shell (a child process cannot change it). The shell defaults to the basename of `$SHELL`; an unknown or undetectable shell exits 1 instead of guessing. fish uses `git cross completion fish | source` (multi-line `eval (...)` breaks in fish); `init` prints the matching one-liner for the caller's shell. `shell-init` is now hidden (kept for compatibility, wrappers only), and the clipboard fallback is no longer wired into `cd`/`wt`; its helper is kept isolated (unused) for possible reuse.
- **Conflict resolution memory (`rerere`)** - `init`, `patch`, and `update` enable Git's `rerere.enabled` in the shared repository config, so a conflict resolved once in a cross worktree is replayed automatically when the same conflict reappears on a later update. `init` announces the setting (and reports when it is already on), `patch` is silent, and `update` re-enables it for repositories set up before this change. `rerere.autoUpdate` is intentionally left unset (opt-in). Documented in README as "Conflict Resolution Memory (`rerere`)" and covered by `test/024_rerere.sh`, including a real resolve-then-replay scenario.
- **`list --raw` and `list --no-header`** - `--raw` emits tab-separated rows with no table borders and no `==>` banners; `--no-header` omits the header line. Raw column order is documented and fixed: `REMOTE_NAME<TAB>REMOTE_URL` first, then `REMOTE<TAB>REMOTE_PATH<TAB>LOCAL_PATH<TAB>WORKTREE<TAB>BRANCH`. Remote rows are sorted deterministically, remotes with distinct fetch/push URLs produce one row per URL without `(fetch)`/`(push)` suffixes, and the empty-state message goes to stderr in raw mode. On a terminal the columns are space-padded for readability; piped output stays TAB-separated.
- **Patch row listings** - Bare `git cross` prints one `local_path<TAB>worktree` row per patch to stdout instead of Cobra help (rows are aligned on a TTY, TAB-separated when piped; no hint line). Unresolved `compare` / `diff` / `remove` / `cd` / `wt` invocations print the same rows and exit 1 instead of dumping a usage block.
- **Tests 019, 020, 021, 023, 024** - Cover whole-repo patches plus row listings, grouped help and ordering, fzf-driven `diff`/`compare`, editor selection, `local_path` normalization, and `rerere` conflict-resolution memory.

#### Changed
- **BREAKING: `cd` / `wt` print a path instead of opening a shell** - Both commands print the absolute destination path to stdout (hints to stderr). They no longer start a subshell and no longer copy anything to the clipboard. Use `cd "$(git cross cd)"`, `cd "$(git cross wt)"`, or the `crosscd`/`crosswt` functions from `git cross completion`. Without an argument they auto-detect the current patch, then use `fzf`; if `fzf` is missing, rows plus a hint are printed and the command exits 1.
- **Behavior change: interactive `diff` selection** - With no path, `diff` resolves the patch via CWD auto-detect, then `fzf`, then rows + hint + exit 1. Previously, running `diff` from outside a patch directory dumped diffs for all patches.
- **`compare` selection ladder** - With no path, `compare` uses the same CWD auto-detect → `fzf` → rows + hint + exit 1 ladder and always operates on exactly one patch.
- **`cross.dirdifftool` template form** - The configured command may contain `{left}` / `{right}`, replaced with repo-relative paths while running with the repo root as cwd. The default is `nvim` when installed, otherwise `vim`, using `"+let g:DirDiffExcludes = '.git'" "+DirDiff {left} {right}"` (two `+cmd` arguments: `DirDiffIgnore=...` is not a vim command). `DIRDIFF_EXCLUDES` appends extra file/dir names to the exclusion list (`.git` is always ignored) and `DIRDIFF_IGNORE` ignores comma-separated keywords in diff content (converted to a very-nomagic `\V` regexp), e.g. `DIRDIFF_IGNORE=github.com,gitlab.com`. The legacy append form (for example `vim "+DirDiff"`) is deprecated.
- **Concise `update` warning** - Local edits now produce only the fact: `'<local_path>' differs from upstream; local copy preserved`. After the run, one generic path-less block suggests the next step (`git cross diff` / `git cross compare`, both fzf-assisted). The dirdiff configuration hint and the broken DirDiff invocation are gone.
- **Simplified upstream workflow** - `git cross update [path]` reads declarative `use`/`patch` entries from `Crossfile`, fetches upstream, fast-forwards sparse worktrees, and installs only when the local copy has no edits. Local edits are preserved while the worktree advances for manual comparison.
- **Config key renamed to `cross.dirdifftool`** - The comparison tool operates on directories (DirDiff and similar), so the key now matches the `DIRDIFF_*` environment variables. The pre-0.4 `cross.diffTool` key keeps working as a deprecated fallback (the new key wins when both are set); the README documents a one-line migration.
- **Manual contribution workflow** - Retired `push`; use `wt`, `compare`, and ordinary Git commands to manually copy and commit desired changes in the sparse worktree. The comparison tool is configured with `cross.dirdifftool` (see the Directory Diff Tool section in `README.md`).
- **Retired replay and arbitrary Crossfile commands** - `update` interprets only `use` and `patch`; hooks and shell commands are no longer run from Crossfile.
- **Supported implementations** - Go remains primary and Just/Fish the reference. Rust source is retained but no longer maintained; release artifacts are Go-only.
- **Retired sync workflow** - The prior stash/copy/rebase logic is removed from the supported CLI and Just recipes.
- **`.crossignore` entry syntax** - Override review behavior uses plain non-comment `.crossignore` lines: basename entries such as `.env`, basename globs such as `*.env`, and directory entries such as `config/`. Full `.gitignore` semantics are still not supported.
- **README workflow guidance** - The current `.crossignore` behavior is documented as a review-oriented workflow for local overlay files layered on top of upstream-managed content.

#### Fixed
- **Shared worktrees across local directories** - Patching one upstream source (`remote:branch:path`) into several local dirs is supported: they share a single hidden worktree (the hash covers remote/path/branch, not the destination). Just/Fish previously deduplicated metadata by worktree id and silently dropped the first local dir's entry; it now keeps one entry per `local_path` like Go. `remove`/`prune` delete the worktree only when no remaining patch references it. Test 023 covers both implementations, including removing one of the shared destinations.
- **Aligned interactive patch picker** - The `fzf` selector used by `cd`/`wt`/`diff`/`compare` printed raw TAB-separated fields, so a long remote name (e.g. `mxc-library`) ran into the next column and the header never lined up. Rows are now space-padded with `LOCAL_PATH` first, then `REMOTE:REMOTE_PATH` (branch shown in parentheses only when it is not `main`), the header uses the same padding, and the hidden `local_path` key is the last TAB field. Go and Just emit the identical layout.
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
