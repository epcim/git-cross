# Feature Specification: cross command test strategy

**Feature Branch**: `001-cross-test-strategy`  
**Created**: 2025-11-28  
**Status**: Draft  
**Input**: User description: "Implement test strategy for core functions in cross especially use and patch and any time later all documented functions and callables from usage documentation."

## Clarifications

### Session 2025-11-28

- Q: Where must automated cross tests execute relative to the repository? → A: In a temporary directory outside the project workspace.
- Q: Which directories define the canonical test suites and fixtures? → A: All example Crossfiles under `examples/` plus unit scripts under `test/`.
- Q: How should the test harness accommodate a future Rust rewrite of `cross`? → A: Maintain Bash coverage while enabling parallel frameworks (e.g., Rust integration tests).
- Q: What sequencing must sparse checkout configuration follow relative to `git fetch` in patch workflows? → A: Configure sparse checkout before the first fetch.
- Q: How should the known `bill:/setup/flux` misplacement be handled during testing? → A: Add regression coverage that detects and prevents the wrong destination.
- Q: What final gate must end-to-end tests satisfy before release? → A: All E2E scenarios must pass without manual intervention.
- Q: Should each numbered example Crossfile run as its own end-to-end smoke? → A: Yes—each example must be executed independently with parity checks.
- Q: Should the cross `patch()` fix land in the main script so CLI users benefit too? → A: Yes—tests must consume the same corrected `patch()` in `cross`.
- Q: How should remotes referenced by examples be provided during tests? → A: Create local synthetic fixtures for every example Crossfile.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Example Crossfiles (Priority: P1)

Release maintainers need a single command to verify that the "default testcase" documented in README still succeeds end-to-end, proving that `cross` handles mixed worktrees as advertised.

**Why this priority**: This is the minimum safety net for every change and the first regression signal for contributors before they iterate on deeper checks.

**Independent Test**: Can be fully tested by running the documented default testcase (`VERBOSE=true ./cross`) inside a clean workspace and confirming expected files and git status markers are produced.

**Acceptance Scenarios**:

1. **Given** a clean repository on branch `001-cross-test-strategy`, **When** a maintainer executes `VERBOSE=true ./cross`, **Then** the expected directories (`deploy/flux/cluster/cluster.yaml`, `deploy/metal/docs/index.md`) exist and the root git status shows staged files only in those locations, with no unexpected `deploy/setup/flux` directory created.
2. **Given** the same default testcase run, **When** the maintainer inspects `deploy/flux` via `git status`, **Then** the output contains the phrase "branch is up to date with 'bill/master'" with no dirty state and no stray `deploy/setup/flux` folder.

---

### User Story 2 - Validate `use` registrations (Priority: P2)

Contributors need automated checks that the `use` subcommand records remote aliases and metadata correctly across supported git versions.

**Why this priority**: Reliable alias registration is prerequisite for every `patch` workflow and prevents regressions that would orphan contributor worktrees.

**Independent Test**: Can be fully tested by executing scripted scenarios that call `./cross use <alias> <url>` with mocked remotes and then inspecting `.git/cross/` metadata without invoking other commands.

**Acceptance Scenarios**:

1. **Given** a clean repository with no prior alias, **When** a contributor runs `./cross use demo https://example.org/demo.git` (or `cross use`), **Then** the alias appears in `.git/cross/config` (or `Crossfile`) with correct URL and no duplicate entries.
2. **Given** an existing alias, **When** `./cross use demo https://example.org/demo.git` runs again, **Then** the command reports idempotent success without modifying timestamps or duplicating configuration.

---

### User Story 3 - Validate `patch` workflows (Priority: P2)

Contributors need repeatable tests that confirm `patch` can fetch sparse directories, create worktrees, and stage synced files while enforcing worktree hygiene.

**Why this priority**: `patch` drives the primary value of cross; regressions here break the core promise of mixing upstream repositories.

**Independent Test**: Can be fully tested by scripting `./cross patch <alias>:<remote-path> <local-path>` against fixture remotes and asserting worktree configuration, sparse checkout files, and staged changes match expectations.

**Acceptance Scenarios**:

1. **Given** a configured alias and clean target directory, **When** `./cross patch demo:docs/reference vendor/demo-docs --branch main` (or `cross patch`) executes, **Then** a worktree named `demo_main_docs_reference` exists, sparse checkout lists `/docs/reference/`, and staged files appear under `vendor/demo-docs`.
2. **Given** the same scenario with an intentionally dirty target directory, **When** `./cross patch ...` executes, **Then** the command aborts via `say "ERROR: ..."` without modifying working files, preserving constitution principle II (Worktree Hygiene).

### User Story 4 - Post-hooks via `exec` (Priority: P2)

Contributors need a way to run custom cleanup or setup commands after `cross` operations, defined within the `Crossfile`.

