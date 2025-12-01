# Contract: `cross use`

## Preconditions
- Temporary workspace created and initialised as a git repository with `cross` available on PATH.
- `.git/cross/` directory absent or empty for target alias.
- Fixture bare repository exists (e.g., `fixtures/remotes/demo.git`).

## Steps
1. Run `./cross use demo fixtures/remotes/demo.git`.
2. Rerun the same command to confirm idempotency.
3. Inspect `.git/cross/config` and `.git/cross/aliases/demo` metadata files.

## Expected Results
- First execution exits 0, creates alias metadata under `.git/cross/` with correct URL and branch defaults.
- Second execution exits 0 without changing file modification timestamps (idempotent behaviour).
- `_git` wrapper logging (if verbose) records the operations; no direct `git` invocation bypasses the wrapper.

## Failure Conditions
- Duplicate alias entries or mismatched URLs.
- Idempotent rerun modifies metadata timestamps or contents.
- Command bypasses `_git` (detected via verbose logs) or produces unexpected prompts when `CROSS_NON_INTERACTIVE=1`.
