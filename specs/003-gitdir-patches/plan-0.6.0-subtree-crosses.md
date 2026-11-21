# Implementation plan 0.6.0 — subtree-rooted subdir crosses (ADR-004)

User decision (2026-11-21): ship D3(c) as a **special case** — whole-repo
crosses (`remote:.` → local) keep the exact current machinery (no synthesis,
no hooks, no graft; plain `pull -r`/`push` unchanged); only when
`remote_path != "."` does the subtree machinery engage. Goal: zero risk for
the common case, the reported UX bug fixed for subdir crosses. Fallback
ladder: ADR-004 (all entries work on released code).

Scope: **directories only** in 0.6.0; file-level `remote_path` (the
`dir_or_file` case, primitive proven) = 0.6.1 follow-up. Fish reference
parity (`set` + passthrough) is IN scope (tests 002/004/025 run both sides).

## Stages

### S1 — Go: core helpers (src-go/main.go)
- `emptyTree` const; `synthRef()/upstreamRef()` (refs/cross/synthesized/<b>,
  refs/cross/upstream/<b>).
- `synthesizeSubtree(gdAbs, rp, walkRange, baseTip)` — rev-list --reverse
  --topo-order walk; per commit: `rev-parse C:rp` (missing → empty tree),
  skip unchanged (outside-only); `commit-tree` with author+committer
  identity AND raw dates pinned from the source commit (deterministic),
  message preserved (`-F` from `%B`). Lab-proven algorithm.
- `writeCrossGuards(gdAbs)` — `hooks/pre-rebase` (allow `refs/cross/*`
  targets, else abort with `use: git cross pull -r`) + `hooks/pre-push`
  (abort with `use: git cross push`). Live-proven.
- `ensureGitdirIdentity(gdAbs)` — gitdir-local `user.*` fallback (bare
  clones have none; cross-ctx commits/rebases need it).

### S2 — Go: flows
- `set` (rp != "."): validate `HEAD:<rp>` exists AND is a tree (blob →
  "file-level remote_path: 0.6.1"); full synthesis → refs/heads/<b>;
  markers; NO sparse config; `read-tree -mu HEAD` (unchanged command,
  re-rooted result); hooks+identity; announce. Orphaned-gitdir reuse path:
  legacy (no refs/cross/upstream/<b>) → hard error with re-create hint.
- `update` pass 3 (`landUpstream`):
  - up-to-date check via `refs/cross/upstream/<b>` marker (synth vs real
    hashes are disjoint — the old HEAD==rev check never fires);
  - delta: base = mirror HEAD (its tree IS the subtree), theirs =
    `<fetched>:<rp>` (missing → empty tree = upstream deleted the subtree);
    existing `read-tree --prefix=<P>/` + cherry-pick machinery UNCHANGED;
  - legacy guard (no marker → error) + lineage check
    (`merge-base --is-ancestor refs/cross/synthesized/<b> refs/heads/<b>`);
  - `advanceMirror`: whole-repo unchanged + **index refresh**
    (`read-tree HEAD`) for ALL crosses (fixes the v0.5.x stale-index wart);
    subdir advances to the synthesized tip + both markers.
- `ls` DIFF (`patchDiffersFromUpstream`): subdir → `diff --quiet HEAD`
  (no pathspec — HEAD tree is the subtree); whole-repo unchanged.
- Passthrough interception (subdir only): `pull` → fetch → incremental
  synthesis (base = marker) → `rebase --onto <tip> <marker> refs/heads/<b>`
  (or `merge` for merge-mode; exotic args → hint). `push` → refuse-unless-
  clean-graft: fetch, build graft (temp index: `read-tree U^{tree}` +
  `read-tree -m --prefix=<rp>/` + `write-tree` + `commit-tree -p U`) in the
  gitdir, refuse if upstream also changed `<rp>` (pull first), then plain
  push. Whole-repo crosses: plain passthrough (unchanged).

### S3 — Go tests
- New `test/030_subtree_crosses.sh`: re-rooted layout; synthesis determinism;
  outside-only skipped; cross-ctx status/diff/log; update lands A/M/D
  re-rooted; intercepted `pull -r` (clean + conflict + `rebase --continue`);
  graft push (nothing outside rp/ differs, refusal when upstream moved);
  hook guards (plain pull/push abort with hints); lineage-check recovery;
  whole-repo control group (byte-identical layout + plain pull -r still works).
- New `src-go/subtree_test.go`: synthesizeSubtree determinism/incremental;
  graft-tree equality.
- Update (layout assertions only): 002, 003, 004, 007, 009, 012 (sparse →
  no-sparse + markers), 016, 018, 023, 025, 026, 027, 029; 019 (whole-repo)
  expected unchanged.

### S4 — Fish reference parity (Justfile.cross)
- `set`: synthesis loop (reuse the Go message strings), markers, no sparse,
  hooks, identity. `_gitcmd`: pull/push interception parity.

### S5 — Docs + release
- README (`set` semantics, plain-git contract table, pull/push flows),
  CHANGELOG 0.6.0 (breaking layout + migration: `git cross del <path> &&
  git cross update`, re-adoption prompt preserves local content), AGENTS.md
  (architecture + coverage matrix), ADR-004 → Accepted, VERSION + version
  string 0.6.0, test-update SKILL note (0.5→0.6 assertion mapping:
  `P/<rp>/*` → `P/*`, sparse → refs).

## Verification (per AGENTS.md order)
1. `bash test/030_subtree_crosses.sh` + the updated specific tests.
2. `bash test/003_diff.sh && bash test/004_update.sh` (regression-prone).
3. Parallel groups (skill) + serial `run-all.sh` + `go test ./src-go`.
4. Labs stay green (they are implementation-independent).

## Stop condition
If S2/S4 cannot be made green: keep whole-repo behavior, present the ADR
fallback ladder — no partial subtree machinery ships.
