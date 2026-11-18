# Tests

The test suite lives in [`test/`](test/) and targets the **v0.5.0 gitdir
architecture** only. There is no exclusion list: retired tests were deleted with
their commands.

```bash
# everything (21 tests)
SHELL=/bin/bash bash test/run-all.sh        # or: just cross-test

# one test
SHELL=/bin/bash bash test/012_sparse_checkout.sh

# skip network-dependent tests
SKIP_NETWORK_TESTS=true SHELL=/bin/bash bash test/run-all.sh
```

`run-all.sh` is the **CI/CD entry point** (serial, shared `testdir`). When
iterating, run the suite as parallel groups instead — see
`.agents/skills/git-cross-parallel-tests/SKILL.md` (measured groups, ~20s wall).

```bash
# one group is just sequential files; never export TESTDIR in parallel workers
unset TESTDIR
for t in test/017_* test/020_* test/010_*; do SHELL=/bin/bash bash "$t" || break; done
```

`SHELL` must be exported so `just` can run the Fish recipes; the Go binary is
built on demand by `test/common.sh:ensure_go_bin`.

Three layers, by design:

| Layer | File | Role |
|---|---|---|
| readable reference | `Justfile.cross` | the git commands, in order (a workflow document that also runs) |
| implementation | `src-go/main.go` | the real CLI |
| Go tests | `src-go/*_test.go` | unit/integration of the implementation (`go test ./src-go`) |
| integration | `test/*.sh` | end-to-end; `run-all.sh` also runs `go test ./src-go` first |

Integration tests that take an `exercise()`/`xc()` dispatcher run the same scenario
through both implementations, so a divergence fails there.

## What each test covers

| Test | Scope |
|---|---|
| `001_use.sh` | `use` → metadata only, primary git remotes untouched |
| `002_patch.sh` | `set` → bare gitdir + in-repo work tree (D3 nesting) |
| `003_diff.sh` | `diff` as the patch-context passthrough |
| `004_update.sh` | edit upstream → `git cross pull -r` in the patch context |
| `007_ls_health.sh` | `ls` health columns (DIFF/SHA) (clean/modified/missing/conflict) |
| `009_go_cli.sh` | full Go CLI: use/set/cfg/ls/update/diff-passthrough/del/wipe |
| `010_cd_wt_passthrough.sh` | `cd`, `wt` and the native-git passthrough |
| `012_sparse_checkout.sh` | sparse plumbing (bare gitdir + `info/sparse-checkout`) |
| `013_real_world.sh` | real upstream (runtipi-appstore); network, skippable |
| `014_remove.sh` | `del` cleans gitdir, crossed dir, Crossfile, metadata |
| `015_wipe.sh` | `wipe <remote>` and the orphan-gitdir sweep |
| `016_diff_context.sh` | diff context inside/outside a crossed dir (ADR-002) |
| `017_cd_shell_integration.sh` | path printing, fzf picker, `comp` wrappers |
| `018_sbx_sandbox.sh` | concurrent local edit + upstream update (preserve) |
| `019_whole_repo_patch_and_listing.sh` | `remote:.` patches + row listings |
| `020_help_groups.sh` | grouped `--help` (Go only: CLI presentation) |
| `023_localpath_normalization.sh` | `./sub` normalization, independent gitdirs |
| `024_rerere.sh` | rerere in the repo config **and** every patch gitdir |
| `025_gitdir_patch.sh` | stage-1 gate: creation/checkout for both implementations |
| `026_update_resolve.sh` | update/resolve lifecycle (land, refusal, conflict, abort, continue, `--no-resolve`) — Go (the just variant skips: Go-only) |
| `027_update_force.sh` | `update --force` / y-N re-adoption of lost crosses (Go prompt matrix; the just variant skips: Go-only) |

Retired (deleted, not skipped): `005_replay`, `008_rust_cli`, `011_rust_push`,
`021_fzf_diff_compare` — `replay`/`push` are gone, `compare` was removed in
0.5.0; the Rust implementation itself was deleted in v0.5.1.

**Just/Fish variants (v0.5.1):** the reference implements core commands only.
Just-side sub-cases of Go-only commands (update, resolve, wipe, comp, cd, wt)
SKIP via the `just_ref_implements` probe in `test/common.sh` — a `SKIP (just)`
line is expected output, not a failure. Go coverage is the gate.

## Layout

```text
test/
├── common.sh                 # setup_sandbox, ensure_go_bin, create_upstream, assert_*
├── run-all.sh                # runner: discovers test/NNN_*.sh
└── NNN_name.sh               # one logical group each
```

Tests use `setup_sandbox` (a throwaway repo under `testdir/`) and
`create_upstream` (a local upstream served over `file://`). Assertions such as
`assert_file_exists` resolve against `$SANDBOX`, not the current directory.

Architecture, coverage matrix and the test-authoring procedure live in
[AGENTS.md](AGENTS.md) and `.agents/skills/git-cross-test-update/SKILL.md`.
