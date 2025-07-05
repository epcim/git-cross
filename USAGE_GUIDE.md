# git-cross: Comprehensive Usage Guide

## Overview

`git-cross` is a powerful tool that enables you to mix and manage sparse directories from multiple git repositories in a single workspace. It provides a minimalist approach to managing code dependencies by leveraging git worktrees and sparse checkout features.

## Core Concept

Unlike traditional approaches like git submodules or subtrees, `git-cross` allows you to:
- **Selectively checkout** specific directories from remote repositories
- **Maintain independent tracking** of each directory as a separate git worktree
- **Easily contribute back** to upstream repositories from within your workspace
- **Manage dependencies** without complex merge conflicts or submodule complexity

## Architecture

```
Your Repository
├── .git/
│   ├── worktrees/
│   │   ├── patch1/          # Worktree for first patch
│   │   └── patch2/          # Worktree for second patch
│   └── refs/
│       ├── remotes/
│       │   ├── upstream1/
│       │   └── upstream2/
│       └── heads/
├── patch1/                  # Sparse checkout of upstream1:some/path
├── patch2/                  # Sparse checkout of upstream2:other/path
├── Cross                    # Configuration file
└── cross                    # Executable script
```

## Requirements

- Git version >= 2.20 (for proper worktree support)
- Bash shell
- Read/write access to target repositories

## Configuration File Format

Create a `Cross` file in your repository root:

```bash
# Define upstream repositories
use <name> <repository_url>

# Checkout specific paths
patch <name>:<remote_path> [local_path] [branch]

# Optional: Define hooks
cross_post_hook() {
    # Custom actions after patching
}
```

## Core Functions

### 1. `setup()`
**Purpose**: Initialize git configuration for cross-repository management

**What it does**:
- Disables embedded repository warnings
- Enables worktree configuration extensions
- Prunes stale worktrees

**Usage**: Automatically called when running `./cross`

```bash
# Git configurations applied:
git config advice.addEmbeddedRepo false
git config extensions.worktreeConfig true
git worktree prune
```

### 2. `use <name> <repository_url>`
**Purpose**: Register a remote repository for tracking

**Parameters**:
- `<name>`: Local alias for the remote repository
- `<repository_url>`: Git URL (https, ssh, or local path)

**Examples**:
```bash
use core https://github.com/habitat-sh/core-plans
use myorg git@github.com:myorg/shared-configs.git
use local ../another-project
```

**What it does**:
- Adds the repository as a git remote
- Skips if remote already exists
- Validates required parameters

### 3. `patch <name>:<remote_path> [local_path] [branch]`
**Purpose**: Checkout a specific directory from a remote repository

**Parameters**:
- `<name>:<remote_path>`: Remote name and path (e.g., `core:consul/config`)
- `[local_path]`: Optional local path (defaults to `<remote_path>`)
- `[branch]`: Optional branch name (defaults to `master`)

**Examples**:
```bash
# Checkout core:consul to local consul directory
patch core:consul

# Checkout core:consul to local services/consul directory
patch core:consul services/consul

# Checkout from specific branch
patch core:consul consul dev-branch
```

**Workflow**:
1. **First-time setup**:
   - Fetches the specified branch with shallow history
   - Creates a new git worktree for the path
   - Configures sparse checkout for the specific directory
   - Backs up existing local directory if present

2. **Subsequent runs**:
   - Fetches updates from remote
   - Optionally rebases local changes (if `CROSS_REBASE_ORIGIN=true`)
   - Handles stash/unstash of local changes during rebase

### 4. `remove <local_path>`
**Purpose**: Stop tracking a patched directory

**Parameters**:
- `<local_path>`: Local directory to remove

**What it does**:
- Removes the git worktree
- Deletes the tracking branch
- Removes the local directory

**Example**:
```bash
remove services/consul
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CROSS_DEFAULT_BRANCH` | `master` | Default branch to checkout |
| `CROSS_REBASE_ORIGIN` | `false` | Auto-rebase on updates |
| `CROSS_FETCH_DEPTH` | `20` | Shallow fetch depth |
| `VERBOSE` | `false` | Show git commands |

## Usage Patterns

### Basic Workflow

1. **Initialize your project**:
```bash
git init
git add .
git commit -m "Initial commit"
```

2. **Create Cross configuration**:
```bash
cat > Cross << 'EOF'
# Upstream repositories
use habitat https://github.com/habitat-sh/core-plans
use myconfigs https://github.com/myorg/configs

# Patches
patch habitat:consul
patch habitat:nginx
patch myconfigs:monitoring/prometheus monitoring
EOF
```

3. **Execute cross**:
```bash
./cross
```

### Advanced Configuration

```bash
# Cross file with hooks and custom settings
use upstream https://github.com/upstream/repo.git
use fork https://github.com/myorg/fork.git

# Multiple patches from same repo
patch upstream:service1/config configs/service1
patch upstream:service2/config configs/service2
patch fork:custom/addon addons/custom

# Environment settings
export CROSS_REBASE_ORIGIN=true
export CROSS_FETCH_DEPTH=50

# Post-processing hook
cross_post_hook() {
    local path="$1"
    echo "Processing $path"
    
    # Update dependencies
    if [[ -f "$path/requirements.txt" ]]; then
        pip install -r "$path/requirements.txt"
    fi
    
    # Custom validation
    if [[ -f "$path/validate.sh" ]]; then
        bash "$path/validate.sh"
    fi
}
```

### Contributing Back to Upstream

