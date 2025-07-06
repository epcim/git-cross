THIS SHOULD BE A LINTER ERROR#!/bin/bash
shopt -s expand_aliases

## git-cross: Tool for mixing git repositories using worktrees and sparse checkout
## 
## This tool enables selective checkout of directories from remote repositories
## into your local workspace, using git worktrees to maintain independent tracking
## of each directory while allowing easy contribution back to upstream repositories.

## NOTES:
## - To share features to upstream, commit on upstream branch with `cd patch; git cherry-pick ##### -Xtheirs`
## - Each patch creates an independent worktree with sparse checkout configuration
## - Minimum git version required: 2.20 (for proper worktree support)

# Global variables
W=.                           # Working directory for git worktrees
declare -a FETCHED=('')       # Array to track already processed patches
export _gitpth=$(which git)   # Git executable path

# DEFAULT ENVIRONMENT VARIABLES
export CROSS_DEFAULT_BRANCH=${CROSS_DEFAULT_BRANCH:-master}  # Will be overridden by CI
export CROSS_REBASE_ORIGIN=${CROSS_REBASE_ORIGIN:-false}     # Whether to auto-rebase on updates
export CROSS_FETCH_DEPTH=${CROSS_FETCH_DEPTH:-20}           # Shallow fetch depth for performance

# COLOR CONSTANTS for output formatting
export MAGENTA='\033[0;95m'
export YELLOW='\033[1;33m'
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export NC='\033[0m' # No Color

# CORE FUNCTIONS - These are the main functions available in Cross configuration files

## setup() - Initialize git configuration for cross-repository management
## 
## This function configures git for optimal worktree and sparse checkout usage:
## - Disables warnings about embedded repositories
## - Enables worktree configuration extensions
## - Prunes any stale worktrees from previous runs
## - Validates git version requirement
##
## Called automatically when running ./cross
setup() {
    # Validate git version requirement (minimum 2.20)
    validate_git_version
    
    # Configure git for cross-repository management
    git config advice.addEmbeddedRepo false      # Disable embedded repo warnings
    git config extensions.worktreeConfig true    # Enable worktree configuration
    git worktree prune                          # Clean up stale worktrees
    
    say "Git configuration initialized for cross-repository management"
}

## use() - Register a remote repository for tracking
##
## Parameters:
##   $1: Remote name (local alias for the repository)
##   $2: Repository URL (https, ssh, or local path)
##
## This function adds a remote repository to the local git configuration
## if it doesn't already exist. It validates that both parameters are provided
## and handles the case where the remote already exists gracefully.
##
## Example: use core https://github.com/habitat-sh/core-plans
use() {
    # Validate required parameters
    [[ -n "$1" ]] || say "ERROR: USE called without remote name argument" 1
    [[ -n "$2" ]] || say "ERROR: USE called without repository URL argument" 1
    
    local name="$1"
    local url="$2"
    
    # Add remote if it doesn't already exist
    if ! git remote show | grep -q "^${name}$"; then
        _git remote add "$name" "$url"
        say "Added remote: $name -> $url"
    else
        say "Remote '$name' already exists, skipping"
    fi
}

## remove() - Stop tracking a patched directory
##
## Parameters:
##   $1: Local path of the patch to remove
##
## This function completely removes a patch by:
## - Removing the git worktree
## - Deleting the associated tracking branch
## - Removing the local directory
##
## Example: remove services/consul
remove() {
    local path="$1"
    
    [[ -n "$path" ]] || say "ERROR: REMOVE called without path argument" 1
    
    # Check if worktree exists
    if [[ ! -d "$path" ]]; then
        say "WARNING: Directory '$path' does not exist"
        return 0
    fi
    
    # Get the branch name from the worktree
    local branch
    if [[ -d ".git/worktrees/$path" ]]; then
        branch=$(git --git-dir=".git/worktrees/$path" rev-parse --abbrev-ref HEAD 2>/dev/null)
    else
        say "WARNING: Worktree for '$path' not found"
    fi
    
    # Remove the worktree
    if git worktree list | grep -q "$path"; then
        _git worktree remove --force "$path"
        say "Removed worktree: $path"
    fi
    
    # Remove the branch if it exists
    if [[ -n "$branch" ]] && git branch | grep -q "$branch"; then
        _git branch --force -D "$branch"
        say "Removed branch: $branch"
    fi
    
    # Remove from FETCHED array
    local new_fetched=()
    for item in "${FETCHED[@]}"; do
        [[ "$item" != "$path" ]] && new_fetched+=("$item")
    done
    FETCHED=("${new_fetched[@]}")
}

