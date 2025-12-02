Known issues:

- [ ] README the basic example to clone git-cross is not valid, as it will fail first time (just cross, is not available). First time we need to clone the git-cross repo to vendor in an regular way.
- [ ] on `patch` command, we need to relocate branch parameter of the remote path (as third argument it's not confortable, as user has to always provide 2nd parameter; validate whether justfile can do some trick to set it deferent way ). Suggested "remote:branchName" "remote/path/to/dir" "local/path". Where only first two arguments are mandatory. And ":branchName" is an optional. Extend the fucntionality and if user will specify new branch that is not yet tracked, start tracking it (same remote, new .git/cross worktree). Alt. if remote is REMOTE_NAME:path/to/dir we can cosider that branch can be either identified as "@branch". Though, it;s easier to split string just by ":" and pick. The simpliest implementation and readability shall drive as well as git URL standards in opensource and golang ecosystem.
- [ ] on `use` command, function must corectly identify whether remote default branch is main or master or even other. This cmd can be used to identify remote default branch `git ls-remote --symref ${REPO_URL} HEAD`, right after "refs/heads"
- [ ] on `patch` command, the local path is optional and `patch` must be able to create intermediate directories
- [ ] on patch command, you need to sync that specific patch automatically  for the user
- [ ] there is a bug, and `Crossfile` is updated with commands, even they failed. That result in having wrong commands as well as not keeps the Crossfile lines uniq.  Fix and Extend tests and Examples directories to deeply test.
- [ ] ensure that with "sync" command, the local repository changes are preserved (user must stash them first (or commit). User basically has two options. Commit to local_path repo (then we would sync from upstream as we would doing rebase). Better would be if we inform user "that there are uncommited changes" in local/path, then ask whether they shall be commited to upstream (then next steps are obvious - diff> export VES_P12_PASSWORD=""

> terragrunt init --all
> terragrunt plan --all
> terragrunt apply --allhttps://docs.cloud.f5.com/docs-v2/multi-cloud-network-connect/how-to/site-management/create-secure-mesh-site-v2/patch to .git/cross worktree, commit, rebase originm and run regular sync.  Undestand sync to local_path is not just copy from upstream)

- [ ] github CI validations dont pass, fix github actions/workflows. If Github MCP would help ask for it to be configured first.
