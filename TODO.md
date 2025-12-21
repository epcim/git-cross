# TODO - git-cross

## Core Implementation Status
- [x] Go Implementation (Primary) - Feature parity achieved.
- [x] Justfile/Fish - Fully functional original version.
- [x] Rust Implementation (Experimental/WIP) - Refactored to `git2` and `duct`.

## Infrastructure & Releases
- [x] Create ADR for Go-primary implementation strategy.
- [x] Implement GitHub Release builds for Go (via GoReleaser).
- [x] Implement GitHub Release builds for Rust (via Matrix/Artifacts).
- [x] Update README and status to reflect implementation priorities.
- [x] Setup unified Release workflow.

## Completed Tasks
- [x] Refactor remaining Rust commands to use `duct` for better error visibility.
- [x] Complete `push` command verification in native implementations.
- [x] Integrate integration tests (001-009) into a unified test runner.
- [x] Implement `cross install` command in Go to handle Git alias setup.
- [x] Implement `cross init` to setup a new project with Crossfile.
- [x] Update In README.md, an example how users can implement their "post-hook" actions.
- [x] Implement the test 006 for "push" command.
- [x] Implement the test 007 for "status" command. 
- [x] Wire test 7 to github CI workflow.
- [x] Implement "cross" command in Rust.
- [x] Implement "cross" command in Golang.
- [x] Update AGENTS.md, specs/ and .specify/ to reflect new implementations.