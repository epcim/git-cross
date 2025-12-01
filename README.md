# git-cross

[![CI](https://github.com/epcim/git-cross/workflows/CI/badge.svg)](https://github.com/epcim/git-cross/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Version](https://img.shields.io/badge/version-0.2.0-blue.svg)](https://github.com/epcim/git-cross/blob/main/CHANGELOG.md)

**Git's CRISPR.** 🧬

Minimalist approach for mixing "parts" of git repositories using `git worktree` + `rsync`.
This allows you to "vendor" files from other repositories directly into your source tree (so they are real files, not submodules), while still maintaining a link to the upstream for updates and contributions.

## Why git-cross?

| Feature | git-cross | Submodules | git-subrepo |
|---------|-----------|------------|-------------|
| **Physical files** | ✅ Yes | ❌ Gitlinks only | ✅ Yes |
| **Easy to modify** | ✅ Direct edits | ⚠️ Complex | ✅ Direct edits |
| **Partial checkout** | ✅ Subdirectories | ❌ Entire repo | ❌ Entire repo |
| **Upstream sync** | ✅ Bidirectional | ⚠️ Complex | ⚠️ Merge commits |
| **Commit visibility** | ✅ In main repo | ❌ Separate | ✅ In main repo |
| **Learning curve** | ✅ Simple | ❌ Steep | ⚠️ Moderate |
| **Reproducibility** | ✅ Crossfile | ⚠️ .gitmodules | ⚠️ Manual |
| **Dependencies** | `just` + `fish` | Git only | Bash script |

**Perfect for:**

- Vendoring specific components from monorepos
- Sharing code between microservices  
- Contributing to upstream while maintaining local customizations
- Avoiding submodule hell

## Requirements

- `git` (>= 2.20)
- `just` (Command runner)
- `fish` (Shell, used internally for complex logic)
- `rsync`

## TLDR

```bash
cd $YOUR_REPO
just cross use demo https://github.com/example/demo.git
just cross patch demo:docs vendor/docs
just cross [sync|diff|push|list|status|...]
```

## Installation

### Option 1: Include in Your Justfile (Recommended)

**Step 1**: Vendor the git-cross Justfile into your project:

```bash
# Use git-cross to vendor itself! (meta, right?)
just cross use git-cross https://github.com/epcim/git-cross.git
just cross patch git-cross:. vendor/git-cross
```

**Step 2**: Add to your project's `Justfile`:

```just
# Import git-cross commands
import? 'vendor/git-cross/Justfile'
```

> **Note**: `just` doesn't support importing from URLs directly (e.g., `import? 'https://...'`). You must vendor the Justfile locally first. The `import?` directive uses `?` to make the import optional, so it won't fail if the file doesn't exist yet.

**Alternative**: If you don't want to vendor, use a local clone:

```just
# In your own Justfile
import? '../git-cross/Justfile'
```

### Option 2: Standalone Installation

1. **Clone the repository:**

   ```bash
   git clone https://github.com/epcim/git-cross.git
   cd git-cross
   ```

2. **Setup environment** (optional but recommended):
   - **Direnv**: Run `direnv allow` (if you use direnv).
   - **Manual**: Run `source .env`.

3. **Verify installation:**

   ```bash
   just cross check-deps
   # or if .env is sourced:
   cross check-deps
   ```

## Usage

All commands can be invoked with `just cross <command>` or directly as `cross <command>` if you've sourced `.env`.

**Recommended pattern**: `just cross <command>` (works everywhere, no environment setup needed)

### Core Commands

#### `use` - Add a Remote Repository

Add external repositories you want to pull from:

```bash
just cross use <name> <url>
```

**Example:**

```bash
just cross use demo https://github.com/example/demo.git
just cross use homelab https://github.com/khuedoan/homelab
```

This configuration is automatically saved to `Crossfile`.

---

#### `patch` - Vendor a Directory

Pull a specific directory from a remote into your local tree:

```bash
just cross patch <remote>:<remote_path> <local_path> [branch]
```

**Example:**

```bash
just cross patch demo:docs vendor/docs
just cross patch homelab:metal/roles vendor/ansible/roles master
```

**What happens:**

- Creates a hidden worktree for the remote
- Sparse-checkouts only the specified path
- Syncs files to your local path using `rsync`
- Auto-saves configuration to `Crossfile`

---

#### `sync` - Update from Upstream

Update all vendored dependencies from their upstreams:

```bash
just cross sync
```

**What happens:**

- Pulls latest changes into hidden worktrees
- Uses `git stash` to preserve local modifications in worktrees
- Automatically syncs updated files to your local paths
- Pops stash after update

---

#### `list` - Show All Patches

Display all configured patches:

```bash
just cross list
```

**Example output:**

```
REMOTE               REMOTE PATH                    LOCAL PATH          
----------------------------------------------------------------------
demo                 docs                           vendor/docs         
homelab              metal/roles                    vendor/ansible/roles
```

---

#### `status` - Check Patch Status

Show the status of all patches (modifications, upstream divergence, conflicts):

```bash
just cross status
```

**Example output:**

```
LOCAL PATH           DIFF            UPSTREAM        CONFLICTS       
----------------------------------------------------------------------
vendor/docs          Modified        Synced          No              
vendor/ansible/roles Clean           2 behind        No              
```

**Status indicators:**

- **DIFF**: `Clean` | `Modified` | `Missing WT`
- **UPSTREAM**: `Synced` | `N ahead` | `N behind`
- **CONFLICTS**: `No` | `YES`

---

### Contributing Back Upstream

#### `diff-patch` - Compare Local vs Upstream

Check what you've changed locally:

```bash
# Explicit arguments:
| `just cross diff` | `remote:path` `local/path` | Show diff between local and upstream |
| `just cross push` | `remote:path` `local/path` | Push local changes back to upstream |
| `just cross replay` | | Re-run all patches from `Crossfile` |

### 4. Check Status

See what's changed in your vendored paths:

```bash
just cross status
```

### 5. View Diffs

Compare your local changes against the upstream version:

```bash
just cross diff
```

### 6. Push Changes Upstream

When you're ready to contribute back:

```bash
just cross push
```

This will:

1. Sync your local changes to the hidden worktree
2. Show you the diff
3. Ask for confirmation (Run/Manual/Cancel)
4. Commit and push to the upstream remote

> **Tip**: `diff` and `push` automatically infer arguments if you run them from inside a vendored directory!ntrol

- **Cancel (c)**: Abort without changes

**Example:**

```bash
cd vendor/docs
# Make changes to files
just cross push-upstream
# Choose 'r' to commit and push, or 'm' for manual control
```

---

### Reproducibility

#### `replay` - Restore from Crossfile

Restore your environment from `Crossfile` (e.g., after cloning):

```bash
just cross replay
```

This executes all `use` and `patch` commands stored in `Crossfile`, recreating your vendored setup.

---

## Concept: Git's CRISPR

Like CRISPR gene editing, `git-cross` precisely targets and vendors specific subdirectories from upstream repos, allowing you to "edit" your codebase without full integration (like submodules) or complete detachment (like copy-paste).

**Key advantages:**

- ✅ Physical files in your repo (not gitlinks)
- ✅ Easy to modify and commit
- ✅ Maintains upstream link for updates
- ✅ Bidirectional sync (pull updates, push contributions)
- ✅ Reproducible via `Crossfile`

## How It Works

Under the hood, `git-cross` uses:

- **Git worktrees**: Hidden worktrees in `.git/cross/worktrees/`
- **Sparse checkout**: Only checks out specified paths
- **Rsync**: Syncs files between worktree and your visible directory
- **Crossfile**: Auto-generated configuration for reproducibility

## Future Roadmap

### Git Plugin Integration

We're considering integrating `git-cross` as a native git plugin, enabling:

```bash
git cross use demo https://github.com/example/demo.git
git cross patch demo:docs vendor/docs
git cross sync
```

This would make `git-cross` feel like a first-class git feature while maintaining the simplicity of the current implementation.

**How it would work:**

- Create `git-cross` executable in `$PATH`
- Git automatically recognizes `git-cross` as `git cross`
- Keep the `Justfile` as the implementation backend
- Maintain backward compatibility with `just cross`

**Status**: 🔮 Future consideration - feedback welcome!

## License

MIT
