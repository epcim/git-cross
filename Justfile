# Detect Homebrew location (Intel: /usr/local, ARM: /opt/homebrew, Linux: /home/linuxbrew/.linuxbrew)
export HOMEBREW_PREFIX := if path_exists("/opt/homebrew") == "true" { "/opt/homebrew" } else if path_exists("/usr/local/Homebrew") == "true" { "/usr/local" } else if path_exists("/home/linuxbrew/.linuxbrew") == "true" { "/home/linuxbrew/.linuxbrew" } else { env_var_or_default('HOMEBREW_PREFIX', env_var('HOME') + "/homebrew") }
export PATH := env_var('HOME') + "/bin:" + HOMEBREW_PREFIX + "/bin:" + env_var('PATH')

# Execute "just cross"
@cross +ARGS:
  just {{ARGS}}

# Auto-setup environment on first use
# Auto-setup environment on first use
setup:
    #!/usr/bin/env fish
    # Check if direnv is available
    if command -v direnv >/dev/null && test -f .envrc
        if not direnv status | grep -q "Found RC allowed true"
            direnv allow .
        end
    end

# Show this help message
help:
    @echo "git-cross - Vendor parts of git repos into your project"
    @echo ""
    @echo "Usage:"
    @echo "  just <command> [options]"
    @echo "  ./cross <command> [options]  (wrapper script)"
    @echo ""
    @echo "Available commands:"
    @just --list --unsorted
    @echo ""
    @echo "Quick start:"
    @echo "  1. Add upstream repo:    just use <name> <url>"
    @echo "  2. Patch directory:      just patch <name>:<path> <local_path>"
    @echo "  3. Sync from upstream:   just sync"
    @echo " "
    @echo "For more details, see README.md"

# Check for required dependencies
check-deps:
    #!/usr/bin/env fish
    set -l missing
    for cmd in fish rsync git python3 jq yq
        if not command -v $cmd > /dev/null
            set missing $missing $cmd
        end
    end
    if test (count $missing) -gt 0
        echo "Missing: $missing"
        echo "Install with: brew install $missing"
        exit 1
    end

# Internal: resolve rspec and lpath from args or CWD
_resolve_context arg_rspec arg_lpath invocation_dir:
    #!/usr/bin/env fish
    set rspec {{arg_rspec}}
    set lpath {{arg_lpath}}
    
    # If arguments are provided, use them
    if test -n "$rspec" -a -n "$lpath"
        echo "$rspec|$lpath"
        exit 0
    end
    
    # Try to infer from invocation dir
    set cwd {{invocation_dir}}
    set git_root (git rev-parse --show-toplevel)
    set rel_cwd (string replace "$git_root/" "" "$cwd")
    
    # Check Crossfile for matching local path
    if test -f Crossfile
        while read -l line
            # Parse: [cross] patch <remote>:<path> <local> ...
            set parts (string split " " $line)
            set cmd_idx 1
            if test "$parts[1]" = "cross"
                set cmd_idx 2
            end
            
            if test "$parts[$cmd_idx]" = "patch"
                set p_local $parts[(math $cmd_idx + 2)] # Local path is 2 positions after command
                # Check if CWD is inside the patch local path
                if string match -q "$p_local*" "$rel_cwd"
                    set rspec $parts[(math $cmd_idx + 1)] # Remote spec is 1 position after command
                    set lpath $p_local
                    echo "$rspec|$lpath"
                    exit 0
                end
            end
        end < Crossfile
    end
    
    echo "Error: Could not infer context. Please provide remote:path and local_path." >&2
    exit 1

# Internal: append command to Crossfile (avoiding duplicates)
update_crossfile cmd:
    #!/usr/bin/env fish
    set CROSSFILE "Crossfile"
    # Create Crossfile with header if it doesn't exist
    if not test -f $CROSSFILE
        printf "# Crossfile - Auto-generated configuration\n# Run: just replay\n\n" > $CROSSFILE
    end
    # Only append if not already present
    if not grep -qF "{{cmd}}" $CROSSFILE
        echo "{{cmd}}" >> $CROSSFILE
    end

# Execute arbitrary shell command
exec +CMD:
    {{CMD}}

# Add a remote repository
use name url: check-deps (update_crossfile "cross use " + name + " " + url)
    echo here\
    @git remote show | grep -q "^{{name}}$" \
      || { git remote add {{name}} {{url}} && echo "Added remote: {{name}} -> {{url}}"; }

