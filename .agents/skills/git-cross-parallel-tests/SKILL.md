---
name: git-cross-parallel-tests
description: Use when running or triaging the git-cross test suite during development (not CI). Batches test/NNN_*.sh into logical groups that are safe to run concurrently and dispatches one subagent per group, so a full pass costs ~15-20s instead of ~60s. run-all.sh stays the serial CI entry point.
---

# Running the git-cross suite in parallel groups

`test/run-all.sh` is the **CI/CD entry point**: one process, shared `testdir`,
strictly serial, plus `go test ./src-go` first. It is correct but slow to iterate
with. For development, split the suite into groups and run the groups in parallel
subagents.

## Why grouping is not just "split the file list"

1. **The 001-004-014 chain shares state.** `002` sources `001`, `003` and `004`
   source `002`, and `014` sources `002` with `CLEANUP=false`. Those files must
   run **sequentially in one worker**; running them concurrently corrupts each
   other's sandbox.
2. **`TESTDIR` must be unique per worker.** `test/common.sh` defaults
   `TESTDIR` to `mktemp -d` only when it is unset, so parallel workers must
   **not** export `TESTDIR` (and must not run `run-all.sh`, which exports a
   shared `testdir`). Each `bash test/NNN_*.sh` then gets its own temp sandbox.
3. **Balance by measured cost**, not by count (see table below).

## Groups (measured, single core)

| Group | Files (in order) | Cost | Notes |
|---|---|---|---|
| **A — chain** | `001 002 003 004 014` | ~7s | must be sequential; sources chain |
| **B — cli/ux** | `017 020 010` | ~10s | completion, grouped help, cd/wt |
| **C — paths** | `023 012 018` | ~13s | normalization, sparse, sandbox update |
| **D — repo shape** | `019 015 016` | ~17s | whole-repo patch, wipe, diff context |
| **E — gitdir core** | `013 009 026 024 025 029 030` | ~17s | real-world (network+skippable), Go CLI, update/resolve both impls, rerere, stage-1 gate, Crossfile records, subtree crosses |
| **G — go tests** | `go test ./src-go` | ~2s | `src-go/update_resolve_test.go` |

Wall time for A-E in parallel: **~20s**. Rebalance D/E if one lane dominates.

## How to dispatch

From the repo root, one subagent per group, all in the same working tree (tests
never write outside their own temp sandboxes, so no worktree isolation is
needed):

```js
const groups = {
  A: ["test/001_use.sh","test/002_patch.sh","test/003_diff.sh","test/004_update.sh","test/014_remove.sh"],
  B: ["test/017_cd_shell_integration.sh","test/020_help_groups.sh","test/010_cd_wt_passthrough.sh"],
  C: ["test/023_localpath_normalization.sh","test/012_sparse_checkout.sh","test/018_sbx_sandbox.sh"],
  D: ["test/019_whole_repo_patch_and_listing.sh","test/015_wipe.sh","test/016_diff_context.sh"],
  E: ["test/013_real_world.sh","test/009_go_cli.sh","test/026_update_resolve.sh","test/024_rerere.sh","test/025_gitdir_patch.sh","test/029_crossfile_records.sh","test/030_subtree_crosses.sh"],
};
const tasks = Object.entries(groups).map(([g, files]) => ({
  agent: "scout",
  task: `Run these git-cross tests SEQUENTIALLY, in this order, from the repo root:
${files.join("\n")}
Use: cd /path/to/git-cross && unset TESTDIR && SHELL=/bin/bash bash <file>
Do NOT export TESTDIR. Do NOT run test/run-all.sh. Stop at the first failure and
report: group id, failing file, the FAIL line, and the last 30 lines of output.
If all pass, report only: "group ${g}: PASS".`,
  output: `group-${g}.md`,
}));
return { workflow: "parallel", args: { tasks } };
```

Then additionally run `( cd src-go && go test -mod=mod ./... )` in the parent
(group G) — it is cheap and gives the fastest signal on the implementation.

## Verification gate

A change is not verified until **both**:

1. every group reports PASS (or a real failure you then fix), and
2. `SHELL=/bin/bash bash test/run-all.sh` passes once — the serial CI equivalent
   (it also proves no group depends on incidental parallelism).

Run `run-all.sh` only at the end, once: it shares `testdir` and cannot run beside
the workers.

## Gotchas

- **Do not `rm -rf testdir` while workers run** — workers do not use it; only
  `run-all.sh` does. Removing it mid-worker is harmless but pointless.
- **`013_real_world.sh` needs network**; it skips itself when
  `SKIP_NETWORK_TESTS=true` and when the Go toolchain is absent. Keep it in a
  lane that can afford the wait, or set the env var in offline environments.
- **No shared build races**: every test that needs the binary calls
  `ensure_go_bin`, which builds to its own path. `go test ./src-go` builds to a
  temp dir in `TestMain`.
- **Fish is required** for the `just`/fish variants; without it those variants
  skip silently (a PASS that tested less). Check for `SKIP:` lines in a group
  report.
- **Triage order on failure**: failing shell test → reproduce alone
  (`SHELL=/bin/bash bash test/NNN_*.sh`), then check whether
  `src-go/*_test.go` or a `Justfile.cross` recipe still encodes the old contract.
  Shell tests are integration level: they catch divergence the Go tests and the
  recipe do not.
