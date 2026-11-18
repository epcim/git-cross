import? "git.just"

# Delegate all invocations to the full recipe set; unknown (native git) commands
# fall through to the git passthrough: inside a crossed directory git runs against
# the cross's upstream worktree (GIT_DIR/GIT_WORK_TREE), elsewhere it fails early
# with a hint (ADR-002).
[no-cd]
[positional-arguments]
cross *ARGS:
    #!/usr/bin/env bash
    set -e
    JF="{{source_dir()}}/Justfile.cross"
    # Git `!`-aliases run from the REPO ROOT; GIT_PREFIX holds the caller's
    # original CWD (root-relative) — resolve USER_CWD through it (v0.5.2 fix,
    # mirrors the Go CLI's GIT_PREFIX handling).
    if [ -n "${GIT_PREFIX:-}" ]; then
        UC="$(git rev-parse --show-toplevel)/$GIT_PREFIX"
    else
        UC="$(pwd)"
    fi
    # Recipe existence check without spawning just: recipe lines start at column 0
    # with the name followed by a parameter or the colon (e.g. "use name url:", "init:").
    if [ "$#" -eq 0 ] || grep -Eq "^$1([[:space:]]|:)" "$JF"; then
        REPO_DIR=$(git rev-parse --show-toplevel) \
        USER_CWD="${USER_CWD:-$UC}" \
        just --justfile "$JF" "$@"
    else
        REPO_DIR=$(git rev-parse --show-toplevel) \
        USER_CWD="${USER_CWD:-$UC}" \
        just --justfile "$JF" _gitcmd "$@"
    fi

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
