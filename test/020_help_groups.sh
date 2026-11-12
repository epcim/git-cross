#!/usr/bin/env bash
# Test 020: grouped `git cross --help` output (Go CLI).
#
# The help must render the three command groups and list every visible
# command exactly once, under the right group.
source "$(dirname "$0")/common.sh"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO_BIN="$(ensure_go_bin "$PROJECT_ROOT")"

if [ -z "$GO_BIN" ]; then
    echo "SKIP: Go CLI unavailable; skipping grouped help test"
    exit 0
fi

cd "$PROJECT_ROOT"

help_output=$("$GO_BIN" --help 2>&1)
echo "$help_output"

# Print the body of one help section (lines between the title and the next
# section header such as "Flags:").
section_body() {
    printf '%s\n' "$help_output" | awk -v title="$1" '
        $0 == title { inside = 1; next }
        inside && /^[A-Za-z][A-Za-z &-]*:$/ { exit }
        inside { print }
    '
}

log_header "020: group titles are present"
for title in "Repository:" "Inspect & Navigate:" "Patch Lifecycle:"; do
    assert_contains "$help_output" "$title" "help is missing the '$title' group"
done
log_success "group titles present"

log_header "020: commands are listed under their group"
repo_section=$(section_body "Repository:")
inspect_section=$(section_body "Inspect & Navigate:")
patches_section=$(section_body "Patch Lifecycle:")

for cmd in compare init completion list status update; do
    printf '%s\n' "$repo_section" | grep -Eq "^  ${cmd}([[:space:]]|$)" \
        || fail "'$cmd' should be listed under 'Repository:'"
done
for cmd in cd wt diff; do
    printf '%s\n' "$inspect_section" | grep -Eq "^  ${cmd}([[:space:]]|$)" \
        || fail "'$cmd' should be listed under 'Inspect & Navigate:'"
done
for cmd in use patch remove prune; do
    printf '%s\n' "$patches_section" | grep -Eq "^  ${cmd}([[:space:]]|$)" \
        || fail "'$cmd' should be listed under 'Patch Lifecycle:'"
done
log_success "commands grouped correctly"

log_header "020: cd and wt stay adjacent"
inspect_order=$(printf '%s\n' "$inspect_section" | awk '/^  [a-z]/{print $1}')
adjacent=$(printf '%s\n' "$inspect_order" | awk 'prev=="cd" && $0=="wt" {found=1} {prev=$0} END{print found?"yes":"no"}')
[ "$adjacent" = "yes" ] || fail "cd and wt must be listed next to each other (got: $(printf '%s ' $inspect_order))"
log_success "cd/wt adjacency verified"

log_header "020: every visible command appears exactly once"
for cmd in compare init completion list status update cd wt diff use patch remove prune; do
    count=$(printf '%s\n' "$help_output" | grep -cE "^  ${cmd}([[:space:]]|$)")
    [ "$count" -eq 1 ] || fail "command '$cmd' should appear exactly once in help (found $count)"
done
# Cobra still renders the auto-generated 'help' command under "Additional
# Commands:". Tolerate it, but no documented command may end up ungrouped there.
additional_section=$(section_body "Additional Commands:")
for cmd in compare init completion list status update cd wt diff use patch remove prune; do
    if printf '%s\n' "$additional_section" | grep -Eq "^  ${cmd}([[:space:]]|$)"; then
        fail "'$cmd' must not fall into 'Additional Commands:' (missing GroupID)"
    fi
done
if printf '%s\n' "$help_output" | grep -Eq '^  cmp([[:space:]]|$)'; then
    fail "the 'cmp' alias must not get its own help row"
fi
if printf '%s\n' "$help_output" | grep -Eq '^  shell-init([[:space:]]|$)'; then
    fail "hidden 'shell-init' must not appear in help"
fi
log_success "all visible commands listed once"

log_header "020: -h still prints the grouped help"
short_help=$("$GO_BIN" -h 2>&1) || fail "-h should exit 0"
assert_contains "$short_help" "Repository:"
assert_contains "$short_help" "Inspect & Navigate:"
assert_contains "$short_help" "Patch Lifecycle:"
log_success "-h works"

log_header "020: help suggests the cross.diffTool setup"
assert_contains "$help_output" "cross.diffTool" "help should mention cross.diffTool setup"
assert_contains "$help_output" "--unset cross.diffTool" "help should show how to reset to the built-in default"
assert_contains "$help_output" "let g:DirDiffExcludes = '.git'" "help should show the correct DirDiff exclusion syntax"
assert_contains "$help_output" "DirDiff {left} {right}" "help should show the placeholder form"
if printf '%s\n' "$help_output" | grep -q "DirDiffIgnore="; then
    fail "help must not suggest the invalid 'DirDiffIgnore=' command"
fi
log_success "diffTool setup guidance present"

echo "Test 020 passed!"
