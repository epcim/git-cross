# GitHub Actions CI/CD Setup

## Created Workflows

### 1. `.github/workflows/ci.yml` - Main CI Pipeline

**Triggers:**
- Pull requests to `main`
- Pushes to `main`

**Features:**
- **Multi-OS Testing**: Runs on both Ubuntu and macOS
- **Dependency Installation**: Automatically installs `fish`, `rsync`, and `just`
- **Test Execution**: Runs all tests including individual test files
- **Test Coverage Report**: Generates coverage summary in GitHub Actions UI
- **ShellCheck**: Lints all shell scripts for best practices

**Jobs:**
1. `test` - Runs on Linux and macOS
2. `shellcheck` - Code quality checks
3. `status` - Overall status check

### 2. `.github/workflows/badges.yml` - Status Badges

**Triggers:**
- Pushes to `main`
- After CI workflow completes

**Features:**
- Generates CI status badge
- Creates test coverage badge
- Extracts version from CHANGELOG

### 3. `.github/workflows/release.yml` - Automated Releases

**Triggers:**
- Git tags matching `v*` (e.g., `v0.2.0`)

**Features:**
- Creates GitHub release automatically
- Extracts changelog for that version
- Includes installation instructions

## Status Badges in README

Added to README.md header:
- **CI Status**: Shows if tests are passing
- **License**: MIT license badge  
- **Version**: Current version from CHANGELOG

## Usage

### Running Tests Locally
```bash
./test/test_all_commands.sh  # Full test suite
./test/test_01_basic_patch.sh  # Individual test
```

### Creating a Release
```bash
# Tag and push
git tag v0.2.2
git push origin v0.2.2

# GitHub Actions will automatically:
# 1. Create a release
# 2. Extract changelog
# 3. Publish release notes
```

### Viewing CI Results
- All PRs will show CI status
- Click "Details" on PR checks to see full test results
- Test coverage appears in the Actions run summary

## Test Coverage Reporting

The CI workflow:
1. Runs all test scripts
2. Counts passed/failed tests
3. Calculates percentage
4. Displays results in GitHub Actions summary
5. Uploads coverage data as artifact

Coverage metrics:
- ✅ 90%+ = Green badge
- ⚠️  70-89% = Yellow badge  
- ❌ <70% = Red badge

## Next Steps

To enable all features:
1. Push these workflows to GitHub
2. Ensure Actions are enabled in repository settings
3. First run will generate badges
4. Badge URLs will be visible in Actions logs
