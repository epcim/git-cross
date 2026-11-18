# Tasks: root overlay patching and `.crossignore`

## Phase 1: Specification And Safety Baseline

- [x] T001 Write feature spec for repo-root overlay patching and `.crossignore`.
- [x] T002 Write implementation plan describing the managed-file-set model and safety constraints.
- [ ] T003 Decide final CLI shape for root-target patches.
- [ ] T004 Decide whether `.crossignore` applies only to root-target patches or all patch modes.

## Phase 2: Shared Safety Fixes

- [ ] T005 Add repo-root normalization helpers where missing in Just, Go, and Rust.
- [ ] T006 Add hard guards preventing `remove` and `prune` from deleting repo root contents.
- [ ] T007 Align metadata schema across implementations, including Go support for `id`.

## Phase 3: `.crossignore`

- [ ] T008 Define `.crossignore` parsing and matching semantics.
- [ ] T009 Apply ignore semantics to `status` and `diff` in all three implementations.
- [ ] T010 Apply ignore semantics to `sync` and `push` in all three implementations.
- [ ] T011 Document `.crossignore` in README and examples.

## Phase 4: Root Overlay Behavior

- [ ] T012 Implement upstream-root -> local-root patching safely in Just.
- [ ] T013 Port upstream-root -> local-root patching to Go.
- [ ] T014 Port upstream-root -> local-root patching to Rust.
- [ ] T015 Implement upstream-subdir -> local-root patching safely in Just.
- [ ] T016 Port upstream-subdir -> local-root patching to Go.
- [ ] T017 Port upstream-subdir -> local-root patching to Rust.

## Phase 5: Tests

- [ ] T018 Add shell regression tests for root-target patching.
- [ ] T019 Add Go regression coverage for root-target patching.
- [ ] T020 Add Rust regression coverage for root-target patching.
- [ ] T021 Add safety tests ensuring ignored files never appear in upstream commits.
- [ ] T022 Add safety tests ensuring `remove` and `prune` do not delete repo root contents.

## Phase 6: UX And Rollout

- [ ] T023 Improve README usage examples for the new workflow.
- [ ] T024 Update contributor docs and context files after implementation lands.
- [ ] T025 Run full regression suite and capture remaining implementation gaps.