**Acceptance Scenarios**:

1. **Given** a `Crossfile` with `cross exec just posthook`, **When** `cross replay` or `cross sync` is run, **Then** the `posthook` recipe in the user's `Justfile` is executed.

---

### Edge Cases

- How does default testcase behave when remote aliases require authentication or the machine lacks network connectivity?
- What happens when `use` or `patch` run under git <2.20 or unsupported shells? (Tests must fail fast with actionable messaging.)
- How are existing worktrees handled when `patch` re-materialises a directory that was previously removed locally?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The test suite MUST execute the README "default testcase" verbatim (`VERBOSE=true ./cross`) and assert all documented outputs, including staged file paths and expected git status messages, remain unchanged across releases. [Principles I, II, V]
- **FR-002**: Automated checks MUST cover `use` alias registration, ensuring metadata stored under `.git/cross/` remains idempotent and backward compatible with existing configurations. [Principles I, IV]
- **FR-003**: Automated checks MUST validate `patch` workflows for both clean and dirty target directories, ensuring hygiene errors are surfaced via `say` and no unstaged modifications persist. [Principles II, IV, V]
- **FR-004**: The test harness MUST integrate constitution-mandated verification commands (`bash -n cross`, `shellcheck cross`, `./cross status --refresh`) so contributors can run a single aggregated test target. [Principles III, V]
- **FR-005**: Test documentation MUST describe how new commands or helpers become part of the strategy, including fixture requirements and environment knobs such as `CROSS_NON_INTERACTIVE` or `CROSS_FETCH_DEPTH`. [Principles III, IV]
- **FR-006**: The automated suite MUST execute inside an isolated temporary directory outside the repository root, ensuring the project workspace remains untouched during test runs. [Principles II, V]
- **FR-007**: Example-driven tests MUST iterate every Crossfile under the `examples/` directory, while unit and helper scripts MUST reside in the top-level `test/` directory as the canonical execution entrypoint. [Principles I, IV, V]
- **FR-008**: The default testcase MUST have at least two automated executions: one Bash implementation mirroring README steps and one additional harness aligned with the future Rust rewrite (e.g., Rust integration test binary), both producing the same verification artifacts. [Principles III, V]
- **FR-009**: Patch workflow tests MUST configure sparse checkout settings before issuing the first `git fetch`, asserting that worktree and sparse lists exist ahead of network calls. [Principles I, II]
- **FR-010**: Regression tests MUST detect and fail when `bill:/setup/flux` materialises under `deploy/setup/flux` instead of the expected `deploy/flux`, providing diagnostic output that helps isolate the mapping bug. [Principles I, II, V]

> **Constitution Alignment**: Capture requirements that explain how the feature satisfies Principle I (Upstream-First Patching), Principle II (Worktree Hygiene), Principle III (Portable Bash Discipline), Principle IV (Transparent Automation), and Principle V (Verification & Release Confidence).

### Key Entities *(include if feature involves data)*

- **Test Fixture Repository**: Represents lightweight remote repositories (local git fixtures) used to validate `use` and `patch` scenarios. Key attributes include alias name, upstream URL, and expected sparse paths.
- **Command Transcript**: Records stdout/stderr for each scripted scenario, tagged with principle coverage so failures map to governance obligations.
- **Verification Bundle**: Aggregated artefact (log or report) summarising the outcomes of default testcase, command-specific tests, and constitution verification commands for reviewer handoff.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Default testcase smoke completes within 5 minutes on a clean machine and produces the exact staged file set documented in README on 100% of runs.
- **SC-002**: `use` and `patch` automated checks cover 100% of documented usage examples, with failures blocking release pipelines until resolved.
- **SC-003**: Combined verification bundle surfaces the results of `bash -n cross`, `shellcheck cross`, and `./cross status --refresh`, with zero tolerated warnings before merge.
- **SC-004**: Test documentation enables a new contributor to execute the full strategy and obtain passing results in under 30 minutes, confirmed during feature acceptance.
- **SC-005**: Every automated run provisions and tears down a temporary workspace directory with zero residual files left inside the repository root, verified on 100% of CI executions.
- **SC-006**: Regression suites demonstrate 100% execution coverage of `examples/` Crossfiles and produce a consolidated report under `test/` with pass/fail status for each example and unit helper.
- **SC-007**: Bash and Rust (or successor) implementations of the default testcase remain behaviourally equivalent, evidenced by identical assertion outputs and artifact hashes across both harnesses on every CI run.
- **SC-008**: Automated patch tests confirm sparse checkout configuration is applied prior to any `git fetch`, with CI logs demonstrating the configuration step and zero regressions over time.
- **SC-009**: CI runs fail if `bill:/setup/flux` mappings produce any directory other than `deploy/flux`, with regression reports stating the incorrect path when detected.
