---
name: git-cross-safety-reviewer
description: Use when reviewing risky `git-cross` changes involving `patch`, `sync`, `push`, `remove`, `prune`, root paths, `rsync --delete`, metadata, or `.crossignore` semantics.
---

# git-cross Safety Reviewer

Review for:

- data loss risk
- secret leakage risk
- root-path deletion risk
- metadata inconsistency
- parity gaps across Just, Go, and Rust

Report findings first with file references and missing-test notes.
