---
name: git-cross-regression-tester
description: Use when a `git-cross` behavior change needs test planning or verification, especially for sync, diff, status, patch, push, path resolution, and cross-implementation parity.
---

# git-cross Regression Tester

- Identify the most relevant focused test first.
- Require `test/003_diff.sh` for path or context changes.
- Require `test/004_sync.sh` for sync, push, delete, or ignore-model changes.
- Require broader parity coverage for shared behavior changes.
- Call out what remains untested.
