# Claude Skill Guidance

## Required Repo Skills

Claude should rely on these repo roles:

- `.agents/git-cross-maintainer.md`
- `.agents/feature-spec-writer.md`
- `.agents/safety-reviewer.md`
- `.agents/regression-tester.md`

## Suggested Usage

- Use `git-cross-maintainer` for code changes.
- Use `feature-spec-writer` before large feature work.
- Use `safety-reviewer` before landing risky path, sync, push, or remove changes.
- Use `regression-tester` before considering behavior work complete.

## Why This Set

This repo's main risk is not syntax complexity. It is behavior safety across three implementations. These four roles cover the core lifecycle without adding too much process.
