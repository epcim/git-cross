# ADR-003 — `update` lands upstream; `resolve` re-applies your changes (rerere-aware)

- Status: Accepted (2026-11). Supersedes the 0.5.0 "refuse or overwrite" pass 3
  and the earlier rebase-in-a-temp-repo sketch.
- Related: ADR-001 (metadata locations), ADR-002 (passthrough needs a patch context)

## Context

The patch gitdir (`.cross/worktrees/<remote>/<patch>/`) is an **upstream mirror
only**. `push` was removed, so nothing is ever committed or merged there. Your
version of the patched files lives in **your repo** (the patch dir is
primary-tracked content), and your commits are the only history that matters.

`update` today fetches into the mirror and then either refuses (modified patch
dir) or `reset --hard`s the mirror's work tree over the patch dir — it never
merges, so the mirror's `rerere` can never fire, and a divergence is destroyed
(parked in an unread `refs/cross/backup/*`).

The desired behaviour is two independent steps:

1. **land** the new upstream content in the patch dir;
2. **re-apply** the user's change on top of it, reusing a previously recorded
   resolution when `rerere` knows one; if that fails, keep the state for a manual
   rebase.

## Decision

**Land with the mirror, re-apply in the user's repo, one operation.**

### `git cross update [--resolve|--no-resolve] [path]`

1. Interpret `Crossfile`, create missing patches (unchanged).
2. **Fetch every patch** into its mirror (refs only; innocent; unchanged).
3. Per patch, in this order:
   - **uncommitted modifications in the patch dir** → refuse:
     `'<path>' has modified files; commit them in your repo first`. The checkout
     would destroy the only copy; committed work is safe and is `resolve`'s input.
   - **unmerged index state** already present under the patch path → skip with
     `pending conflict in <path>; run git cross resolve`.
   - else **land + re-apply** (default; `--no-resolve` lands only):
     a. import the needed objects into the user's repo with a local
        `git fetch <mirror> <ref>` (FETCH_HEAD only: no remote, no lasting ref) —
        the user's repo must own every object it will reference;
     b. build two synthetic commits with throwaway indexes:
        `base` = mirror tree at the pre-fetch HEAD, `delta` = mirror tree at the
        fetched rev, both `read-tree --prefix=<local_path>/`;
     c. `git cherry-pick -n <delta>` in the **user's repo** (no identity needed,
        nothing is committed);
     d. clean → the new content and your changes are staged in the patch dir;
        the mirror branch advances; report `Updated <path>` and let the user commit;
     e. conflict → unmerged stages under the patch path, markers in the files,
        `rerere` records/replays in `<repo>/.git/rr-cache`; report
        `conflict in <path>; resolve with git add + git commit (or git cross resolve)`.
4. `--no-resolve` = step 3b replaced by `git cherry-pick --quit`-free "take
   upstream as-is": the patch dir is set to the fetched content and the user's
   change stays only in their history (`git cross resolve` can re-apply later).

### `git cross resolve [--continue|--abort] [path]`

Thin by design; it never invents merge logic and never commits.

- default (no flags): re-run the land+re-apply step for the patch if the delta has
  not been applied yet, then report the unmerged paths. Equivalent to
  `git cross update --no-fetch --resolve <path>`.
- `--continue`: refuse while `ls-files -u` under the patch path is non-empty;
  otherwise clear any sequencer state and print the one line the user needs
  (`git commit` in their repo).
- `--abort`: restore the patch path to `HEAD` (discarding the partial apply).
- with nothing pending: exit non-zero and say so.

### `stat`

Gains a `PENDING` state (unmerged stages under the patch path, or a leftover
sequencer directory), so a half-resolved patch is visible before anything else runs.

## Evidence (spike, 2026-11)

User repo, patch `up:src/lib lib`, user committed an edit, upstream moved on the
same file, delta synthesized from the mirror:

- `cherry-pick -n` conflicted with **no identity configured** (nothing to commit).
- Only `lib/src/lib/a.txt` was unmerged; the sparse-unrelated paths never appeared.
- `rerere` recorded into **`<repo>/.git/rr-cache`** (one entry); replay of the same
  delta printed `Resolved 'lib/src/lib/a.txt' using previous resolution.` and left
  zero markers with the merged content.
- `git ls-files -u` reports the conflict; **`CHERRY_PICK_HEAD` is NOT written by
  `-n`** — pending state must be detected by cross, not by `git status`.
- The mirror was never written to (no refs, no work tree); only two dangling
  commits/trees per update are created in the user's object store (gc-able).
- Borrowing objects with `GIT_ALTERNATE_OBJECT_DIRECTORIES` was tried first and is
  **wrong**: the user's index then references blobs that only exist in the mirror,
  so later `git add`/`commit` in the user's repo fails with
  `fatal: unable to read tree`. A local `git fetch` import is the fix.
- Only **unstaged** changes block an update (`git diff --quiet -- <path>`): a
  cherry-pick merges into the index, so staged content (e.g. files just added by
  `patch`) is never lost.

## Consequences

Positive: the mirror stays a pure upstream mirror; upstream content always lands;
your change is re-applied rather than destroyed; `rerere` reuse comes for free in
the repo that owns the resolutions; no new state directory, no temp repo, no
metadata changes; `--no-fetch` makes `resolve` a cheap repeat.

Negative / accepted:
- Two dangling objects per update in the user's object DB.
- While unresolved, the user's repo carries unmerged index stages for the patch
  path; a stray `git commit` fails until they are resolved (safer than markers
  being committed silently).
- Conflict markers are real files in the repo; cross cannot prevent a later
  `git add -A` from committing them without a resolution.
- Shallow/partial mirrors (`cross.depth`, `cross.filter`) may lack the pre-fetch
  tree for a path; detect and say "re-clone or unshallow", not "diverged".
- Just/Fish currently swallow the errors this depends on (`_fetch_patch` captured
  with `2>/dev/null`, `_apply_patch` exit ignored) — fix before layering on.

## Reversal conditions

- If synthesizing commits in the user's repo proves unacceptable (object-store
  hygiene, bare-worktree users) → fall back to `git diff base theirs -- <path>` +
  `git apply -3`, accepting the loss of automatic `rerere` replay.
- If per-patch partial application across 20 patches proves confusing → make
  landing atomic per patch and require an explicit `--resolve` (never auto).
- If marker leakage causes real incidents → quarantine variant (upstream variants
  under `.cross/conflicts/<patch>/`, no markers in the repo).

## Implementation plan

1. Go: delta synthesis + `cherry-pick -n` in pass 3, flags `--resolve/--no-resolve`,
   `resolve` command, `stat` PENDING, hard-fail summary when a fetch fails.
2. Just/Fish: same order of operations in `_apply_patch`, new `resolve` recipe;
   stop discarding `_fetch_patch` stderr/exit.
3. Tests: Go — `src-go/update_resolve_test.go` (5 integration tests: clean
   landing, unstaged refusal, conflict + abort, continue + rerere replay,
   `--no-resolve`). Shell integration — `test/026_update_resolve.sh` runs the same
   scenario against BOTH implementations; 009/018 rewritten for the new contract;
   007 syncs via `update` instead of `update` + `pull -r`.
4. Docs: CHANGELOG, README (`update`, `resolve`, `--no-resolve`), AGENTS command
   table + coverage matrix, `progress.md` (its "abort, local preserved" text is
   already stale).
