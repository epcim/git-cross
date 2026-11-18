---
name: git-cross-maintainer
description: Use when changing `git-cross` behavior in `src-go/main.go` (the only full implementation) or the core-command reference `Justfile.cross`, or related tests. Focus on path safety and minimal correct changes.
---

# git-cross Maintainer

- Read `AGENTS.md` first.
- v0.5.1 scope: Go (`src-go/main.go`) is the primary and only full implementation; `Justfile.cross` is the CORE-command reference (use/set/del/ls/cfg + passthrough) — touch it only for metadata schema or core-command fixes. Rust was deleted.
- Update the Just reference too only when a CORE command's behavior changes.
- Be careful with `rsync --delete` and any root-path handling.
- Prefer the smallest correct shared change.
- Add or update regression tests before considering behavior work complete.
