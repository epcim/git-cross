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
for title in "Crossed paths/dir operations:" "git cross overview:"; do
    assert_contains "$help_output" "$title" "help is missing the '$title' group"
done
log_success "group titles present"

log_header "020: commands are listed under their group"
crosses_section=$(section_body "Crossed paths/dir operations:")
overview_section=$(section_body "git cross overview:")

for cmd in use set del cfg update resolve; do
    printf '%s\n' "$crosses_section" | grep -Eq "^  ${cmd}([[:space:]]|$)" \
        || fail "'$cmd' should be listed under 'Crossed paths/dir operations:'"
done
for cmd in ls comp wipe; do
    printf '%s\n' "$overview_section" | grep -Eq "^  ${cmd}([[:space:]]|$)" \
        || fail "'$cmd' should be listed under 'git cross overview:'"
done
log_success "commands grouped correctly"

# v0.5.2: cd/wt are HIDDEN from help — a subprocess cannot cd the caller's
# shell; the xcd/gx-cd wrappers (git cross comp) do the real cd. The commands
# still work when invoked (the wrappers use them).
log_header "020: cd and wt stay hidden from help"
if printf '%s\n' "$help_output" | grep -Eq '^  (cd|wt)([[:space:]]|$)'; then
    fail "'cd'/'wt' must not get a help row (hidden: xcd / gx cd do the real cd)"
fi
log_success "cd/wt hidden from help"

log_header "020: every visible command appears exactly once"
for cmd in use set del cfg update resolve ls comp wipe; do
    count=$(printf '%s\n' "$help_output" | grep -cE "^  ${cmd}([[:space:]]|$)")
    [ "$count" -eq 1 ] || fail "command '$cmd' should appear exactly once in help (found $count)"
done
# Cobra still renders the auto-generated 'help' command under "Additional
# Commands:". Tolerate it, but no documented command may end up ungrouped there.
additional_section=$(section_body "Additional Commands:")
for cmd in use set del cfg update resolve ls comp wipe; do
    if printf '%s\n' "$additional_section" | grep -Eq "^  ${cmd}([[:space:]]|$)"; then
        fail "'$cmd' must not fall into 'Additional Commands:' (missing GroupID)"
    fi
done
if printf '%s\n' "$help_output" | grep -Eq '^  (compare|cmp)([[:space:]]|$)'; then
    fail "retired 'compare'/'cmp' must not get a help row"
fi
if printf '%s\n' "$help_output" | grep -Eq '^  shell-init([[:space:]]|$)'; then
    fail "hidden 'shell-init' must not appear in help"
fi
log_success "all visible commands listed once"

log_header "020: -h still prints the grouped help"
short_help=$("$GO_BIN" -h 2>&1) || fail "-h should exit 0"
assert_contains "$short_help" "Crossed paths/dir operations:"
assert_contains "$short_help" "git cross overview:"
assert_contains "$short_help" "git cross overview:"
log_success "-h works"

log_header "020: help documents the current configuration keys"
assert_contains "$help_output" "cross.depth" "help should document cross.depth"
assert_contains "$help_output" "cross.filter" "help should document cross.filter"
if printf '%s\n' "$help_output" | grep -q "cross.dirdifftool\|cross.diffTool"; then
    fail "help must not advertise the removed directory-diff keys"
fi
if printf '%s\n' "$help_output" | grep -q "compare"; then
    fail "help must not advertise the removed 'compare' command"
fi
log_success "configuration guidance matches v0.5.0"

log_header "020: help shows how to eval shell completions"
assert_contains "$help_output" "git cross comp fish | source" \
    "help should show the fish completion one-liner"
assert_contains "$help_output" 'eval "$(git cross comp)"' \
    "help should show the bash/zsh completion one-liner"
log_success "completion guidance present"

echo "Test 020 passed!"