Working within a patched directory:

```bash
# Navigate to patched directory
cd configs/service1

# Check branch info
git branch -vv
# * upstream/master/service1/config 1234567 [upstream/master] Latest commit

# Make changes
echo "new_setting=value" >> app.conf
git add app.conf
git commit -m "Add new configuration setting"

# Push to fork (if you have write access)
git push origin HEAD:feature/new-setting

# Or create patch for upstream
git format-patch upstream/master --stdout > ../service1-improvements.patch
```

## Use Cases

### 1. **Microservices Configuration Management**
```bash
# Collect configurations from multiple services
use service1 https://github.com/team/service1
use service2 https://github.com/team/service2
use shared https://github.com/team/shared-configs

patch service1:config configs/service1
patch service2:config configs/service2
patch shared:monitoring configs/monitoring
```

### 2. **Documentation Aggregation**
```bash
# Collect documentation from multiple projects
use projectA https://github.com/org/projectA
use projectB https://github.com/org/projectB

patch projectA:docs/api docs/projectA
patch projectB:docs/user-guide docs/projectB
```

### 3. **Shared Library Management**
```bash
# Include shared components without full dependency
use ui-components https://github.com/org/ui-components
use utils https://github.com/org/common-utils

patch ui-components:components/buttons src/components/buttons
patch utils:validators src/utils/validators
```

### 4. **Infrastructure as Code**
```bash
# Collect infrastructure templates
use terraform-aws https://github.com/org/terraform-aws
use terraform-gcp https://github.com/org/terraform-gcp

patch terraform-aws:modules/vpc infrastructure/aws/vpc
patch terraform-gcp:modules/network infrastructure/gcp/network
```

## Command-Line Usage

### Execute Cross file
```bash
./cross
```

### Execute specific function
```bash
./cross setup
./cross use myremote https://github.com/user/repo
./cross patch myremote:path/to/dir
./cross remove local/dir
```

### With verbose output
```bash
VERBOSE=true ./cross
```

## Best Practices

### 1. **Repository Structure**
- Keep your `Cross` file in the repository root
- Use descriptive names for remote aliases
- Organize patches logically in subdirectories

### 2. **Branch Management**
- Use feature branches for local development
- Regularly sync with upstream using `CROSS_REBASE_ORIGIN=true`
- Create clean commits for upstream contributions

### 3. **Conflict Resolution**
- Always stash local changes before running cross updates
- Use `git status` in patched directories to check for conflicts
- Resolve conflicts manually when auto-rebase fails

### 4. **Security Considerations**
- Validate repository URLs before adding them
- Use SSH keys for repositories requiring authentication
- Be cautious with execute permissions on patched files

## Troubleshooting

### Common Issues

1. **"Branch already exists" error**:
```bash
# Clean up stale worktrees
git worktree prune
git branch -D problematic-branch
```

2. **Sparse checkout not working**:
```bash
# Verify sparse checkout configuration
cd patched-directory
git config core.sparseCheckout
cat .git/info/sparse-checkout
```

3. **Permission denied on push**:
```bash
# Check remote URL and credentials
git remote -v
git config --local user.name
git config --local user.email
```

4. **Rebase conflicts**:
```bash
# Manual conflict resolution
cd patched-directory
git status
# Edit conflicted files
git add .
git rebase --continue
```

### Debug Mode

Enable verbose output to see all git commands:
```bash
VERBOSE=true ./cross
```

### Health Check

Verify your cross setup:
```bash
# Check git version
git --version

# List worktrees
git worktree list

# Check remotes
git remote -v

# Verify sparse checkout
find . -name "sparse-checkout" -exec cat {} \;
```

## Comparison with Alternatives

| Feature | git-cross | git submodule | git subtree | git subrepo |
|---------|-----------|---------------|-------------|-------------|
| Partial checkout | ✅ | ❌ | ❌ | ❌ |
| Independent commits | ✅ | ✅ | ❌ | ✅ |
| Upstream contribution | ✅ | ✅ | ✅ | ✅ |
| Simple setup | ✅ | ❌ | ✅ | ✅ |
| Merge conflicts | ✅ Low | ❌ High | ❌ High | ✅ Low |
| Learning curve | ✅ Low | ❌ High | ✅ Medium | ✅ Medium |

## Extension Points

### Custom Hooks

Implement custom behavior by defining functions in your Cross file:

```bash
# Pre-patch hook
cross_pre_hook() {
    local path="$1"
    echo "About to patch $path"
}

# Post-patch hook
cross_post_hook() {
    local path="$1"
    echo "Patched $path"
    
    # Custom logic here
    if [[ -f "$path/package.json" ]]; then
        cd "$path" && npm install
    fi
}

# Dependency hook
dependencies_hook() {
    local path="$1"
    # Parse and install dependencies
    scripts/parse-deps.sh "$path"
}
```

### Integration with CI/CD

```yaml
# .github/workflows/cross-update.yml
name: Update Cross Dependencies
on:
  schedule:
    - cron: '0 2 * * 1'  # Weekly on Monday
  workflow_dispatch:

jobs:
  update:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - name: Update dependencies
        run: |
          CROSS_REBASE_ORIGIN=true ./cross
          if [[ $(git status --porcelain) ]]; then
            git add .
            git commit -m "Update cross dependencies"
            git push
          fi
```

## Contributing

To contribute to git-cross itself:

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass
5. Submit a pull request

## License

This tool is provided as-is. Use at your own risk and always backup your repositories before using cross-repository management tools.