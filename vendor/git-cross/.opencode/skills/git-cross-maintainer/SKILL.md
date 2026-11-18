---
name: git-cross-maintainer
description: Use when changing `git-cross` behavior in `Justfile.cross`, `src-go/main.go`, `src-rust/src/main.rs`, or related tests. Focus on parity, path safety, and minimal correct changes.
---

# git-cross Maintainer

- Read `AGENTS.md` first.
- Treat `Justfile.cross` as the behavior reference.
- Update Go and Rust when the behavior is shared.
- Be careful with `rsync --delete` and any root-path handling.
- Prefer the smallest correct shared change.
- Add or update regression tests before considering behavior work complete.
