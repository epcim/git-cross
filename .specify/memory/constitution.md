# git-cross Constitution

**Version**: 1.0  
**Last Updated**: 2025-12-01

## Purpose

This constitutional document establishes the core principles governing the design, implementation, and evolution of `git-cross`. These principles ensure the tool remains simple, transparent, and reliable for vendoring parts of git repositories.

## Core Principles

### Principle I: Upstream-First Patching

**git-cross SHALL maintain a direct link to upstream repositories through git worktrees.**

- Vendored files originate from real git commits in upstream repositories
- Sparse checkout enables selective vendoring of subdirectories
- Local modifications remain traceable to upstream sources
- Bidirectional sync (pull and push) maintains relationship with upstream
- No duplication of git history in the consuming repository

**Rationale**: Submodules force entire-repo checkouts and create gitlinks instead of real files. git-cross provides physical files while preserving the upstream connection, enabling both local edits and upstream contributions.

### Principle II: Worktree Hygiene

**git-cross SHALL protect worktree cleanliness and prevent data loss.**

- Hidden worktrees (`.git/cross/worktrees/`) store upstream state
- Automatic stashing before pulls preserves local modifications in worktrees
- Commands abort on dirty state when modifications could be lost
- Explicit confirmation required for destructive operations
- `rsync` provides safe, predictable file synchronization

**Rationale**: Developer trust depends on predictable behavior. The tool must never silently discard work or leave repositories in inconsistent states.

### Principle III: Multi-Implementation Portability

**git-cross SHALL prioritize ease of distribution and performance through native implementations while maintaining a portable shell-based reference.**

**Current implementation**:
- **Native**: Rust (`src-rust/`) and Go (`src-go/`) provide high-performance, single-binary CLIs.
- **Reference**: `just` + `fish` implementation (`Justfile.cross`) serves as the PoC and logic reference.

**Standards**:
- All implementations MUST share identical command syntax and behavior.
- Use libraries where appropriate for Git interop (e.g., `gogs/git-module` in Go).
- Native versions SHOULD be self-contained for easy distribution.
- Maintain Bash coverage for broad CI compatibility.

**Code style**:
- Lower_snake_case for fish functions and variables
- Inline comments for non-obvious logic (especially index calculations)
- Helper functions (`_sync_from_crossfile`, `_resolve_context`) for modularity
- Four-space indentation, grouped exports/constants

**Rationale**: The tool must run on contributor machines (macOS, Linux) without complex installation. `just` provides excellent command-running ergonomics while `fish` handles complex data manipulation cleanly.

### Principle IV: Transparent Automation

**git-cross SHALL make implicit behavior explicit and observable.**

- Commands document themselves via `just help` and `just --list`
- `Crossfile` provides human-readable, reproducible configuration
- `just replay` reconstructs vendoring from `Crossfile` alone
- Operations log actions clearly (what's being fetched, synced, etc.)
- Environment knobs (e.g., `CROSS_NON_INTERACTIVE`) are documented
- `verbose` mode available for debugging

**Auto-save behavior**:
- `use` and `patch` commands automatically append to `Crossfile`
- Idempotent: running same command twice doesn't duplicate entries
- Crossfile structure: plain text, one command per line, comments allowed

**Rationale**: "Magic" automation breeds distrust. Users should understand what the tool does, how to reproduce it, and how to debug it.

### Principle V: Verification & Release Confidence

**git-cross SHALL provide built-in verification mechanisms.**

**Testing strategy**:
- Bash test scripts (`test/bash/examples/`) for realistic scenario coverage
- Fixture repositories (`test/fixtures/remotes/`) simulate upstreams
- `test/run-all.sh` orchestrates full test suite
- Tests verify both happy paths and error handling

**Pre-release checks**:
- Syntax validation: `just check-deps` verifies required tools
- Example validation: All `examples/Crossfile-*` must execute successfully
- Shellcheck linting (when applicable to wrapper scripts)
- Manual verification of `README` examples

**Crossfile reproducibility**:
- `just replay` must reconstruct identical state from `Crossfile`
- Version pinning supported via branch/tag specifications
- Hash-based worktree naming prevents collisions

**Rationale**: Contributors and users need confidence that changes don't break core workflows. Automated testing and clear verification steps enable fearless iteration.

## Decision Framework

When evaluating new features or changes, assess against these questions:

1. **Upstream-First**: Does it maintain/improve the upstream relationship?
2. **Hygiene**: Does it protect user data and worktree cleanliness?
3. **Portability**: Does it run on macOS/Linux without exotic dependencies?
4. **Transparency**: Can users understand and reproduce what it does?
5. **Verification**: Can we test it automatically or document manual verification?

**If any answer is "no"**, re-design the feature or document the trade-off explicitly.

## Extension Points

The constitution permits controlled extensions:

- **Post-hooks**: `cross exec <command>` allows user-defined automation
- **Custom commands**: Users can add recipes to their own `Justfile` that compose `cross` commands
- **Plugin remotes**: Future support for `just <plugin> <cmd>` to delegate to vendored Justfiles

Extensions MUST NOT violate core principles (e.g., post-hooks cannot bypass worktree hygiene checks).

## Constitutional Amendments

This document may be amended when:

1. A principle proves infeasible in practice
2. Ecosystem changes render a principle obsolete (e.g., git internals evolve)
3. Community consensus emerges on a superior approach

**Amendment process**: Propose changes via issue/PR with:
- Problem statement
- Specific principle(s) affected
- Alternative wording or new principle
- Impact assessment on existing users

**Approval**: Requires maintainer consensus + backward compatibility plan or major version bump.

## Acknowledgments

Principles inspired by:
- Git's own design philosophy (simplicity, transparency, data integrity)
- The Unix philosophy (do one thing well, compose with other tools)
- [Spec-kit](https://github.com/github/spec-kit) governance patterns
