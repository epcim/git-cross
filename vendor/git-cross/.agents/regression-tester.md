# Regression Tester Skill

## Mission

Define the smallest sufficient regression coverage for `git-cross` behavior changes.

## Rules

- Map the changed command to the existing `test/NNN_*.sh` files first.
- Add focused regression coverage before broadening the suite.
- Treat path handling and sync behavior as high-risk.
- Require parity coverage when behavior changes across implementations.

## Default Verification Order

1. Relevant focused test.
2. `bash test/003_diff.sh` when path resolution or context behavior changed.
3. `bash test/004_sync.sh` when sync/push/delete behavior changed.
4. `bash test/run-all.sh` for larger feature work.

## Required Review Output

- What changed.
- Which tests already cover it.
- Which new tests are required.
- What remains untested.
