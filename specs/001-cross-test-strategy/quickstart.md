# Quickstart: cross command test strategy

## Prerequisites
- Git ≥ 2.20
- Bash ≥ 5.0 with coreutils (`mktemp`, `realpath`, `tee`)
- `shellcheck`
- Rust toolchain ≥ 1.75 (for Rust harness)
- `cargo` with crates cached locally (`assert_cmd`, `predicates`, `tempfile`, `camino`)

## Environment Setup
1. Install dependencies listed above.
2. Clone repository and check out branch `001-cross-test-strategy`.
3. Export `CROSS_NON_INTERACTIVE=1` for non-interactive runs.
4. (Optional) Set `CROSS_TEST_TMPDIR` to control where temporary workspaces are created; defaults to system `mktemp` location.

## Running the Suite
```bash
# From repository root
test/run-all.sh
```
The script performs:
- README default testcase in Bash (`test/bash/default-test.sh`).
- Rust parity harness via `cargo test` under `test/rust/`.
- Alias and patch scenario checks (`test/bash/use-alias.sh`, `test/bash/patch-workflow.sh`).
- Constitution verification commands: `bash -n cross`, `shellcheck cross`, `./cross status --refresh`.

## Results
- Consolidated output stored in `test/results/verification.json` and human-readable logs in `test/results/*.log`.
- CI must fail if any scenario reports non-zero status, missing files, or mismatched artifact hashes.

## Maintenance
- Update fixtures via `scripts/fixture-tooling/seed-fixtures.sh` when README examples change.
- Document any new environment knobs in README, spec, and plan as required by Principle IV.
