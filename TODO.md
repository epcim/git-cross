# TODO - git-cross

## Summary

**Status:** v0.2.0 released with feature parity across implementations  
**Critical Issues:** 1 (sync data loss)  
**Pending Enhancements:** 4 (prune, cd, single-file patch, fzf improvements)

## Core Implementation Status

- [x] Go Implementation (Primary) - Feature parity achieved.
- [x] Justfile/Fish - Fully functional original version.
- [x] Rust Implementation (Experimental/WIP) - Refactored to `git2` and `duct`.

## Infrastructure & Releases

- [x] Create ADR for Go-primary implementation strategy.
- [x] Implement GitHub Release builds for Go (via GoReleaser).
- [x] Implement GitHub Release builds for Rust (via Matrix/Artifacts).
- [x] Update README and status to reflect implementation priorities.
- [x] Setup unified Release workflow.

## Completed Tasks

- [x] Refactor remaining Rust commands to use `duct` for better error visibility.
- [x] Complete `push` command verification in native implementations.
- [x] Integrate integration tests (001-009) into a unified test runner.
- [x] Implement `cross install` command in Go to handle Git alias setup.
- [x] Implement `cross init` to setup a new project with Crossfile.
- [x] Update In README.md, an example how users can implement their "post-hook" actions.
- [x] Implement the test 006 for "push" command.
- [x] Implement the test 007 for "status" command.
- [x] Wire test 7 to github CI workflow.
- [x] Implement "cross" command in Rust.
- [x] Implement "cross" command in Golang.
- [x] Update AGENTS.md, specs/ and .specify/ to reflect new implementations.

## Future Enhancements / Backlog

### P1: High Priority
- [ ] **Implement `cross prune [remote name]`** - Remove git remote registration from "cross use" command and ask user whether to remove all git remotes without active cross patches (like after: cross remove), then `git worktree prune` to remove all worktrees. Optional argument (a remote repo alias/name) would enforce removal of all its patches together with worktrees and remotes.
  - **Effort:** 3-4 hours
  - **Files:** `src-go/main.go`, `src-rust/`, `Justfile.cross`, `test/015_prune.sh`

### P2: Lower Priority
- [ ] **Refactor `cross cd`** - Target local patched folder and output path (no subshell), supporting fzf. Enable pattern: `cd $(cross cd <patch>)`
  - **Effort:** 2-3 hours
  
- [ ] **Single file patch capability** - Review and propose implementation (tool and test) to be able to patch even single file. If not easily possible without major refactoring, evaluate new command "patch-file".
  - **Effort:** 4-6 hours (includes research)
  
- [ ] **Improve interactive `fzf` selection** in native implementations - Better UI, preview panes, multi-select for batch operations.
  - **Effort:** 3-5 hours

### Completed Enhancements

## Known Issues (To FIX)

### ✅ P0: Sync Command Data Loss (FIXED)

- [x] **Issue:** The `cross sync` command in Go (and Rust) did not preserve local uncommitted changes. When users modified files in patched directory and ran sync, changes were lost/reverted.

**Fix Applied (2025-01-06):**
- ✅ Go implementation (`src-go/main.go`): Added complete stash/restore workflow
- ✅ Rust implementation (`src-rust/src/main.rs`): Added complete stash/restore workflow  
- ✅ Justfile implementation (`Justfile.cross`): Added explicit stash/restore workflow with file deletion detection
- ✅ Test coverage enhanced (`test/004_sync.sh`): 6 comprehensive test scenarios
- ✅ Added cleanup logic between tests to handle conflicted worktree states
- ✅ Added file deletion detection: removes local files that were deleted upstream

**Workflow Now:**
```
1. Detect uncommitted changes (including untracked files) in local_path
2. Rsync git-tracked files WITH current uncommitted content: local_path → worktree
3. Stash uncommitted changes in local_path (with --include-untracked)
4. Commit changes in worktree
5. Check worktree state (recover from detached HEAD, abort in-progress operations)
6. Pull --rebase from upstream
7. Handle conflicts (exit if detected)
8. Detect and remove local files that were deleted upstream
9. Rsync worktree → local_path
10. Restore stashed changes
11. Detect and report merge conflicts
```

**Test Scenarios Covered:**
1. ✅ Basic sync with no local changes
2. ✅ Sync with uncommitted local changes (preserves them)
3. ✅ Sync with committed local changes
4. ✅ Sync with conflicting changes (graceful failure)
5. ✅ Sync with deleted upstream file (removes locally)
6. ✅ Sync with new upstream file (adds locally)

**Testing:** Run `just cross-test 004` to validate all scenarios  
**Impact:** Data loss risk eliminated, file synchronization complete  
**Status:** FIXED - Ready for v0.2.1 release
- [x] Updates to Crossfile can create duplicit lines (especially if user add spaces between remote_spec and local_spec.) Ideally we shall only check whether the local/path is already specified, and if yes then avoid update and avoid patch (as path exist.)
- [x] Extend the tests, start using <https://github.com/runtipi/runtipi-appstore/> and sub-path apps/ for "patches". Document this in test-case design.
- [x] Looks like the worktree created dont have any more "sparse checkout". Extend the validation, ie: that no other top-level files present in checkouts (assuming sub-path is used on remote repo)
- [x] If remote_spec contains "khue:master:/metal" the first slash shall be auto-removed
- [x] Remove " [branch]" string at end of some commented examples under ./examples, branch is now part of remote_spec.
- [x] on Golang implementation, the use command fails to autodetect and use real branch. example:

```sh
❯ git cross use bill       https://github.com/billimek/k8s-gitops
==> Adding remote bill (https://github.com/billimek/k8s-gitops)...
==> Autodetecting default branch...
==> Detected default branch: main
Error: exit status 128 - fatal: couldn't find remote ref main
```

- [x] on Golang implementation, the patch command can't properly use recognized branch, failed example:

```sh
❯ git cross patch khue:/metal deploy/metal
==> Patching khue:/metal to deploy/metal
==> Syncing files to deploy/metal...
Error: rsync failed: exit status 23
Log: {rsync: [sender] change_dir "/Users/p.michalec/Work/gitlab-f5-xc/f5/volterra/ves.io/sre/sre-ai/work/git-cross/testdir/sandbox/.git/cross/worktrees/khue_5a7cd8e3//metal" failed: No such file or directory (2)
rsync error: some files/attrs were not transferred (see previous errors) (code 23) at main.c(1358) [sender=3.4.1]
 sending incremental file list

sent 19 bytes  received 12 bytes  62.00 bytes/sec
total size is 0  speedup is 0.00
}
Usage:
  git-cross patch [spec] [local_path] [flags]

Flags:
  -h, --help   help for patch
```

- [x] on Golang implementation, the patch command doesn't accept properly the branch name in remote_spec.

```sh
 git cross patch khue:main:/metal deploy/metal
==> Patching khue:main:/metal to deploy/metal
==> Syncing files to deploy/metal...
Error: rsync failed: exit status 23
Log: {rsync: [sender] change_dir "/Users/p.michalec/Work/gitlab-f5-xc/f5/volterra/ves.io/sre/sre-ai/work/git-cross/testdir/sandbox/.git/cross/worktrees/khue_5f54dee3/main" failed: No such file or directory (2)
rsync error: some files/attrs were not transferred (see previous errors) (code 23) at main.c(1358) [sender=3.4.1]
 sending incremental file list

```