# Patch a directory from a remote into a local path
patch remote_spec local_path branch="master": check-deps (update_crossfile "cross patch " + remote_spec + " " + local_path + (if branch != "master" { " " + branch } else { "" }))
    #!/usr/bin/env fish
    set parts (string split -m1 : {{remote_spec}})
    set remote $parts[1]
    set remote_path $parts[2]
    test -n "$remote" -a -n "$remote_path" || begin
        echo "Error: Invalid format. Use remote:path"
        exit 1
    end
    git remote show | grep -q "^$remote\$" || begin
        echo "Error: Remote '$remote' not found. Run: just use $remote <url>"
        exit 1
    end
    set hash (echo $remote_path | md5sum | cut -d' ' -f1)
    set wt ".git/cross/worktrees/$remote"_"$hash"
    echo "Setting up hidden worktree at $wt..."
    if not test -d $wt
        mkdir -p (dirname $wt)
        echo "Fetching $remote {{branch}}..."
        git fetch $remote {{branch}}
        git rev-parse --verify "$remote/{{branch}}" >/dev/null || begin
            echo "Error: $remote/{{branch}} does not exist"
            exit 1
        end
        git worktree add --no-checkout -B "cross/$remote/{{branch}}/$hash" $wt "$remote/{{branch}}" >/dev/null 2>&1
        set sparse (git -C $wt rev-parse --git-path info/sparse-checkout)
        mkdir -p (dirname $sparse)
        echo "/$remote_path/" > $sparse
        git -C $wt config core.sparseCheckout true
        git -C $wt read-tree -mu HEAD >/dev/null 2>&1
    end
    echo "Syncing files to {{local_path}}..."
    mkdir -p {{local_path}}
    rsync -av --delete --exclude .git $wt/$remote_path/ {{local_path}}/
    echo "Done. {{local_path}} now contains files from $remote:$remote_path"

# Internal: sync local paths from Crossfile
_sync_from_crossfile:
    #!/usr/bin/env fish
    # Check if Crossfile exists
    if not test -f Crossfile
        echo "Note: No Crossfile found. Only worktrees were updated."
        exit 0
    end
    echo "Syncing changes to local paths..."
    while read -l line
        set parts (string split " " $line)
        # Determine if line starts with 'cross' prefix
        set cmd_idx 1
        if test "$parts[1]" = "cross"
            set cmd_idx 2
        end
        # Handle 'patch' command: sync worktree to local path
        if test "$parts[$cmd_idx]" = "patch"
            set rspec $parts[(math $cmd_idx + 1)]
            set lpath $parts[(math $cmd_idx + 2)]
            set rparts (string split -m1 : $rspec)
            set remote $rparts[1]
            set rpath $rparts[2]
            set hash (echo $rpath | md5sum | cut -d' ' -f1)
            set wt ".git/cross/worktrees/$remote"_"$hash"
            # Sync only if worktree exists
            if test -d $wt
                echo "  $lpath ← $rspec"
                mkdir -p $lpath
                rsync -a --delete --exclude .git $wt/$rpath/ $lpath/ >/dev/null 2>&1
            end
        # Handle 'exec' command: run post-hooks or custom commands
        else if test "$parts[$cmd_idx]" = "exec"
            set cmd_str (string join " " $parts[(math $cmd_idx + 1)..-1])
            echo "  exec: $cmd_str"
            eval $cmd_str
        end
    end < Crossfile
    echo "✅ Sync complete"

