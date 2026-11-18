# ADR-002 — The git passthrough requires a patch context (fail early)

**Status:** Accepted (2026-11, user decision)
**Relates to:** ADR-001 (metadata locations), plan.md L8 (command namespace)

## Context

`git cross wt <git-args...>` and the bare fallback `git cross <native-git-cmd> ...`
run git with `GIT_DIR=<bare gitdir>` and `GIT_WORK_TREE=<patch dir>` so that
`status`/`diff`/`log`/`push`/`pull`/`rebase` act on the patch's **upstream**.

v0.5.0 shipped with a fallback: when no patch could be resolved from the current
directory, the passthrough ran **plain git on the primary repository**. That is
indistinguishable from the intended behavior at the call site and actively
dangerous:

```bash
cd ~/proj            # repo root, NOT inside a patch
git cross pull -r    # v0.5.0: silently pulls THIS repository
git cross push       # v0.5.0: silently pushes THIS repository
```

The user's intent when typing `git cross <git-cmd>` is "operate on a patch's
upstream". If that cannot be configured, continuing with a different repository
is never the intent — plain `git` is already available for the primary repo.

## Decision

**The passthrough fails early when no patch context resolves.** It never falls back
to plain git.

- Resolution ladder (unchanged): current directory → containing patch (longest
  `local_path` prefix) → otherwise **error**.
- Message (stderr) names the problem and both remedies:

  ```
  ==> ERROR: not inside a patch directory: cannot configure GIT_DIR/GIT_WORK_TREE for an upstream context
    cd into a patch first:  git cross cd [path]
    for THIS repository use plain 'git' instead of 'git cross'
  ```

- Exit code `1` (a usage/context error, not a git exit status).
- Applies to both implementations: `gitPassthrough` (Go) and the `wt` recipe
  (Just/Fish). `git cross` with **no arguments** still prints patch rows and
  `-h`/`--help`/`--version` still work — only git arguments enter the passthrough.
- Application-level commands (`use`, `patch`, `update`, `remove`, `purge`, `set`,
  `stat`, `compare`, `list`, `cd`, `completion`, `shell-init`) are unaffected: they
  resolve their own paths and keep working from anywhere in the repo.
- Plain `git` **inside** a patch directory still targets the primary repo (that is
  how you commit patched files to your own project).

## Consequences

- `git cross pull -r` at the repo root now fails instead of pulling the primary.
- Scripts that relied on `git cross <cmd>` as a "git with extras" alias must use
  plain `git`; the completion wrappers (`crosscd`) are the documented way to enter
  a patch context.
- Tests assert the failure (exit ≠ 0 + the "patch directory" hint) rather than the
  old primary-repo fallback: `test/010_worktree.sh`, `test/025_gitdir_patch.sh`.
- No `--force`/`--primary` escape hatch is added in 0.5.0; plain `git` covers it.
