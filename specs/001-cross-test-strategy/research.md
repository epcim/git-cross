# Research Notes: cross command test strategy

## Implementation Update: 2025-12-01

### Decision: Justfile + Fish Shell implementation
- **Rationale**: Provides excellent command-running ergonomics (`just` list, help) while delegating complex logic to fish. Vendorable into user repos via `import?` directive.
- **Migration completed**: All commands (`use`, `patch`, `sync`, `diff`, `push`, `list`, `status`, `exec`, `replay`) now in Justfile.
- **Trade-offs**: Requires `just` and `fish` as dependencies (added to constitution Principle III).

### Decision: `cross` command prefix in Crossfile
- **Rationale**: Extensibility for future plugin support (e.g., `just <plugin> <cmd>`). Makes git-cross commands explicit vs. potential user recipes.
- **Implementation**: All Crossfile lines start with `cross` (e.g., `cross use`, `cross patch`, `cross exec`).

### Decision: Post-hooks via `cross exec`
- **Rationale**: Delegates flexibility to users rather than hardcoding hook logic. Allows calling user's own Justfile recipes or arbitrary shell commands.
- **Implementation**: `_sync_from_crossfile` helper evaluates `cross exec <command>` lines from Crossfile.

## Original Research (2025-11-28)

## Decision: Local git fixtures for examples and regression coverage
- **Rationale**: Avoids network dependency while replicating README scenarios, enabling deterministic tests for `bill:/setup/flux` and other aliases. Local bare repositories can be seeded with required directories and commits.
- **Alternatives considered**: (a) Hitting live upstreams (rejected: flaky, credentials), (b) Mocking git commands (rejected: misses integration).

## Decision: Temporary workspace orchestration outside repo
- **Rationale**: Aligns with FR-006/SC-005, preserves root cleanliness, and mimics contributor instructions. Bash scripts will use `mktemp -d`; Rust harness will rely on `tempfile::TempDir`.
- **Alternatives considered**: Running within repo with cleanup (rejected: risk of dirty worktree).

## Decision: Bash + Rust dual harness for default testcase
- **Rationale**: Bash keeps fidelity with README and current workflow; Rust harness prepares for planned rewrite and validates parity (SC-007).
- **Alternatives considered**: Bash-only (rejected: no future-aligned coverage), Rust-only (rejected: diverges from current docs).

## Decision: Sparse checkout configuration before fetch
- **Rationale**: Matches user guidance and reduces wasted network usage; ensures `patch` behaviour matches expectations in default testcase.
- **Alternatives considered**: Fetch-then-configure (current bug path; rejected due to `deploy/setup/flux` regression).

## Decision: Test reporting format
- **Rationale**: `test/results/verification.json` summarises scenario outcomes and verification commands for CI review, satisfying SC-003 and providing machine-readable status.
- **Alternatives considered**: Plain text logs only (rejected: harder for CI tooling to consume).

## Open Questions (tracked for implementation but no blockers)
- How to generalise fixture seeding scripts for additional future Crossfiles. Solution: parameterise script inputs and document update procedure in quickstart.
