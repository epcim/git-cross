# Data Model: cross command test strategy

## Entities

### Test Fixture Repository
- **Attributes**: `alias`, `remote_url`, `sparse_paths`, `seed_commit`, `branch`.
- **Relationships**: Linked to one or more `PatchScenario` records.

### PatchScenario
- **Attributes**: `name`, `local_path`, `expected_destination`, `expect_sparse_sequence` (bool), `expected_status_message`.
- **Relationships**: Consumes one `Test Fixture Repository`; produces one `Command Transcript` and contributes to a `Verification Bundle`.

### UseScenario
- **Attributes**: `alias`, `remote_url`, `idempotent` (bool), `config_path` (expected `.git/cross` entry).
- **Relationships**: Generates a `Command Transcript`; depends on `Test Fixture Repository` metadata.

### Command Transcript
- **Attributes**: `scenario_name`, `stdout`, `stderr`, `exit_code`, `principles_covered` (list), `artifact_hash`.
- **Relationships**: Aggregated by a `Verification Bundle`.

### Verification Bundle
- **Attributes**: `run_id`, `timestamp`, `workspace_path`, `results_json`, `bash_checks`, `shellcheck_status`, `status_refresh_result`.
- **Relationships**: Aggregates many `Command Transcript` entries and references the temporary workspace used (`TempWorkspace`).

### TempWorkspace
- **Attributes**: `path`, `creation_time`, `cleanup_time`, `status` (clean/dirty), `residual_files` (list).
- **Relationships**: Linked one-to-one with a `Verification Bundle` and to multiple scenarios executed within it.

### HarnessImplementation
- **Attributes**: `language` (bash/rust), `entrypoint`, `parity_group` (default testcase), `artifacts` (logs, hashes).
- **Relationships**: Associates with one or more `Command Transcript` entries proving parity between implementations.

## Relationships Overview

- Each `Verification Bundle` **collects** `Command Transcript` records emitted by Bash and Rust harnesses.
- `PatchScenario` and `UseScenario` **depend** on `Test Fixture Repository` for accurate alias/path metadata.
- `TempWorkspace` **belongs to** exactly one `Verification Bundle`, ensuring cleanup verification per run.
- `HarnessImplementation` **pairs** transcripts across languages to enforce SC-007 parity assertions.
