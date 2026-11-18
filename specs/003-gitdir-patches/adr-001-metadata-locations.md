# ADR-001 — Metadata location fields for v0.5.0 (gitdir / worktree / local_path)

**Status:** Accepted (2026-11, user decision)
**Supersedes:** the v2 metadata schema in `plan.md` §4 (which carried `gitdir` only)

## Context

v0.5.0 replaced *sparse linked worktree + rsync* with a **standalone bare gitdir per
patch**, whose **work tree is the patch directory inside the primary repo**. The
initial v2 metadata entry kept just the gitdir:

```json
{"remote":"khue","remote_url":"...","remote_path":"metal",
 "local_path":"deploy/metal","gitdir":".cross/worktrees/khue/deploy_metal","branch":"master"}
```

That left the work tree *implicit* (`worktree == local_path`). The ambiguity showed up
immediately:

- tooling and tests read `.patches[].worktree` (v0.4 key) and got `null`;
- `list --raw` had no column for "where the work tree actually is";
- a reader of `metadata.json` cannot tell whether the patch directory is derived or
  stored, nor that D3 nesting puts the upstream subtree at `<patch>/<remote_path>/`.

## Decision

A patch entry records **every location explicitly**:

```json
{
  "remote": "khue",
  "remote_url": "https://github.com/khuedoan/homelab.git",
  "remote_path": "metal",
  "local_path": "deploy/metal",
  "worktree": "deploy/metal",
  "gitdir": ".cross/worktrees/khue/deploy_metal",
  "branch": "master"
}
```

| Field | Meaning | Absolute or repo-relative |
|---|---|---|
| `local_path` | The user's key: CLI argument, Crossfile argument, patch selector. Dedup key. | repo-relative |
| `worktree` | The work tree git operates on: the patch directory in the primary repo. **Equal to `local_path`** in v0.5.0. | repo-relative |
| `gitdir` | The standalone bare gitdir holding `.git` content (objects, refs, sparse config, rerere, remotes). | repo-relative |

Rules:

1. **`worktree` is stored, not derived.** It is written whenever an entry is created
   or rewritten, and kept equal to `local_path`. Readers must not have to infer it.
2. **Nothing absolute is ever stored** (portability; see plan.md L4). All three paths
   are repo-relative and resolved against `git rev-parse --show-toplevel`.
3. **`worktree == local_path` today.** They are separate fields because they are
   separate concepts; if v0.6 allows a work tree outside the patch path, only
   `worktree` changes and every reader keeps working.
4. **D3 nesting is not encoded in metadata.** `remote_path` stays a *sparse filter*,
   and the work tree mirrors the upstream root, so the upstream subtree lives at
   `<worktree>/<remote_path>/`. That is a property of the tree layout, not a location.
5. **Machine rows keep the state path.** `<local_path>\t<gitdir>` stays the one-row
   form (bare `git cross`, `_list_patches`, path-miss hints): the work tree is already
   named by `local_path`, so the non-redundant extra column is the gitdir.
6. **`list --raw` patch columns:**
   `REMOTE, REMOTE_PATH, LOCAL_PATH, WORKTREE, GITDIR, BRANCH`
   (`REMOTE_NAME, REMOTE_URL` for the remotes block). `LOCAL_PATH` stays field 3 so
   existing `cut -f3` consumers keep working; `WORKTREE` and `GITDIR` are new/kept.

## Consequences

- v0.4 keys `id` and the old worktree semantics remain gone; `worktree` returns as a
  *field with a new meaning* (the in-repo patch dir), which also restores v0.4-era
  reader compatibility for "where do I look at files".
- `compare` still exports the upstream tree to a **temp dir** for the left side; that
  temp path is intentionally not stored in metadata.
- Tests should resolve locations via `jq` on `metadata.json`
  (`.patches[] | select(.local_path == "...") | .gitdir`), never by globbing
  `.cross/worktrees/` or guessing hash suffixes.
- Both implementations must write all three fields on `patch` and preserve them on
  `update`/`remove`; a missing `worktree` in an older metadata file is read as
  `local_path` (defensive read, no migration command).

## Implementation checklist

- [x] Justfile.cross: write `worktree` in the patch metadata entry; `list --raw` columns.
- [x] src-go/main.go: `Patch.Worktree` with a read fallback to `LocalPath`; same columns.
- [ ] Test updates in progress (`test/007`, `test/009`, `test/010`, …) — tracked in
      `specs/003-gitdir-patches/progress.md`.
