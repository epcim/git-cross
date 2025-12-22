#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

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

# Test wt with explicit path
output=$(just cross dry=echo wt vendor/shell-src | grep "exec ")
if [[ "$output" != *"exec $SHELL"* ]]; then
    fail "wt with explicit path failed. Output: $output"
fi

# Test wt from patch directory (implicit context)
pushd vendor/shell-src >/dev/null
output=$(just cross dry=echo wt | grep "exec ")
if [[ "$output" != *"exec $SHELL"* ]]; then
    fail "wt from patch directory failed. Output: $output"
fi
popd >/dev/null

echo "Shell wt command tests passed!"
