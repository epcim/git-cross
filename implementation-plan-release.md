# Implementation Plan - GitHub Releases & Architecture Refinement

## Context
The `git-cross` project currently has three implementations:
1.  **Go:** A native implementation (Primary focus).
2.  **Shell/Justfile:** The original functional version.
3.  **Rust:** A native implementation (WIP).

To streamline distribution and maintenance, we are formalizing the preference for the Go implementation while maintaining the others for reference or future development.

## Architecture Decision Record (ADR) - Primary Implementation Choice
**Decision: Prioritize Go as the primary native implementation for `git-cross`.**

### Rationale:
- **Ecosystem:** Go has mature, high-level wrappers for both Git (`git-module`) and Rsync (`grsync`) that align well with our "wrapper" philosophy.
- **Distribution:** Go's static linking and cross-compilation simplicity make it ideal for a developer tool that needs to run in various environments (Mac, Linux, CI).
- **Maintenance:** The Go implementation is currently more complete and matches the behavioral requirements of the PoC with less boilerplate than the current Rust approach.

### Consequences:
1.  **Rust Implementation:** Will be marked as **Work In Progress (WIP)** and experimental. Future feature development will land in Go first.
2.  **Builds & Releases:** Focus on providing pre-built binaries for Go across platforms (Linux amd64/arm64, Darwin amd64/arm64). Rust binaries will be built but marked as experimental.

## Proposed Changes

### 1. Documentation & Status Updates
- **`README.md`**: Update the "Implementation Note" to clearly state Go is the primary version and Rust is WIP.
- **`src-rust/src/main.rs`**: Add a WIP warning to the CLI help description.
- **`src-rust/Cargo.toml`**: Update metadata if needed.

### 2. GitHub Release Workflow Refinement
- Update `.github/workflows/release.yml` to:
    - Build Go binaries using `goreleaser` (or a similar action).
    - Build Rust binaries for standard platforms.
    - Attach all binaries to the GitHub Release.
    - Use `softprops/action-gh-release` instead of the deprecated `actions/create-release`.

### 3. Implementation Details for Release Workflow
#### Go Release (via GoReleaser):
Create a `.goreleaser.yaml` in `src-go/` (or root) to handle:
- Binaries: `git-cross` (from Go).
- Platforms: `linux/amd64`, `linux/arm64`, `darwin/amd64`, `darwin/arm64`.

#### Rust Release:
- Use `cross-rs` or simple `cargo build --release` in a matrix for Rust.

## Tasks
- [ ] Update `README.md` status section.
- [ ] Add WIP warning to Rust CLI.
- [ ] Create `.goreleaser.yaml`.
- [ ] Rewrite `.github/workflows/release.yml`.
- [ ] Update `TODO.md` to reflect these documentation and release tasks.