# Sync all patches from upstream
sync: check-deps
    #!/usr/bin/env fish
    test -d .git/cross/worktrees || begin
        echo "No worktrees found."
        exit 0
    end
    # First, update all worktrees from upstream
    for wt in .git/cross/worktrees/*
        test -d $wt || continue
        echo "Updating $wt..."
        # Stash local changes if any
        set dirty (git -C $wt status --porcelain)
        if test -n "$dirty"
            echo "Stashing local changes in $wt..."
            git -C $wt stash
        end
        set branch (git -C $wt rev-parse --abbrev-ref HEAD)
        set upstream (git -C $wt rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')
        git -C $wt pull --rebase >/dev/null 2>&1
        # Pop stash if we stashed
        if test -n "$dirty"
            echo "Popping stash in $wt..."
            git -C $wt stash pop
        end
    end
    # Then, sync changes to local paths using Crossfile
    just --quiet _sync_from_crossfile

# Diff local vs upstream
diff arg_rspec="" arg_lpath="": check-deps
    #!/usr/bin/env fish
    set context (just --quiet _resolve_context "{{arg_rspec}}" "{{arg_lpath}}" "{{invocation_directory()}}"); or exit 1
    set parts (string split "|" $context)
    set rspec $parts[1]
    set lpath $parts[2]
    
    set rparts (string split -m1 : $rspec)
    set remote $rparts[1]
    set rpath $rparts[2]
    
    set hash (echo $rpath | md5sum | cut -d' ' -f1)
    set wt ".git/cross/worktrees/$remote"_"$hash"
    
    if test -d $wt
        # Use git diff --no-index to compare directories
        # We exclude .git to avoid noise
        git diff --no-index $wt/$rpath $lpath || true
    else
        echo "Error: Worktree not found for $rspec"
        exit 1
    end

# Push changes back to upstream
push arg_rspec="" arg_lpath="": check-deps
    #!/usr/bin/env fish
    set context (just --quiet _resolve_context "{{arg_rspec}}" "{{arg_lpath}}" "{{invocation_directory()}}"); or exit 1
    set parts (string split "|" $context)
    set rspec $parts[1]
    set lpath $parts[2]
    
    set rparts (string split -m1 : $rspec)
    set remote $rparts[1]
    set rpath $rparts[2]
    
    set hash (echo $rpath | md5sum | cut -d' ' -f1)
    set wt ".git/cross/worktrees/$remote"_"$hash"
    
    test -d $wt || begin
        echo "Error: Worktree not found. Run 'just patch' first."
        exit 1
    end
    
    echo "Syncing changes from $lpath back to $wt..."
    rsync -av --delete --exclude .git $lpath/ $wt/$parts[2]/
    
    echo "---------------------------------------------------"
    echo "Worktree updated. Status:"
    git -C $wt status
    echo "---------------------------------------------------"
    
    while true
        read -P "Run (r), Manual (m), Cancel (c)? " choice
        switch $choice
            case r R
                echo "Committing and pushing..."
                pushd $wt
                git add .
                git commit -v
                set upstream (git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')
                set remote (string split -m1 / $upstream)[1]
                set branch (string split -m1 / $upstream)[2]
                git push $remote HEAD:$branch
                popd >/dev/null
                break
            case m M
                echo "Spawning subshell in $wt..."
                echo "Type 'exit' to return."
                echo "Type 'exit' to return."
                pushd $wt
                fish
                popd >/dev/null
                echo "Returned from manual mode."
            case c C
                echo "Cancelled."
                exit 0
            case '*'
                echo "Invalid choice."
        end
    end

# List all patches
list: check-deps
    #!/usr/bin/env fish
    if not test -f Crossfile
        echo "No patches found (Crossfile missing)."
        exit 0
    end
    
    printf "%-20s %-30s %-20s\n" "REMOTE" "REMOTE PATH" "LOCAL PATH"
    printf "%s\n" (string repeat -n 70 "-")
    
    while read -l line
        set parts (string split " " $line)
        set cmd_idx 1
        if test "$parts[1]" = "cross"
            set cmd_idx 2
        end

        if test "$parts[$cmd_idx]" = "patch"
            set remote_spec $parts[(math $cmd_idx + 1)] # Remote spec
            set local_path $parts[(math $cmd_idx + 2)] # Local path
            set rparts (string split -m1 : $remote_spec)
            printf "%-20s %-30s %-20s\n" $rparts[1] $rparts[2] $local_path
        end
    end < Crossfile

# Show status of all patches
status: check-deps
    #!/usr/bin/env fish
    if not test -f Crossfile
        echo "No patches found."
        exit 0
    end
    
    printf "%-20s %-15s %-15s %-15s\n" "LOCAL PATH" "DIFF" "UPSTREAM" "CONFLICTS"
    printf "%s\n" (string repeat -n 70 "-")
    
    while read -l line
        set parts (string split " " $line)
        set cmd_idx 1
        if test "$parts[1]" = "cross"
            set cmd_idx 2
        end

        if test "$parts[$cmd_idx]" = "patch"
            set remote_spec $parts[(math $cmd_idx + 1)] # Remote spec
            set local_path $parts[(math $cmd_idx + 2)] # Local path
            set rparts (string split -m1 : $remote_spec)
            set remote $rparts[1]
            set rpath $rparts[2]
            
            set hash (echo $rpath | md5sum | cut -d' ' -f1)
            set wt ".git/cross/worktrees/$remote"_"$hash"
            
            set diff_stat "Clean"
            set upstream_stat "Synced"
            set conflict_stat "No"
            
            if test -d $wt
                # Check diffs
                if not git diff --no-index --quiet $wt/$rpath $local_path 2>/dev/null
                     set diff_stat "Modified"
                end
                
                # Check upstream divergence
                set behind (git -C $wt rev-list --count HEAD..@{upstream} 2>/dev/null)
                set ahead (git -C $wt rev-list --count @{upstream}..HEAD 2>/dev/null)
                if test "$behind" -gt 0
                    set upstream_stat "$behind behind"
                else if test "$ahead" -gt 0
                    set upstream_stat "$ahead ahead"
                end
                
                # Check conflicts (basic check for unmerged entries in worktree)
                if git -C $wt ls-files -u | grep -q .
                    set conflict_stat "YES"
                end
            else
                set diff_stat "Missing WT"
            end
            
            printf "%-20s %-15s %-15s %-15s\n" $local_path $diff_stat $upstream_stat $conflict_stat
        end
    end < Crossfile

# Replay commands from Crossfile
replay: check-deps
    #!/usr/bin/env fish
    if not test -f "Crossfile"
        echo "No Crossfile found. Run 'just use' or 'just patch' to create one."
        exit 1
    end
    
    echo "Replaying Crossfile..."
    # Read each line from Crossfile
    while read -l line
        # Skip comments and empty lines
        if string match -r '^#' $line
            continue
        end
        if test -z "$line"
            continue
        end
        
        # If line starts with "cross", execute it directly via just
        if string match -q "cross *" $line
             echo "▶ just $line"
             just $line
        else
             # Backward compatibility for old format (implicit "cross")
             echo "▶ just cross $line"
             just cross $line
        end
    end < Crossfile
    
    echo "✅ Crossfile replay complete"
