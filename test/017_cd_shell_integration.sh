#!/usr/bin/env bash
# Test 017: cd/wt path-printing contract.
#
# The command cannot change the caller's shell, so it prints exactly one
# absolute path to stdout (hints go to stderr). No subshell, no clipboard.
# Without a path and without fzf: rows + hint, exit 1.
source "$(dirname "$0")/common.sh"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GO_BIN="$(ensure_go_bin "$PROJECT_ROOT")"

assert_one_abs_path() {
    local label=$1
    local output=$2
    local expected=$3
    local line_count
    line_count=$(printf '%s\n' "$output" | sed '/^$/d' | wc -l | tr -d ' ')
    [ "$line_count" -eq 1 ] || fail "$label: expected exactly one line, got $line_count: $output"
    case "$output" in
        /*) ;;
        *) fail "$label: expected an absolute path, got: $output" ;;
    esac
    assert_not_contains "$output" "Opening shell" "$label: must not open a subshell"
    assert_not_contains "$output" "clipboard" "$label: must not copy to the clipboard"
    [ "$output" = "$expected" ] || fail "$label: expected '$expected', got '$output'"
}

cd "$PROJECT_ROOT"
setup_sandbox
cd "$SANDBOX"

upstream_path=$(create_upstream "cd-wt-demo")
pushd "$upstream_path" >/dev/null
mkdir -p src
echo "upstream content" > src/file.txt
git add src/file.txt
git commit -m "Add src" -q
popd >/dev/null
upstream_url="file://$upstream_path"

# Create the patch with whichever implementation is available.
if [ -n "$GO_BIN" ]; then
    "$GO_BIN" use demo "$upstream_url" >/dev/null
    "$GO_BIN" set demo:src vendor/src >/dev/null
else
    just cross use demo "$upstream_url" >/dev/null
    just cross set demo:src vendor/src >/dev/null
fi

local_abs=$(cd vendor/src && pwd -P)
# ADR-001: `worktree` is stored and equals local_path — the upstream work tree IS
# the crossed directory inside the repo (there is no separate worktree anymore).
wt_rel=$(jq -r '.patches[] | select(.local_path == "vendor/src") | .worktree' .cross/metadata.json)
[ -n "$wt_rel" ] && [ "$wt_rel" != "null" ] || fail "metadata missing the vendor/src worktree"
[ "$wt_rel" = "vendor/src" ] || fail "worktree should equal local_path, got '$wt_rel'"
wt_abs=$(cd "$wt_rel" && pwd -P)
[ "$wt_abs" = "$local_abs" ] || fail "worktree and patch dir must resolve to the same directory"

# ---------------------------------------------------------------- Go section
if [ -n "$GO_BIN" ]; then
    log_header "017: Go cd prints one absolute path (the bare git passthrough)"
    out=$("$GO_BIN" cd vendor/src 2>/dev/null) || fail "Go cd with a path failed"
    assert_one_abs_path "Go cd vendor/src" "$out" "$local_abs"

    # wt runs git in the upstream context: the work tree root is the patch dir.
    out=$(cd vendor/src && "$GO_BIN" rev-parse --show-toplevel 2>/dev/null) \
        || fail "Go wt inside a patch failed"
    assert_one_abs_path "Go wt rev-parse --show-toplevel" "$out" "$local_abs"
    log_success "Go prints absolute paths"

    log_header "017: Go fzf-missing fallback prints rows and exits 1"
    nofzf_path=$(make_path_without_fzf "$SANDBOX/no-fzf-bin")

    cd_rc=0
    cd_out=$(PATH="$nofzf_path" "$GO_BIN" cd 2>"$SANDBOX/cd.err") || cd_rc=$?
    echo "$cd_out"
    echo "--- stderr ---"
    cat "$SANDBOX/cd.err"
    [ "$cd_rc" -eq 1 ] || fail "Go cd without fzf should exit 1, got $cd_rc"
    printf '%s\n' "$cd_out" | cut -f1 | grep -qx "vendor/src" \
        || fail "Go cd fallback should list local_path rows"
    printf '%s\n' "$cd_out" | cut -f2 | grep -q '^\.cross/worktrees/demo/' \
        || fail "Go cd fallback should list gitdir rows"
    assert_contains "$(cat "$SANDBOX/cd.err")" "fzf is not installed" \
        "Go cd fallback should say fzf is missing"
    log_success "Go fzf-missing fallback verified"

    log_header "017: Go no-path cd/wt auto-detect from CWD"
    pushd vendor/src >/dev/null
    out=$(PATH="$nofzf_path" "$GO_BIN" cd 2>/dev/null) \
        || fail "Go cd without a path inside a patch should auto-detect"
    assert_one_abs_path "Go cd (CWD auto-detect)" "$out" "$local_abs"
    popd >/dev/null

    log_header "017: Go completion prints scripts plus cd wrappers"
    comp_bash=$("$GO_BIN" completion bash 2>&1) || fail "completion bash should exit 0"
    assert_contains "$comp_bash" "xcd()" "bash completion should define xcd"
    assert_contains "$comp_bash" "gx()" "bash completion should define gx"
    assert_contains "$comp_bash" "git-cross" "bash completion should include the completion script"
    printf '%s\n' "$comp_bash" | bash -n || fail "bash completion output must be valid bash"

    comp_fish=$("$GO_BIN" completion fish 2>&1) || fail "completion fish should exit 0"
    assert_contains "$comp_fish" "function xcd" "fish completion should define xcd"
    assert_contains "$comp_fish" "function gx" "fish completion should define gx"
    assert_contains "$comp_fish" "complete -c git-cross" "fish completion should include the completion script"

    # $SHELL is used when the shell argument is omitted.
    comp_detected=$(SHELL=/usr/bin/fish "$GO_BIN" completion 2>&1)         || fail "completion should detect fish from \$SHELL"
    assert_contains "$comp_detected" "function xcd" "detected fish should emit fish wrappers"
    comp_detected=$(SHELL=/bin/zsh "$GO_BIN" completion 2>&1)         || fail "completion should detect zsh from \$SHELL"
    assert_contains "$comp_detected" "xcd()" "detected zsh should emit posix wrappers"

    # Undetectable/unsupported shells fail instead of guessing; fish is listed first.
    comp_unset=$(env -u SHELL "$GO_BIN" completion 2>&1); comp_rc=$?
    [ "$comp_rc" -eq 1 ] || fail "completion without SHELL should exit 1, got $comp_rc"
    assert_contains "$comp_unset" "fish, bash, zsh, powershell" "error hint should list fish first"
    comp_bad=$("$GO_BIN" completion tcsh 2>&1); comp_rc=$?
    [ "$comp_rc" -eq 1 ] || fail "unsupported shell should exit 1, got $comp_rc"
    assert_contains "$comp_bad" "fish, bash, zsh, powershell" "unsupported-shell hint should list fish first"

    # powershell gets completions only (no cd wrappers).
    comp_pwsh=$("$GO_BIN" completion powershell 2>&1) || fail "completion powershell should exit 0"
    assert_not_contains "$comp_pwsh" "xcd" "powershell output should not define wrappers"

    # shell-init is hidden but still functional.
    init_bash=$("$GO_BIN" shell-init bash 2>&1) || fail "shell-init bash should exit 0"
    assert_contains "$init_bash" "xcd()" "bash shell-init should define xcd"
    printf '%s\n' "$init_bash" | bash -n || fail "bash shell-init must be valid bash"
    init_fish=$("$GO_BIN" shell-init fish 2>&1) || fail "shell-init fish should exit 0"
    assert_contains "$init_fish" "function xcd" "fish shell-init should define xcd"
    help_out=$("$GO_BIN" --help 2>&1)
    assert_not_contains "$help_out" "shell-init" "shell-init must be hidden from help"
    assert_contains "$help_out" "completion" "completion must be visible in help"

    # init advertises the integration, tailored to $SHELL.
    probe="$SANDBOX/init-probe"
    mkdir -p "$probe"
    git -C "$probe" init -q
    fish_hint=$(cd "$probe" && rm -f Crossfile && SHELL=/usr/bin/fish "$GO_BIN" init 2>&1) \
        || fail "Go init (fish hint) should exit 0"
    assert_contains "$fish_hint" "git cross comp fish | source" \
        "fish init hint should use | source"
    bash_hint=$(cd "$probe" && rm -f Crossfile && SHELL=/bin/bash "$GO_BIN" init 2>&1) \
        || fail "Go init (posix hint) should exit 0"
    assert_contains "$bash_hint" 'eval "$(git cross comp)"' \
        "posix init hint should use eval"
    log_success "Go completion + hidden shell-init verified"
    log_success "Go CWD auto-detect verified"

    log_header "017: Go fzf selection prints the selected path"
    shim_dir="$SANDBOX/fzf-shim-bin"
    mkdir -p "$shim_dir"
    cat > "$shim_dir/fzf" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FZF_STDIN_FILE:-}" ]; then
    cat > "$FZF_STDIN_FILE"
else
    cat >/dev/null
fi
if [ -n "${FZF_ARGS_FILE:-}" ]; then
    printf '%s\n' "$@" > "$FZF_ARGS_FILE"
fi
if [ -n "${FZF_SELECT:-}" ]; then
    printf '%b\n' "$FZF_SELECT"
    exit 0
fi
exit 130
EOF
    chmod +x "$shim_dir/fzf"
    # New picker contract: "<aligned display><TAB><local_path>"
    selection="vendor/src       demo:src\tvendor/src"

    out=$(FZF_SELECT="$selection" PATH="$shim_dir:$PATH" "$GO_BIN" cd 2>/dev/null) \
        || fail "Go cd with an fzf selection failed"
    assert_one_abs_path "Go cd (fzf)" "$out" "$local_abs"

    log_header "017: Go fzf picker aligns local_path and labels"
    long_upstream=$(create_upstream "mxc-library")
    # Idempotent: the Go and Just sections share the sandbox.
    if ! git -C "$long_upstream" rev-parse --verify feature >/dev/null 2>&1; then
        pushd "$long_upstream" >/dev/null
        mkdir -p src pkg
        echo "src" > src/s.txt
        echo "pkg" > pkg/p.txt
        git add -A
        git commit -m "Add src and pkg" -q
        git checkout -q -b feature
        echo "more" >> pkg/p.txt
        git commit -qam "Feature change" -q
        popd >/dev/null
    fi
    "$GO_BIN" use mxc-library "file://$long_upstream" >/dev/null
    "$GO_BIN" set mxc-library:main:src vendor/mxcsrc >/dev/null 2>&1
    "$GO_BIN" set mxc-library:feature:pkg vendor/mxcpkg >/dev/null 2>&1

    maxlen=$(jq -r '[.patches[].local_path | length] | max' .cross/metadata.json)
    width=$((maxlen + 2))
    [ "$width" -lt 16 ] && width=16
    [ "$width" -gt 48 ] && width=48
    stdin_file="$SANDBOX/fzf-stdin.txt"
    args_file="$SANDBOX/fzf-args.txt"
    FZF_STDIN_FILE="$stdin_file" FZF_ARGS_FILE="$args_file" \
        PATH="$shim_dir:$PATH" "$GO_BIN" cd >/dev/null 2>&1 || true
    [ -s "$stdin_file" ] || fail "fzf picker should receive candidate rows"

    # Every row is "<display padded to width><TAB><local_path>"; the label must
    # start at column width+1, past the two-space gap.
    awk -F'\t' -v w="$width" '
        NF != 2 { bad = 1 }
        substr($1, w + 1, 1) == " " { bad = 1 }
        substr($1, w, 1) != " " { bad = 1 }
        $2 == "" { bad = 1 }
        END { exit bad ? 1 : 0 }
    ' "$stdin_file" || fail "picker rows must align at column $((width + 1)) and end with a TAB key"

    awk -F'\t' '$1 ~ /mxc-library:pkg \(feature\)$/ { found = 1 } END { exit found ? 0 : 1 }' "$stdin_file" \
        || fail "picker should show the branch for non-main patches"
    if awk -F'\t' '$1 ~ /mxc-library:src/ && $1 ~ /\(main\)/ { f = 1 } END { exit f ? 0 : 1 }' "$stdin_file"; then
        fail "picker should not show '(main)' for the default branch"
    fi

    header_val=$(awk '/^--header$/{ getline; print; exit }' "$args_file")
    expected_header="LOCAL_PATH$(printf '%*s' "$((width - 10))" '')REMOTE:REMOTE_PATH"
    [ "$header_val" = "$expected_header" ] \
        || fail "padded header mismatch: got '$header_val', want '$expected_header'"
    assert_contains "$(cat "$args_file")" "--with-nth=1" "picker should hide the key field"
    assert_contains "$(cat "$args_file")" "--delimiter" "picker should use TAB as the field delimiter"
    log_success "Go fzf picker alignment verified"
    log_success "Go fzf selection verified"
else
    echo "SKIP: Go CLI unavailable; skipping Go cd/wt assertions"
fi

# -------------------------------------------------------------- Just section
if command -v fish >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v just >/dev/null 2>&1; then
    log_header "017: Just cd prints one absolute path (the bare git passthrough)"
    if just_ref_implements cd; then
        out=$(just cross cd vendor/src 2>/dev/null) || fail "Just cd with a path failed"
        assert_one_abs_path "Just cd vendor/src" "$out" "$local_abs"
    else
        log_warn "SKIP (just): cd is Go-only — NOT IMPLEMENTED in the Just reference (v0.5.1)"
    fi

    out=$(cd vendor/src && just cross rev-parse --show-toplevel 2>/dev/null) \
        || fail "Just wt inside a patch failed"
    assert_one_abs_path "Just wt rev-parse --show-toplevel" "$out" "$local_abs"
    log_success "Just prints absolute paths"

    log_header "017: Just fzf-missing fallback prints rows and exits 1"
    if just_ref_implements cd; then
        nofzf_path=$(make_path_without_fzf "$SANDBOX/no-fzf-bin")

        cd_rc=0
        cd_out=$(PATH="$nofzf_path" just cross cd 2>&1) || cd_rc=$?
        echo "$cd_out"
        [ "$cd_rc" -eq 1 ] || fail "Just cd without fzf should exit 1, got $cd_rc"
        if ! printf '%s\n' "$cd_out" | awk -F'\t' '$1=="vendor/src"{found=1} END{exit found?0:1}'; then
            fail "Just cd fallback should list local_path<TAB>gitdir rows"
        fi
        assert_contains "$cd_out" "fzf is not installed" "Just cd fallback should say fzf is missing"
        log_success "Just fzf-missing fallback verified"
    else
        log_warn "SKIP (just): cd is Go-only — NOT IMPLEMENTED in the Just reference (v0.5.1)"
    fi

    log_header "017: Just fzf picker aligns local_path and labels"
    if just_ref_implements cd; then
    long_upstream=$(create_upstream "mxc-library")
    # Idempotent: the Go and Just sections share the sandbox.
    if ! git -C "$long_upstream" rev-parse --verify feature >/dev/null 2>&1; then
        pushd "$long_upstream" >/dev/null
        mkdir -p src pkg
        echo "src" > src/s.txt
        echo "pkg" > pkg/p.txt
        git add -A
        git commit -m "Add src and pkg" -q
        git checkout -q -b feature
        echo "more" >> pkg/p.txt
        git commit -qam "Feature change" -q
        popd >/dev/null
    fi
    just cross use mxc-library "file://$long_upstream" >/dev/null
    just cross set mxc-library:main:src vendor/mxcsrc >/dev/null 2>&1
    just cross set mxc-library:feature:pkg vendor/mxcpkg >/dev/null 2>&1

    maxlen=$(jq -r '[.patches[].local_path | length] | max' .cross/metadata.json)
    width=$((maxlen + 2))
    [ "$width" -lt 16 ] && width=16
    [ "$width" -gt 48 ] && width=48
    stdin_file="$SANDBOX/just-fzf-stdin.txt"
    args_file="$SANDBOX/just-fzf-args.txt"
    FZF_STDIN_FILE="$stdin_file" FZF_ARGS_FILE="$args_file" \
        PATH="$shim_dir:$PATH" just cross cd >/dev/null 2>&1 || true
    [ -s "$stdin_file" ] || fail "Just fzf picker should receive candidate rows"
    awk -F'\t' -v w="$width" '
        NF != 2 { bad = 1 }
        substr($1, w + 1, 1) == " " { bad = 1 }
        substr($1, w, 1) != " " { bad = 1 }
        $2 == "" { bad = 1 }
        END { exit bad ? 1 : 0 }
    ' "$stdin_file" || fail "Just picker rows must align at column $((width + 1)) and end with a TAB key"
    awk -F'\t' '$1 ~ /mxc-library:pkg \(feature\)$/ { found = 1 } END { exit found ? 0 : 1 }' "$stdin_file" \
        || fail "Just picker should show the branch for non-main patches"
    header_val=$(awk '/^--header$/{ getline; print; exit }' "$args_file")
    expected_header="LOCAL_PATH$(printf '%*s' "$((width - 10))" '')REMOTE:REMOTE_PATH"
    [ "$header_val" = "$expected_header" ] \
        || fail "Just padded header mismatch: got '$header_val', want '$expected_header'"
    log_success "Just fzf picker alignment verified"
    else
        log_warn "SKIP (just): cd is Go-only — NOT IMPLEMENTED in the Just reference (v0.5.1)"
    fi

    log_header "017: Just completion prints cd wrappers"
    if just_ref_implements comp; then
        comp_bash=$(just cross comp bash 2>&1) || fail "Just completion bash should exit 0"
        assert_contains "$comp_bash" "xcd()" "Just bash completion should define xcd"
        printf '%s\n' "$comp_bash" | bash -n || fail "Just bash completion must be valid bash"
        comp_fish=$(just cross comp fish 2>&1) || fail "Just completion fish should exit 0"
        assert_contains "$comp_fish" "function xcd" "Just fish completion should define xcd"
        comp_detected=$(SHELL=/usr/bin/fish just cross comp 2>&1)         || fail "Just completion should detect fish from \$SHELL"
        assert_contains "$comp_detected" "function xcd" "Just detection should emit fish wrappers"
        comp_unset=$(SHELL= just cross comp 2>&1); comp_rc=$?
        [ "$comp_rc" -eq 1 ] || fail "Just completion without SHELL should exit 1, got $comp_rc"
        assert_contains "$comp_unset" "fish, bash, zsh" "Just error hint should list fish first"
        init_bash=$(just cross shell-init bash 2>&1) || fail "Just shell-init bash should exit 0"
        assert_contains "$init_bash" "xcd()" "Just shell-init should still work"
    else
        log_warn "SKIP (just): comp/shell-init are Go-only — NOT IMPLEMENTED in the Just reference (v0.5.1)"
    fi
    probe="$SANDBOX/just-init-probe"
    mkdir -p "$probe"
    git -C "$probe" init -q
    fish_hint=$(cd "$probe" && rm -f Crossfile && SHELL=/usr/bin/fish just cross init 2>&1) \
        || fail "Just init (fish hint) should exit 0"
    assert_contains "$fish_hint" "git cross comp fish | source" \
        "Just fish init hint should use | source"
    bash_hint=$(cd "$probe" && rm -f Crossfile && SHELL=/bin/bash just cross init 2>&1) \
        || fail "Just init (posix hint) should exit 0"
    assert_contains "$bash_hint" 'eval "$(git cross comp)"' \
        "Just posix init hint should use eval"
    log_success "Just completion + shell-init verified"
else
    echo "SKIP: fish and/or jq/just unavailable — or cd/comp are Go-only (NOT IMPLEMENTED in the Just reference, v0.5.1); skipping Just cd/wt assertions"
fi

echo "Test 017 passed!"
