# Contract: `cross patch`

## Preconditions
- Alias previously registered via `./cross use bill fixtures/remotes/bill.git`.
- Temporary workspace clean; target directory (e.g., `deploy/flux`) absent.
- Sparse checkout patterns defined before fetching (write desired paths to `info/sparse-checkout`).

## Steps
1. Execute `./cross patch bill:/setup/flux deploy/flux --branch master` within the temporary workspace.
2. Capture stdout/stderr and `_git` command log.
3. Run `./cross status --refresh` to confirm hygiene.
4. Remove target directory, create a dirty file, and rerun `./cross patch ...` to validate error handling.

## Expected Results
- First execution creates worktree `bill_master_setup_flux_deploy_flux` with sparse checkout limited to `/setup/flux/`.
- Files arrive under `deploy/flux`, not `deploy/setup/flux`.
- `_git` logs show sparse checkout configuration prior to the first fetch command.
- `./cross status --refresh` reports clean state for root and patch worktree.
- Second execution with dirty target aborts via `say "ERROR: ..."` without modifying local files.

## Failure Conditions
- Files materialised under `deploy/setup/flux` or other incorrect paths.
- Sparse checkout configured after fetch (detected in logs).
- Worktree left dirty or command fails to abort when preconditions violated.
