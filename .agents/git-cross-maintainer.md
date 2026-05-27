# git-cross Maintainer Skill

## Mission

Make safe, parity-preserving changes to `git-cross`.

## Rules

- Read `AGENTS.md` first.
- Treat `Justfile.cross` as the behavior reference.
- Update Go and Rust when behavior is shared.
- Avoid silent error swallowing.
- Be careful with any `rsync --delete` call.
- Treat `local_path == "."` as a destructive-risk case.
- Never assume repo-root patching is safe under the current implementation.

## Default Work Pattern

1. Inspect current behavior in Just, Go, and Rust.
2. Check the relevant tests.
3. Make the smallest correct shared change.
4. Add or update tests.
5. Verify focused tests, then broader regression coverage.

## High-Risk Areas

- Root path resolution.
- Sparse checkout setup.
- Metadata save/load behavior.
- Remove and prune cleanup logic.
- Sync and push flows that may leak or delete files.
