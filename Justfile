# Minimal proxy for git-cross commands
set export := true
set positional-arguments

# Delegate all invocations to the full recipe set
cross +ARGS:
  #!/usr/bin/env bash
  just --justfile "{{justfile_directory()}}/Justfile.cross" "$@"

# keep compatibility with `just test-cross`
cross-test *ARGS:
  just --justfile "{{justfile_directory()}}/Justfile.cross" test {{ARGS}}
