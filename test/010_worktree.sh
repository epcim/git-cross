#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

# The cd/wt commands are only implemented in Go and Rust, not in Justfile/shell
# Skip this test when using Justfile implementation
if [ "${TEST_USE_IMPL:-}" != "go" ] && [ "${TEST_USE_IMPL:-}" != "rust" ]; then
    echo "Skipping test 010: cd/wt commands only available in Go/Rust implementations"
    exit 0
fi

setup_sandbox
cd "$SANDBOX"

mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/fzf" <<'EOF'
#!/usr/bin/env bash
lines=()
while IFS= read -r line; do
  lines+=("$line")
done
for (( idx=${#lines[@]}-1; idx>=0; idx--)); do
  line="${lines[$idx]}"
  trimmed="$(echo "$line" | tr -d '[:space:]')"
  if [[ -z "$trimmed" ]]; then continue; fi
  if [[ "$line" == *"REMOTE"* && "$line" != *"/"* ]]; then continue; fi
  if [[ "$line" =~ ^[-+]+$ ]]; then continue; fi
  echo "$line"
  exit 0
done
exit 0
EOF
chmod +x "$SANDBOX/bin/fzf"
export PATH="$SANDBOX/bin:$PATH"

upstream_path=$(create_upstream "shell-worktree")
upstream_url="file://$upstream_path"

pushd "$upstream_path" >/dev/null
mkdir -p src
echo "shell data" > src/data.txt
git add src/data.txt
git commit -m "Add shell data" >/dev/null
popd >/dev/null

just cross use demo "$upstream_url"
just cross patch demo:src vendor/shell-src

# Test cd with explicit path
output=$(just cross dry=echo cd vendor/shell-src | grep "exec ")
if [[ "$output" != *"exec $SHELL"* ]]; then
    fail "cd with explicit path failed. Output: $output"
fi

# Test cd from patch directory (implicit context)
pushd vendor/shell-src >/dev/null
output=$(just cross dry=echo cd | grep "exec ")
if [[ "$output" != *"exec $SHELL"* ]]; then
    fail "cd from patch directory failed. Output: $output"
fi
popd >/dev/null

echo "Shell cd command tests passed!"
