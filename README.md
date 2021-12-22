
# git-cross is tool for mixing git repositories

TLDR;
Minimalist approach for mixing "parts" of git repositories.

Use `git add/checkout/commit/rebase` as you are used to, the script cut the complexity behind git worktrees, sparse checkout etc.

`Cross` allows you to mix sparse directories from your favourite upstreams to your local repo. As you do changes to spare branch,
updates back to origin repository is always easy.

## Requirements

Requires `git --version >= 2.20`.

## Usage

Configure your mixins in Cross* file:

```sh
  use core https://github.com/habitat-sh/core-plans
  use ncerny https://github.com/ncerny/habitat-plans

  # example: upstream/path [branch]
  patch core:consul
  patch core:cacerts
  patch core:etcd
  patch ncerny:cfssl
```

Track and checkout plans with:

```sh
./cross # to process Cross* file in repo
# or
./cross some ../some/remote/git/repo_url
./cross patch some:path/on/remote to/local/path [branch]
```


## Note

Do not overestimate features of this tool.

If you are interested in nesting 3rd party git repositories in your you probably want to use submodule or subtree feature instead.
Latest versions of git/submodule allows almost same behaviour.

## Other & similar projects

Very close idea:

 - https://github.com/ingydotnet/git-subrepo (generic approach)

Inspired by:

 - https://github.com/metacloud/gilt
 - https://github.com/capr/multigit
 - https://syslog.ravelin.com/multi-to-mono-repository-c81d004df3ce
 - https://github.com/unravelin/tomono
 - https://leewc.com/articles/how-to-merge-multiple-git-repositories-into-one-repo/
 - ...


## Example

```sh

❯ cat Cross 

# upstream
use khue	https://github.com/khuedoan/homelab
use bill	https://github.com/billimek/k8s-gitops
use mine	../test-git-cross-dummy

git remote -v | grep fetch | column -t

# stash?
# repo_is_clean || say "There are uncommitted changes in the repository. Stash them first." 1

# cross patches
# ex: origin:path/to/dir [local/path/to/dir] [-b branch]
patch mine:docs/another docs
patch khue:/metal deploy/metal
patch bill:/logs  deploy/logs


# hooks, are custom fn for triggers run in git-cross
cross_post_hook() {
  ask "Update upstream?" N && {
    echo "DOES NOTHING"
  }
}


❯ VERBOSE=true ./cross 
git remote add khue https://github.com/khuedoan/homelab
git remote add bill https://github.com/billimek/k8s-gitops
git remote add mine ../test-git-cross-dummy
bill  https://github.com/billimek/k8s-gitops  (fetch)
khue  https://github.com/khuedoan/homelab     (fetch)
mine  ../test-git-cross-dummy                 (fetch)

Tracking mine:docs/another (branch:master) at docs
git fetch --prune --depth=20 mine master:mine/docs
remote: Enumerating objects: 10, done.
remote: Counting objects: 100% (10/10), done.
remote: Compressing objects: 100% (4/4), done.
remote: Total 10 (delta 0), reused 0 (delta 0), pack-reused 0
Unpacking objects: 100% (10/10), 1.94 KiB | 283.00 KiB/s, done.
From ../test-git-cross-dummy
 * [new branch]      master     -> mine/docs
 * [new branch]      master     -> mine/master
git worktree add --no-checkout -B mine/master/docs/another ./docs --track mine/master
Preparing worktree (new branch 'mine/master/docs/another')
Branch 'mine/master/docs/another' set up to track remote branch 'master' from 'mine'.
git config --worktree --bool core.sparseCheckout true
git config --worktree --path core.worktree /Users/epcim/Workspace/apealive/test-git-cross/docs/..
git config --worktree status.showUntrackedFiles no
git checkout
Your branch is up to date with 'mine/master'.
git --git-dir=.git --work-tree=. add ./docs
warning: adding embedded git repository: docs
...
...
...


❯ git status
On branch main
Changes to be committed:
  (use "git restore --staged <file>..." to unstage)
	new file:   deploy/logs
	new file:   deploy/metal
	new file:   docs


❯ cd deploy/metal 
❯ git status
On branch khue/master/metal
Your branch is up to date with 'khue/master'.

You are in a sparse checkout with 24% of tracked files present.

nothing to commit (use -u to show untracked files)

```
