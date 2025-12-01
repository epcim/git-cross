# Contract: README Default Testcase

## Preconditions
- Git ≥2.20 available.
- Temporary workspace directory created outside the repository (`$TMPDIR/cross-e2e-*`).
- Fixture remotes for `bill` and `khue` registered via `./cross use` pointing to local bare repositories.
- Workspace clean: `./cross status --refresh` exits 0 with no dirty entries.

## Steps
1. Export `VERBOSE=true` and run `./cross` from within the temporary workspace.
2. Allow script to process `Crossfile` entries, materialising patches.
3. Capture stdout/stderr into `command.log`; capture git status snapshots for root and `deploy/flux`.
4. Compute artifact hash for staged files (`deploy/flux/cluster/cluster.yaml`, `deploy/metal/docs/index.md`).

## Expected Results
- Command exits 0.
- Directories materialised: `deploy/flux/cluster/cluster.yaml` and `deploy/metal/docs/index.md` only; **no** `deploy/setup/flux` directory present.
- `git status` at repo root shows staged changes limited to the expected paths.
- `git status` inside `deploy/flux` reports `branch is up to date with 'bill/master'`.
- Verification bundle records artifact hashes identical between Bash and Rust harness executions.

## Failure Conditions
- Presence of `deploy/setup/flux` or other unexpected directories.
- Non-zero exit code or missing staged files.
- Divergence between Bash and Rust artifact hashes/logs.
