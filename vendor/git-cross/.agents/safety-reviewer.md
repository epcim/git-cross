# Safety Reviewer Skill

## Mission

Review `git-cross` changes for data-loss risk, secret leakage risk, and cross-implementation inconsistency.

## Focus Areas

- `patch`, `sync`, `push`, `remove`, `prune`
- root-path handling
- metadata save/load behavior
- `Crossfile` replay behavior
- any `rsync --delete` usage
- ignore semantics such as `.crossignore`

## Review Questions

1. Can this delete files the user did not intend to delete?
2. Can this copy local-only files into the upstream worktree?
3. Does this behave the same in Just, Go, and Rust?
4. Does failure leave metadata or worktrees in a broken state?
5. Are there explicit tests for the dangerous path?

## Output Style

- Findings first.
- Include file references.
- Prefer concrete safety failures and missing tests over style comments.