## patch() - Track and checkout a specific directory from a remote repository
##
## Parameters:
##   $1: Remote specification in format "name:path" (e.g., "core:consul/config")
##   $2: Local path (optional, defaults to the remote path)
##   $3: Branch name (optional, defaults to CROSS_DEFAULT_BRANCH)
##
## This is the main function that:
## 1. Parses the remote specification
## 2. Creates a git worktree for the specific path
## 3. Configures sparse checkout to only include the specified directory
## 4. Handles updates and rebasing for subsequent runs
##
## Example: patch core:consul/config services/consul master
patch() {
    local from="$1"
    local orig=$(cut -d: -f1 <<<"$from")        # Extract remote name (e.g., "core")
    local opth=$(cut -d: -f2 <<<"$from")        # Extract remote path (e.g., "consul/config")
    local path="${2:-$opth}"                    # Local path (defaults to remote path)
    local branch="${3:-$CROSS_DEFAULT_BRANCH}"  # Branch name (defaults to master) - FIXED: was $4
    local fdepth=${CROSS_FETCH_DEPTH}           # Fetch depth for shallow clones
    
    # Validate input parameters
    [[ -n "$from" ]] || say "ERROR: PATCH called without remote specification" 1
    [[ "$from" == *:* ]] || say "ERROR: PATCH requires format 'remote:path', got '$from'" 1
    [[ -n "$orig" ]] || say "ERROR: Could not extract remote name from '$from'" 1
    [[ -n "$opth" ]] || say "ERROR: Could not extract remote path from '$from'" 1
    
    # Skip if already processed (prevents duplicate processing)
    [[ "${FETCHED[*]}" =~ $path ]] && {
        say "Path '$path' already processed, skipping"
        return 0
    }
    
    # Normalize paths (remove leading slashes)
    opth=${opth#/}
    path=${path#/}
    
    # Validate that remote exists
    if ! git remote show | grep -q "^${orig}$"; then
        say "ERROR: Remote '$orig' not found. Add it first with: use $orig <url>" 1
    fi
    
    # Internal helper functions
    _branch_exist() {
        # Check if the tracking branch exists
        git rev-parse --verify "$orig/$branch" &>/dev/null
    }
    
    _rebase_active() {
        # Check if a rebase is currently in progress
        test -d "$(git rev-parse --git-path rebase-merge)" || \
        test -d "$(git rev-parse --git-path rebase-apply)"
    }
    
    _worktree_branch_name() {
        # Generate a unique branch name for this worktree
        echo "$orig/$branch/$opth" | sed 's|/|_|g'
    }
    
    local worktree_branch=$(_worktree_branch_name)
    
    # FIRST-TIME SETUP: Create new worktree and configure sparse checkout
    if ! _branch_exist; then
        say "Tracking $orig:$opth (branch:$branch) at $path"
        
        # Fetch the remote branch with shallow history
        _git fetch --prune --depth="$fdepth" "$orig" "$branch:$orig/$branch" || {
            say "ERROR: Failed to fetch $orig/$branch. Check remote URL and branch name." 1
        }
        
        # Backup existing local directory if it exists
        if [[ -e "$W/$path" ]]; then
            say "Backing up existing directory: $path -> $path.crossed"
            mv "$W/$path" "$W/$path.crossed"
        fi
        
        # Create worktree with tracking branch
        _git worktree add --no-checkout -B "$worktree_branch" "$W/$path" --track "$orig/$branch" || {
            say "ERROR: Failed to create worktree for $path" 1
        }
        
        # Configure sparse checkout within the worktree
        pushd "$W/$path" || say "ERROR: Could not enter directory $W/$path" 1
        
        # Set up sparse checkout configuration
        local sparse_checkout=$(git rev-parse --git-path info/sparse-checkout)
        
        # Configure sparse checkout if not already configured
        if ! [[ -f "$sparse_checkout" && $(cat "$sparse_checkout" 2>/dev/null) =~ ^/$opth/?$ ]]; then
            say "Configuring sparse checkout for /$opth/"
            
            # Enable sparse checkout
            _git config --worktree --bool core.sparseCheckout true
            _git config --worktree --path core.worktree "$PWD/.."
            _git config --worktree status.showUntrackedFiles no
            
            # Create sparse checkout file
            mkdir -p "$(dirname "$sparse_checkout")"
            echo "/$opth/" > "$sparse_checkout"
        fi
        
        # Checkout the files
        _git checkout || say "ERROR: Failed to checkout files in $path" 1
        
        popd
        
        # Add the new worktree to the main repository's index
        _git --git-dir=.git --work-tree=. add "$W/$path"
        
    # SUBSEQUENT RUNS: Update existing worktree
    elif [[ -e "$W/$path" ]]; then
        say "Updating existing patch: $path"
        
        pushd "$W/$path" || say "ERROR: Could not enter directory $W/$path" 1
        
        # Fetch latest changes
        _git fetch --prune --depth="$fdepth" "$orig" "$branch" || {
            say "WARNING: Failed to fetch updates for $orig/$branch"
        }
        
        # Rebase local changes if requested
        if [[ "$CROSS_REBASE_ORIGIN" == "true" ]]; then
            say "Rebasing $path against $orig/$branch"
            
            # Check if rebase is already in progress
            if _rebase_active; then
                COLOR=$YELLOW say "$W/$path has rebase in progress. Skipped."
            else
                # Get git directory path
                local git_dir
                if [[ -f .git ]]; then
                    git_dir=$(sed 's/gitdir: //g' .git)
                else
                    git_dir=.git
                fi
                
                # Stash any uncommitted changes
                if ! git diff-index --quiet HEAD --; then
                    say "Stashing local changes before rebase"
                    _git --git-dir="$git_dir" stash push -m "cross-rebase-stash-$(date +%s)" || true
                fi
                
                # Perform rebase
                if _git rebase "$orig/$branch"; then
                    say "Rebase successful"
                else
                    say "WARNING: Rebase failed. Manual intervention required."
                fi
                
                # Restore stashed changes
                if _git --git-dir="$git_dir" stash list | grep -q "cross-rebase-stash"; then
                    say "Restoring stashed changes"
                    _git --git-dir="$git_dir" stash pop || {
                        say "WARNING: Failed to restore stashed changes. Check git stash."
                    }
                fi
            fi
        fi
        
        popd
    else
        say "ERROR: Expected directory $W/$path not found" 1
    fi
    
    # Mark this path as processed
    FETCHED+=("$path")
    
    # Call post-hook if defined
    if declare -f cross_post_hook > /dev/null; then
        cross_post_hook "$path"
    fi
}

# UTILITY FUNCTIONS

## validate_git_version() - Ensure git version meets minimum requirements
validate_git_version() {
    local git_version=$(git --version 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+' | head -1)
    
    if [[ -z "$git_version" ]]; then
        say "ERROR: Could not determine git version" 1
    fi
    
    local major=$(echo "$git_version" | cut -d. -f1)
    local minor=$(echo "$git_version" | cut -d. -f2)
    
    if [[ $major -lt 2 ]] || [[ $major -eq 2 && $minor -lt 20 ]]; then
        say "ERROR: git version $git_version is too old. Minimum required: 2.20" 1
    fi
}

## _git() - Wrapper for git commands with optional verbose output
##
## This wrapper function:
## - Shows git commands when VERBOSE=true
## - Provides consistent formatting for git output
## - Allows for future enhancements like logging or error handling
_git() {
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        echo -e "${COLOR:-$YELLOW}git $*${NC}" >&2
    fi
    "$_gitpth" "$@"
}

## repo_is_clean() - Check if the repository has uncommitted changes
##
## Returns:
##   0 (true) if repository is clean
##   1 (false) if repository has uncommitted changes
repo_is_clean() {
    git diff-index --quiet HEAD --
}

## pushd() - Silent directory change with stack management
##
## Enhanced version of pushd that:
## - Suppresses output for cleaner logs
## - Stores previous directory for popd()
pushd() {
    export OLDPWD="$PWD"
    cd "$@" >/dev/null || say "ERROR: Could not change to directory: $*" 1
}

## popd() - Silent return to previous directory
##
## Returns to the directory stored by pushd()
popd() {
    if [[ -n "$OLDPWD" ]]; then
        cd "$OLDPWD" >/dev/null || say "ERROR: Could not return to directory: $OLDPWD" 1
    else
        cd - >/dev/null || say "ERROR: No previous directory to return to" 1
    fi
}

## say() - Enhanced output function with color support
##
## Parameters:
##   $1: Message to display
##   $2: Optional exit code (if provided, script exits with this code)
##
## Features:
## - Colored output using COLOR variable or default MAGENTA
## - Outputs to stderr for better separation from command output
## - Optional exit functionality for error handling
say() {
    local message="$1"
    local exit_code="${2:-}"
    
    echo -e "\n${COLOR:-$MAGENTA}$message${NC}" >&2
    
    if [[ -n "$exit_code" ]]; then
        exit "$exit_code"
    fi
}

## ask() - Interactive prompt with Y/N default handling
##
## Parameters:
##   $1: Question to ask
##   $2: Default answer (Y or N)
##
## Returns:
##   0 for Yes/Y answers
##   1 for No/N answers
##
## Features:
## - Smart default handling based on second parameter
## - Case-insensitive input
## - Proper prompt formatting
ask() {
    local question="$1"
    local default="${2:-}"
    local prompt reply
    
    # Set up prompt based on default
    if [[ "${default:-}" =~ ^[Yy] ]]; then
        prompt="Y/n"
        default="Y"
    elif [[ "${default:-}" =~ ^[Nn] ]]; then
        prompt="y/N"
        default="N"
    else
        prompt="y/n"
        default=""
    fi
    
    # Loop until valid answer
    while true; do
        say "$question [$prompt]"
        read -r reply
        reply=${reply:-$default}
        
        case "$reply" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
            *) say "Please answer yes or no." ;;
        esac
    done
}

# MAIN EXECUTION LOGIC

## Main execution block
## This block only runs when the script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Enable strict error handling
    set -euo pipefail
    
    # Initialize git configuration
    setup
    
    # Handle command-line arguments
    if [[ $# -gt 0 ]]; then
        # Execute specific function with arguments
        fn="$1"
        shift
        
        # Validate function exists
        if ! declare -f "$fn" > /dev/null; then
            say "ERROR: Function '$fn' not found" 1
        fi
        
        # Execute function with remaining arguments
        "$fn" "$@"
    else
        # Default behavior: process Cross configuration file
        
        # Check repository cleanliness
        if ! repo_is_clean; then
            if [[ "${CROSS_NON_INTERACTIVE:-false}" == "true" ]]; then
                # In non-interactive mode (CI), continue with uncommitted changes
                say "WARNING: Uncommitted changes detected in non-interactive mode. Continuing..."
            elif ! ask "There are uncommitted changes in the repository. Continue?" Y; then
                say "Aborting due to uncommitted changes"
                exit 1
            fi
        fi
        
        # Find and source Cross configuration file
        cross_file=""
        if [[ -f "Cross" ]]; then
            cross_file="Cross"
        elif [[ -f "Cross.sh" ]]; then
            cross_file="Cross.sh"
        else
            for file in Cross*; do
                if [[ -f "$file" ]]; then
                    cross_file="$file"
                    break
                fi
            done
        fi
        
        if [[ -n "${cross_file:-}" ]]; then
            say "Processing configuration file: $cross_file"
            source "$cross_file"
        else
            say "No Cross configuration file found. Create one with 'use' and 'patch' commands."
            exit 1
        fi
    fi
fi