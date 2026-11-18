# specs

- **`003-gitdir-patches/`** — the **living** design/ADR set for the current
  (v0.5.x) architecture: bare gitdir per cross, in-repo work tree, ADR-001
  metadata locations, ADR-002 passthrough contract, ADR-003 update/resolve.
  Read the ADRs before changing the metadata schema or the passthrough.

Retired and deleted (v0.5.2):
- `001-cross-test-strategy/` — Rust-era test strategy, superseded by
  `TESTS.md` + `test/` + `.agents/skills/git-cross-parallel-tests/`.
- `002-root-overlay-patching/` — pre-v0.5 root-overlay/rsync design, retired
  with the gitdir architecture; the open root-patch/`.crossignore` item lives
  in `TODO.md` and `AGENTS.md` → "Gaps Worth Addressing".
