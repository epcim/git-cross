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

# Run the Rust implementation
[no-cd]
@cross-rust *ARGS:
  cargo run --manifest-path "{{source_dir()}}/src-rust/Cargo.toml" -- {{ARGS}}

# Run the Go implementation
[no-cd]
@cross-go *ARGS:
  go run -C "{{source_dir()}}/src-go" main.go {{ARGS}}

#_idea:
#  REPO_DIR=$(git rev-parse --show-toplevel) \
#  just --justfile "{{source_dir()}}/Justfile.cross" {{ARGS}} 