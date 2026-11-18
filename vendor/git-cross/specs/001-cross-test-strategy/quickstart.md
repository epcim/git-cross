# Quickstart: cross command test strategy

## Prerequisites
- Git ≥ 2.20
- `just` (command runner) - install via Homebrew or cargo
- `fish` shell ≥ 3.0
- `rsync`
- Bash ≥ 3.2 (for test harness, macOS default is fine)
- Homebrew (macOS/Linux) for PATH setup

## Environment Setup
1. Install dependencies listed above.
2. Clone repository and check out branch `001-cross-test-strategy`.
3. Export `CROSS_NON_INTERACTIVE=1` for non-interactive runs.
4. (Optional) Set `CROSS_TEST_TMPDIR` to control where temporary workspaces are created; defaults to system `mktemp` location.

## Running the Suite
```bash
# From repository root
./test/run-all.sh
```

The script performs:
- Example Crossfile tests via `test/bash/examples/crossfile-{001,002,003,005}.sh`
- Rust implementation tests via `test/008_rust_cli.sh`
- Go implementation tests via `test/009_go_cli.sh`
- Validates expected files exist and behavioral parity across implementations

**Current status**: Tests require fixture seeding (see Maintenance section)

## Results
- Consolidated output stored in `test/results/verification.json` and human-readable logs in `test/results/*.log`.
- CI must fail if any scenario reports non-zero status, missing files, or mismatched artifact hashes.

## Maintenance
- **Fixture seeding**: Run `scripts/fixture-tooling/seed-fixtures.sh` to populate `test/fixtures/remotes/` with content
  - Currently missing: needs implementation to create bare repos with `/metal`, `/setup/flux`, `/asciinema` paths
- Update examples in `examples/Crossfile-*` when adding new features
- Copy modified `Justfile` and `.env` to test repos via test scripts
- Document environment knobs (`CROSS_NON_INTERACTIVE`, `CROSS_FETCH_DEPENDENCIES`) per Principle IV
