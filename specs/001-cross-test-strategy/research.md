# Research Notes: cross command test strategy

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
