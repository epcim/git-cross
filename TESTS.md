# Test Documentation

This document describes all available tests for `git-cross`, including their purpose and how to execute them.

## Test Summary

| ID | Test Name | Description | Command |
|----|-----------|-------------|---------|
| TC-001 | crossfile-001 | Basic patch workflow | `just test 001` or `./test/bash/examples/crossfile-001.sh` |
| TC-002 | crossfile-002 | Dual remote workflow | `just test 002` or `./test/bash/examples/crossfile-002.sh` |
| TC-003 | crossfile-003 | Asciinema example | `just test 003` or `./test/bash/examples/crossfile-003.sh` |
| TC-005 | crossfile-005 | Exec command & post-hooks | `just test 005` or `./test/bash/examples/crossfile-005.sh` |
| TC-006 | core-improvements | Core improvements suite | `./test/bash/core-improvements.sh` |

**Quick Start:**
```bash
# Run all tests
just test

# Run specific test by ID
just test 001

# Run directly
./test/bash/examples/crossfile-001.sh
```

## Prerequisites

Before running tests, ensure you have:

- **fish** shell ≥ 3.0
- **just** command runner
- **git** ≥ 2.20
- **Homebrew** (for PATH setup on macOS/Linux)
- **rsync**

## Running All Tests

Execute the complete test suite:

```bash
./test/run-all.sh
```

This runs all example Crossfile tests and generates a report in `test/results/verification.json`.

## Individual Test Cases

### Example Crossfile Tests

These tests validate the core workflow using numbered Crossfile examples.

#### TC-001: Basic Patch Workflow

**Test ID**: `crossfile-001`  
**Description**: Tests basic `use` and `patch` commands with a single remote repository. Validates that files are correctly vendored from upstream.  
**Command**:
```bash
./test/bash/examples/crossfile-001.sh
```
**What it tests**:
- Remote registration (`cross use`)
- Basic patching (`cross patch`)
- Sparse checkout configuration
- File synchronization via rsync

---

#### TC-002: Dual Remote Workflow

**Test ID**: `crossfile-002`  
**Description**: Tests vendoring from multiple remote repositories (khue and bill) into different local paths.  
**Command**:
```bash
./test/bash/examples/crossfile-002.sh
```
**What it tests**:
- Multiple remote management
- Concurrent patches from different upstreams
- Worktree isolation
- Path organization (deploy/metal, deploy/flux)

---

#### TC-003: Asciinema Example

**Test ID**: `crossfile-003`  
**Description**: Tests patching a directory with the same name as the remote path (asciinema → asciinema).  
**Command**:
```bash
./test/bash/examples/crossfile-003.sh
```
**What it tests**:
- Same-name directory patching
- `CROSS_FETCH_DEPENDENCIES` environment handling
- Path mapping edge cases

---

#### TC-005: Exec Command & Post-hooks

**Test ID**: `crossfile-005`  
**Description**: Tests the `cross exec` command for running post-hooks and custom Justfile recipes.  
**Command**:
```bash
./test/bash/examples/crossfile-005.sh
```
**What it tests**:
- `cross exec` command execution
- Integration with user Justfile recipes
- Post-hook automation
- Command chaining in Crossfile

---

### Core Improvements Tests

#### TC-006: Core Improvements Suite

**Test ID**: `core-improvements`  
**Description**: Validates all core improvements implemented in Phase 7: patch arguments, branch detection, mkdir support, Crossfile idempotency, and sync safety.  
**Command**:
```bash
./test/bash/core-improvements.sh
```
**What it tests**:
- `remote:path:branch` syntax support
- Automatic branch detection (main/master)
- `mkdir -p` for intermediate directories
- Crossfile idempotency (no duplicates on re-run)
- Sync safety checks (uncommitted changes warning)

---

## Test Output & Results

### Log Files

Test runs generate logs in `test/results/`:

```
test/results/
├── examples/
│   ├── crossfile-001-bash.log
│   ├── crossfile-002-bash.log
│   ├── crossfile-003-bash.log
│   └── crossfile-005-bash.log
├── verification.json      # Machine-readable test report
└── verification.log        # Human-readable test log
```

### Interpreting Results

- **PASS**: Test completed successfully
- **FAIL**: Test failed (check log file for details)
- **SKIPPED**: Test script missing or not executable

View the JSON report:
```bash
cat test/results/verification.json | jq
```

---

## Running Tests in Isolation

Each test runs in a temporary workspace (`/tmp/cross-e2e-*`) and uses sandboxed git configuration:

- **No GPG signing** (uses `GIT_CONFIG_GLOBAL` override)
- **Isolated from user settings** (custom .gitconfig)
- **Clean environment** (no interference with `~/.gitconfig`)

To debug a specific test:

```bash
# Enable verbose mode
set -x
./test/bash/examples/crossfile-001.sh
```

---

## Test Scenarios (Advanced)

The test suite supports scenario-based execution:

### Examples Scenario (Default)
```bash
./test/run-all.sh --scenario examples
```
Runs all numbered Crossfile tests (001, 002, 003, 005).

### Use Scenario
```bash
./test/run-all.sh --scenario use
```
Tests alias registration and idempotency checks (not yet implemented).

### Patch Scenario
```bash
./test/run-all.sh --scenario patch
```
Tests patch workflow regression suite (not yet implemented).

### All Scenarios
```bash
./test/run-all.sh --scenario all
```
Runs every scenario sequentially.

---

## Creating New Tests

To add a new test:

1. **Create test script**: `test/bash/examples/crossfile-XXX.sh`
2. **Follow the pattern**:
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   
   workspace=${1:?"workspace path required"}
   ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
   
   # Your test logic here
   ```
3. **Create example Crossfile**: `examples/Crossfile-XXX`
4. **Update this documentation**: Add TC-XXX section above
5. **Test it**:
   ```bash
   ./test/bash/examples/crossfile-XXX.sh
   ```

---

## Troubleshooting

### Test fails with "unbound variable"
- Ensure you're using Bash ≥ 3.2
- Check that all required variables are initialized
- Run with `set -x` for debugging

### Test fails with "command not found: fish"
- Install fish shell: `brew install fish`
- Verify: `fish --version`

### Test fails with "command not found: just"
- Install just: `brew install just` or `cargo install just`
- Verify: `just --version`

### Fixture warnings
- The fixture tool (`scripts/fixture-tooling/seed-fixtures.sh`) is not yet implemented
- Tests use real git repositories instead (slower but functional)

---

## CI Integration

Tests are designed to run in CI environments:

```yaml
# Example GitHub Actions
- name: Run tests
  run: ./test/run-all.sh
  
- name: Upload test results
  uses: actions/upload-artifact@v3
  with:
    name: test-results
    path: test/results/
```

---

## Related Documentation

- [README.md](README.md#testing) - Quick start testing guide
- [specs/001-cross-test-strategy/](specs/001-cross-test-strategy/) - Detailed test strategy
- [AGENTS.md](AGENTS.md#testing) - Testing section for AI agents
