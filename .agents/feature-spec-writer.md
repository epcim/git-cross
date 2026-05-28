# Feature Spec Writer Skill

## Goal

Write repo-specific specs that are precise enough to implement across all three `git-cross` implementations.

## Required Sections

- User problem.
- Scope and non-goals.
- Functional requirements.
- Safety requirements.
- CLI and UX expectations.
- Test requirements.
- Migration or compatibility notes.

## Repo-Specific Expectations

- State whether the feature affects Just, Go, Rust, or all three.
- Name the commands affected.
- Describe how `Crossfile` and `.cross/metadata.json` must evolve.
- Call out any root-path or delete-path risks.
- Include explicit regression-test expectations.

## Anti-Patterns

- Do not describe only the happy path.
- Do not leave `.crossignore` or root deletion semantics vague.
- Do not assume current implementation behavior is already safe.
