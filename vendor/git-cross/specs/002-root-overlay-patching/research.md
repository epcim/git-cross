# Research Notes: root overlay patching and `.crossignore`

## Current Blocking Findings

- `patch` and `push` currently behave like directory mirrors.
- Go `sync` still deletes local-only files on worktree-to-local sync.
- `status` and `diff` currently compare full trees instead of a managed file set.
- `remove` and `prune` are unsafe when `local_path` is `.`.

## Product Insight

This feature is not just "patch root". It introduces a second usage model:

- subtree mirror mode for vendoring
- root overlay mode for mixing upstream and local-only files safely

The implementation should make that distinction explicit.
