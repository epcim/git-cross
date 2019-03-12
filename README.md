
# git-cross is tool for mixing git repositories

TLDR;
Minimalist approach for mixing "parts" of git repositories.

Example usage: https://github.com/epcim/planfile

## Requirements

Requires `git --version >= 2.20`.

## Usage

Configure your mixins in *.cross:

```sh
  use core https://github.com/habitat-sh/core-plans
  use ncerny https://github.com/ncerny/habitat-plans

  # example: upstream/path [branch]
  section core/consul
  section core/cacerts
  section core/etcd
  section ncerny/cfssl
```

Track and checkout plans with:

```sh
./git-cross
```

Use `git add/checkout/commit/rebase` as you are used to.


## Note

Do not overestimate features of this tool. This is more concept rather than framework. If you are interested in nesting 3rd party git repositories in your you probably want to use subrepo or submodule instead.

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

