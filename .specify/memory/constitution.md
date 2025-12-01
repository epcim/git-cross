<!--
Sync Impact Report
Version change: 0.0.0 → 1.0.0
Modified Principles: Principle I – Upstream-First Patching; Principle II – Worktree Hygiene; Principle III – Portable Bash Discipline; Principle IV – Transparent Automation; Principle V – Verification & Release Confidence
Added sections: Operational Constraints; Workflow & Quality Gates
Removed sections: None
Templates requiring updates: .specify/templates/plan-template.md ✅ updated, .specify/templates/spec-template.md ✅ updated, .specify/templates/tasks-template.md ✅ updated
Follow-up TODOs: None
-->

# git-cross Constitution

## Core Principles

### Principle I – Upstream-First Patching
cross exists to mix sparse directories while keeping upstream repositories the source of truth.

- Patch operations MUST preserve remote alias metadata and branch naming derived from `alias/branch/path`, avoiding rewrites that break contribution flows.
- All git interactions inside the script MUST flow through the `_git` wrapper so logging stays verbose and behaviour remains observable.
- Crossfile definitions MUST rely on the `use` and `patch` helpers; custom fetch flows demand documented governance approval inside the feature plan.

Rationale: Maintaining upstream-first behaviour keeps external projects healthy and ensures contributors can upstream their improvements without friction.

### Principle II – Worktree Hygiene
Reliable worktrees keep cross trustworthy for both the root repository and every patched remote.

- The script MUST execute with `set -euo pipefail`, guarding non-fatal lookups with `|| true` so failures are explicit.
- Root and patch worktrees MUST be clean before cross mutates files; violations exit via `say "ERROR: …" <exit>` rather than continuing silently.
- `./cross status --refresh` MUST be the canonical smoke check before distributing changes or releases.

Rationale: Enforcing cleanliness avoids hidden conflicts and gives contributors immediate feedback about repository health.

### Principle III – Portable Bash Discipline
Portability protects the script across environments and shell versions.

- Implementation MUST target Bash ≥4 syntax, relying on `[[` tests, `local` variables, and other portable constructs.
- Indentation MUST remain four spaces; functions stay lower_snake_case; constants and exported variables stay grouped near the top of the script.
- Direct `git` invocations are forbidden unless a documented exception is granted; `_git` handles instrumentation and future enhancements.
- New external dependencies beyond the established coreutils MUST NOT be introduced without explicit governance approval and documentation.

Rationale: A disciplined style ensures the tool remains approachable, reviewable, and easy to extend.

### Principle IV – Transparent Automation
Users and automations need predictable prompts and output.

- Prompts MUST use the shared `ask` helper and honour `CROSS_NON_INTERACTIVE` so non-interactive runs fail fast and predictably.
- Human-facing output MUST route through `say` to maintain consistent messaging for both humans and AI-assisted tooling.
- Reusable helpers MUST live alongside related utilities and be sourced explicitly to keep automation discoverable.
- Any new environment knob (for example `CROSS_FETCH_DEPTH`) MUST ship with documentation updates in README, plan, and spec artifacts.

Rationale: Clear automation patterns reduce surprises and make integration with other tooling straightforward.

### Principle V – Verification & Release Confidence
Confidence comes from repeatable verification gates.

- `bash -n cross` and `shellcheck cross` MUST pass with zero warnings before any change is merged.
- `./cross status --refresh` MUST succeed for the root and every patch before publishing releases or artifacts.
- New executable variants (e.g., `cross_v<semver>.sh`) MUST mirror the primary `cross` script and be marked executable with `chmod +x`.
- Manual test coverage remains the default; introducing automated suites demands documentation in this constitution, AGENTS, and the Sync Impact Report.

Rationale: Mandatory verification keeps the project reliable even without a large automated test harness.

## Operational Constraints

- Git 2.20 or newer is a hard requirement; the script MUST fail fast with actionable guidance when the version check fails.
- cross MUST continue to support sparse checkout and partial fetch workflows, preserving alias-derived branch naming to avoid collisions.
- Crossfile entries MUST keep comments short and aligned, always declaring destinations with the canonical `alias:path [local] [--branch]` syntax.
- Constants and exported environment toggles (for example `CROSS_FETCH_DEPTH`) MUST live near the top of the script with defaults and rationale.
- Remote metadata stored under `.git/cross/` MUST remain backwards compatible; migrations require explicit mention in the plan and the Sync Impact Report.

## Workflow & Quality Gates

- Implementation plans MUST document how they satisfy every principle, including the exact verification commands contributors will run.
- Developers MUST stage outputs with git after running `./cross` so the root repository captures all generated changes.
- Before requesting review, contributors MUST record the results of `bash -n`, `shellcheck`, and `./cross status --refresh`.
- Preparing a release requires copying `cross` to `cross_v<semver>.sh`, updating documentation, and verifying `./cross version --current` reports the new version.
- Feature work MUST avoid adding new dependencies; when new helpers are introduced they MUST include explicit `source` statements and rationale in the plan.

## Governance

- This constitution supersedes conflicting project guidance; compliance is mandatory for every contribution.
- Amendments require maintainer approval, an updated Sync Impact Report, and a refreshed audit of affected templates.
- Versioning follows Semantic Versioning: MAJOR for principle changes, MINOR for new sections or material expansions, PATCH for clarifications.
- Ratification or amendment MUST capture the verification commands mandated by Principle V as part of the review record.
- Maintainers MUST block merges that omit constitution gates or introduce regressions against these principles.

**Version**: 1.0.0 | **Ratified**: 2025-11-28 | **Last Amended**: 2025-11-28
