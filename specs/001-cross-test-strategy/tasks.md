# Tasks: cross command test strategy

**Input**: Design documents from `/specs/001-cross-test-strategy/`  
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/  
**Status**: Partially Complete (2025-12-01)  
**Implementation**: Justfile + Fish shell

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Establish scaffolding for local fixtures, orchestrators, and temporary workspace utilities.

- [x] T001 Ensure test harness directories exist (`test/bash`, `test/bash/lib`, `test/bash/examples`, `test/rust/src`, `test/fixtures/{templates,remotes,workspaces}`, `test/results`) with `.gitkeep` placeholders as needed.
- [x] T002 Add initial orchestration stub `test/run-all.sh` wiring command-line flags and placeholders for Bash/Rust suites plus verification commands.
- [x] T003 Create fixture template skeletons under `test/fixtures/templates/{bill,khue,core,mine}` mirroring paths required by Crossfile-00{1,2,3}.
- [x] T004 Add executable stub `scripts/fixture-tooling/seed-fixtures.sh` with `set -euo pipefail` that currently logs intended remotes.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Build reusable helpers, populate fixture content, and prepare reporting/verification plumbing before story-specific work.

- [ ] T005 Implement fixture seeding in `scripts/fixture-tooling/seed-fixtures.sh` creating bare remotes for khue, bill, core, and mine using templates, pushing canonical commits for each Crossfile scenario.
- [ ] T006 Populate template content for `khue:/metal`, `bill:/setup/flux`, `core:asciinema`, and `mine:docs/another` under `test/fixtures/templates/` with minimal files expected by tests.
- [ ] T007 Add workspace lifecycle helper `test/bash/lib/workspace.sh` to provision/cleanup temp directories outside the repo via `mktemp` and optional `CROSS_TEST_TMPDIR`.
- [ ] T008 Add git logging wrapper `test/bash/lib/git.sh` that proxies `_git` commands and records invocations to `test/results/git.log`.
- [ ] T009 Add artifact hash helper `test/bash/lib/artifact_hash.sh` to collect and compare SHA256 digests across Bash/Rust harnesses.
- [ ] T010 Implement JSON report writer `test/bash/lib/report.sh` accumulating scenario results into `test/results/verification.json` with status and optional messages.
- [ ] T011 Extend `test/run-all.sh` to seed fixtures, manage temp workspaces, run verification commands (`bash -n cross`, `shellcheck cross`, `./cross status --refresh`), and record results via report helpers.
- [ ] T012 Create Rust harness workspace (`test/rust/Cargo.toml`, `test/rust/src/lib.rs`) with dependencies `assert_cmd`, `predicates`, `tempfile`, `camino` and placeholder test scaffolding.

---

## Phase 3: User Story 1 - Execute Example Crossfiles (Priority: P1) 🎯 MVP

**Goal**: Execute each `examples/Crossfile-*` (001, 002, 003) end to end in both Bash and Rust harnesses, verifying outputs, parity, and git status.

**Independent Test**: Run `test/run-all.sh --scenario examples` to iterate Crossfile-001/002/003 sequentially, logging Bash + Rust runs, parity hashes, and regression assertions for each example.

### Implementation for User Story 1

- [x] T013 [US1] Implement Bash harness `test/bash/examples/crossfile-001.sh` that clones the repo, rewrites the Crossfile to local fixture remotes, enforces absence of `deploy/setup/flux`, captures expected artifacts, and emits hash file metadata.
- [x] T014 [US1] Implement Bash harness `test/bash/examples/crossfile-002.sh` covering dual remotes (khue+bill), asserting sparse checkout hygiene and capturing artifact hashes/logs.
- [x] T015 [US1] Implement Bash harness `test/bash/examples/crossfile-003.sh` including `core:asciinema`, verifying additional files and ensuring `CROSS_FETCH_DEPENDENCIES` semantics are documented in outputs.
- [ ] T016 [P] [US1] Extend Rust harness `test/rust/src/examples.rs` to mirror Crossfile-001/002/003 flows, generate hash outputs (`test/results/default-artifacts-rust-00X.sha256`), and assert absence of `deploy/setup/flux`.
- [ ] T017 [US1] Update `test/run-all.sh` to orchestrate `--scenario examples`, calling each Bash script, Rust parity run, parity comparison, and logging pass/fail per example into the JSON report.
- [ ] T018 [US1] Add regression assertions for each example ensuring expected directories exist (deploy/metal, deploy/flux, `core/asciinema`) and no unexpected paths remain; surface failures to the report helper.

**Checkpoint**: All numbered Crossfiles pass in Bash/Rust harnesses with matching artifacts and clean git status per scenario.

---

## Phase 4: User Story 2 - Validate `use` registrations (Priority: P2)

**Goal**: Automate alias registration checks ensuring `_git` routing and idempotent `.git/cross` metadata for fixture remotes.

**Independent Test**: Run `test/run-all.sh --scenario use` to seed fixtures, run `./cross use` twice per alias, and compare metadata dumps for stability.

### Implementation for User Story 2

