# Contributing to git-cross

We welcome contributions! This document outlines our philosophy and coding standards.

## Project Philosophy

### Keep It Simple

`git-cross` is intentionally **minimalist**. We're not building a universe of features—we're building a **Swiss Army knife** for git vendoring.

**Core principles:**
- ✅ **Simple**: Easy to understand, easy to use
- ✅ **Readable**: Code should be self-documenting
- ✅ **Focused**: Do one thing well (vendor subdirectories)
- ❌ **Not**: A full dependency management system
- ❌ **Not**: A replacement for package managers

### Feature Criteria

Before proposing a new feature, ask:
1. Does it solve a common vendoring problem?
2. Can it be implemented in <50 lines of code?
3. Does it maintain simplicity for existing users?

If you answered "no" to any of these, consider if it belongs in a plugin/extension instead.

## Code Style Guide

### Shell Scripting (Fish/Bash)

#### 1. Conciseness Over Verbosity

**Prefer short-circuit syntax for simple checks:**
```fish
# ✅ Good
test -f .env && source .env || true
command -v git >/dev/null || echo "Git missing"

# ❌ Avoid (unless complex logic)
if test -f .env
    source .env
else
    true
end
```

**Use `if...end` for complex logic:**
```fish
# ✅ Good (complex condition)
if test -d $wt
    set dirty (git -C $wt status --porcelain)
    if test -n "$dirty"
        git -C $wt stash
    end
end
```

#### 2. Variable Naming

Use **short, consistent names**:
- `rspec` - remote spec (e.g., `demo:docs`)
- `lpath` - local path (e.g., `vendor/docs`)
- `rpath` - remote path component
- `git_root` - repository root
- `wt` - patch directory (the upstream work tree; `gitdir` for the bare `.git`)

**Rationale**: Shorter names improve readability in compact fish scripts.

#### 3. Verbosity in Output

Commands should have **1-2 informative echo statements max**:
```fish
# ✅ Good
echo "Materializing $lpath from $rspec..."
git --git-dir=$gitdir --work-tree=$wt checkout -f HEAD >/dev/null 2>&1
echo "Done. $lpath is the work tree for $rspec"

# ❌ Too verbose
echo "Cloning the bare gitdir..."
echo "Configuring sparse checkout..."
echo "Setting up git config..."
echo "Materializing the work tree..."
```

**Debugging**: Users can re-run with `@` prefix for verbose output (future feature).

### Justfile Recipes

#### 1. Self-Contained Recipes

Each recipe should be **independent** and not rely on global state:
```just
# ✅ Good
patch rspec lpath: check-deps
    #!/usr/bin/env fish
    # All logic self-contained
    
# ❌ Avoid
patch: setup-global-vars do-patch cleanup
```

#### 2. Language Choice

- **Fish**: Complex logic (loops, string manipulation, conditionals)
- **Bash**: Simple checks (`check-deps`)
- **Native just**: One-liners only

#### 3. Error Handling

Use fish's concise error handling:
```fish
# ✅ Good
set context (just --quiet _resolve_context ...); or exit 1

# ❌ Verbose
set context (just --quiet _resolve_context ...)
if test $status -ne 0
    exit 1
end
```

## Testing

### Test Structure

Tests are split into individual files for easier debugging:
- `test/test_helpers.sh` - Common functions
- `test/test_01_*.sh` - Individual test cases
- `test/test_all_commands.sh` - Full integration suite

### Writing Tests

```bash
#!/bin/bash
set -e
source "$(dirname "$0")/test_helpers.sh"

setup_test_env

# Your test logic here

echo "✅ Test passed"
cleanup_test_env
```

## Documentation

### README Updates

When adding features:
1. Update the command table
2. Add usage examples
3. Keep examples using `just cross` pattern
4. Update comparison table if relevant

### Code Comments

- **Do**: Explain *why*, not *what*
- **Don't**: State the obvious

```fish
# ✅ Good
# Stash to preserve local modifications during pull
git -C $wt stash

# ❌ Obvious
# Run git stash
git -C $wt stash
```

## Contribution Workflow

1. **Fork** the repository
2. **Create** a feature branch (`feature/my-feature`)
3. **Write** tests for your changes
4. **Ensure** all tests pass (`./test/test_all_commands.sh`)
5. **Keep** commits atomic and well-described
6. **Submit** a pull request

### Commit Messages

```
feat: add list command to show all patches

- Parses Crossfile and displays patches in table format
- Shows remote, remote path, and local path
- Closes #123
```

Format: `type: brief description`

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`

## Questions?

Open an issue or start a discussion. We're here to help!

---

**Remember**: Simple, readable, Swiss Army knife. Not a universe of features. 🔪