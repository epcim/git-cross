import? "git.just"

# Delegate all invocations to the full recipe set
[no-cd]
[positional-arguments]
@cross *ARGS:
  REPO_DIR=$(git rev-parse --show-toplevel) \
  USER_CWD=${USER_CWD:-$(pwd)} \
  just --justfile "{{source_dir()}}/Justfile.cross" "$@"

# keep compatibility with `just test-cross`
[no-cd]
[positional-arguments]
@cross-test *ARGS:
  REPO_DIR=$(git rev-parse --show-toplevel) \
  just --justfile "{{source_dir()}}/Justfile.cross" test "$@"

# Run the Go implementation
[no-cd]
[positional-arguments]
@cross-go *ARGS:
  go run -C "{{source_dir()}}/src-go" main.go "$@"

# Install git alias for git-cross (Go or Just)
[no-cd]
@install impl="go":
  just --justfile "{{source_dir()}}/Justfile.cross" install {{impl}}

#_idea:
#  REPO_DIR=$(git rev-parse --show-toplevel) \
#  just --justfile "{{source_dir()}}/Justfile.cross" {{ARGS}}