- [ ] T019 [US2] Implement `test/bash/use-alias.sh` to set up temp workspace, register demo aliases, capture `.git/cross` state before/after reruns, and output diff summaries.
- [ ] T020 [P] [US2] Extend `test/bash/lib/report.sh` to collect alias metadata diffs, recording idempotency status and diagnostic messages.
- [ ] T021 [US2] Wire `test/run-all.sh` to invoke the use-alias script, fail on metadata changes, and log results in `test/results/use-alias.log` plus the JSON report.

**Checkpoint**: Alias registration flows are idempotent with `_git` logging and report entries per alias.

---

## Phase 5: User Story 3 - Fix & Validate `patch` workflows (Priority: P2)

**Goal**: Correct `cross patch()` so sparse checkout config occurs before fetch, destination paths land correctly (no `deploy/setup/flux`), and hygiene checks trigger on dirty targets.

**Independent Test**: Run `test/run-all.sh --scenario patch` to execute clean and dirty runs, inspect `_git` logs for sparse-before-fetch, and confirm regression detection for misrouted paths.

### Implementation for User Story 3

- [ ] T022 [US3] Update `cross` script `patch()` implementation to configure sparse checkout prior to fetching, correct branch/worktree naming, and ensure destination paths map to `deploy/flux` without intermediates.
- [ ] T023 [US3] Implement Bash regression script `test/bash/patch-workflow.sh` covering clean and dirty target scenarios, asserting sparse-before-fetch via log inspection and guarding against `deploy/setup/flux`.
- [ ] T024 [P] [US3] Add log assertion helper `test/bash/lib/log_assert.sh` to parse `test/results/git.log` ensuring `_git fetch` occurs after sparse config entries.
- [ ] T025 [US3] Extend `test/run-all.sh` patch scenario wiring to record log assertions, hygiene status, and regression failures in the JSON report.

**Checkpoint**: Fixed `cross patch()` passes regression scripts across clean/dirty cases with documented sparse checkout ordering.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Document suite usage, hook into automation, and preserve repository hygiene.

- [ ] T026 Document test suite usage and scenarios in `README.md` (verification section) and reference `test/run-all.sh --scenario ...` plus prerequisites.
- [ ] T027 Update `specs/001-cross-test-strategy/quickstart.md` and any contributor docs to include new example scenarios, Rust parity instructions, and environment knobs.
- [ ] T028 Integrate `test/run-all.sh` into CI/Justfile (`.github/workflows/*.yml` or `Justfile`) running `examples`, `use`, and `patch` scenarios sequentially.
- [ ] T029 Amend `.gitignore` to exclude `test/results/*.log`, generated hash files, temporary workspaces, and Rust `target/` directories.
- [ ] T030 Perform final suite run across all scenarios, commit `test/results/verification.json` summary (or attach to release evidence), and record parity outcomes for review.

---

## Dependencies & Execution Order

### Phase Dependencies
- **Setup (Phase 1)**: No dependencies.
- **Foundational (Phase 2)**: Depends on Setup completion.
- **User Story Phases (3–5)**: Depend on Foundational completion.
- **Polish (Phase 6)**: Depends on completion of all user stories to ensure documentation and automation reflect final behaviour.

### User Story Dependencies
- **User Story 1 (P1)**: Serves as MVP; enables parity utilities and reporting leveraged by later stories.
- **User Story 2 (P2)**: Requires fixture seeding (Phase 2) so alias scenarios operate on local remotes.
- **User Story 3 (P2)**: Depends on parity/reporting infrastructure plus Bash helpers from Phases 1–2 and 3.

### Within Each User Story
- Helpers marked [P] (artifact hash compare, log assertions, Rust parity) can run in parallel once prerequisite scaffolding exists.
- Scenario scripts must be implemented before wiring them into `test/run-all.sh` to avoid failing orchestrator tasks.
- Reporting integrations (T017, T021, T025) rely on base report writer from Phase 2.

### Parallel Opportunities
- T008–T010 (helpers) can proceed concurrently after directories exist.
- T016 (Rust parity) and T017 (orchestrator updates) can run in parallel after Bash scripts (T013–T015) expose artifact outputs.
- T024 (log assertions) can proceed alongside T023 once `_git` logging is available.

---

## Implementation Strategy

### MVP First (User Story 1 Only)
1. Complete Setup + Foundational phases (T001–T012).
2. Implement User Story 1 tasks (T013–T018) for all numbered Crossfiles.
3. Run `test/run-all.sh --scenario examples` to validate MVP parity and regression coverage.

### Incremental Delivery
1. Deliver MVP (User Story 1) for example coverage.
2. Add User Story 2 to ensure alias idempotency.
3. Add User Story 3 to ship the `cross patch()` fix with regression tests.
4. Finish with Polish phase to document and automate the suite.

### Parallel Team Strategy
- Developer A: Fixture seeding, Bash example scripts, orchestrator updates.
- Developer B: Rust parity harness, artifact/hash utilities, parity evaluations.
- Developer C: Alias and patch regression scripts, cross patch implementation.
- Shared: Documentation, CI integration, final verification runs (Phase 6).
