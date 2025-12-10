# Delegate all invocations to the full recipe set
[no-cd]
@cross *ARGS:
  REPO_DIR=$(git rev-parse --show-toplevel) \
  just --justfile "{{source_dir()}}/Justfile.cross" {{ARGS}}

# keep compatibility with `just test-cross`
[no-cd]
@cross-test *ARGS:
  REPO_DIR=$(git rev-parse --show-toplevel) \
  just --justfile "{{source_dir()}}/Justfile.cross" test "{{ARGS}}"

#_idea:
#  REPO_DIR=$(git rev-parse --show-toplevel) \
#  just --justfile "{{source_dir()}}/Justfile.cross" {{ARGS}} 