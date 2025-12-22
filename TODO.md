# TODO - git-cross

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

## Known Issues (To FIX)

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
