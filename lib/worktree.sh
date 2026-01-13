#!/bin/bash
# lib/worktree.sh - Git worktree operations

# Default worktree directory inside repo
WT_DIR_NAME=".worktrees"

# Get worktrees directory path
worktrees_dir() {
    local repo_root="${1:-$(git_root)}"
    echo "$repo_root/$WT_DIR_NAME"
}

# Get worktree path for a branch
worktree_path() {
    local branch="$1"
    local repo_root="${2:-$(git_root)}"

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    echo "$(worktrees_dir "$repo_root")/$sanitized"
}

# Check if a worktree exists for a branch
worktree_exists() {
    local branch="$1"
    local repo_root="${2:-$(git_root)}"

    local path
    path=$(worktree_path "$branch" "$repo_root")

    [[ -d "$path" ]]
}

# List all worktrees (excluding the main one)
list_worktrees() {
    local repo_root="${1:-$(git_root)}"

    git -C "$repo_root" worktree list --porcelain | while read -r line; do
        if [[ "$line" =~ ^worktree\ (.+) ]]; then
            local wt_path="${BASH_REMATCH[1]}"
            # Skip main worktree
            if [[ "$wt_path" != "$repo_root" ]]; then
                echo "$wt_path"
            fi
        fi
    done
}

# Get branch name for a worktree path
get_worktree_branch() {
    local wt_path="$1"
    local repo_root="${2:-$(git_root)}"

    git -C "$repo_root" worktree list --porcelain | awk -v path="$wt_path" '
        /^worktree / { wt = substr($0, 10) }
        /^branch / && wt == path { print substr($0, 19) }
    '
}

# Create a new worktree
# Usage: create_worktree <branch> [base_branch] [repo_root]
# Outputs: the worktree path on success (to stdout)
# All log messages go to stderr
create_worktree() {
    local branch="$1"
    local base_branch="${2:-}"
    local repo_root="${3:-$(git_root)}"

    local wt_path
    wt_path=$(worktree_path "$branch" "$repo_root")

    # Ensure .worktrees directory exists
    ensure_dir "$(worktrees_dir "$repo_root")"

    # Add .worktrees to .gitignore if not already there
    local gitignore="$repo_root/.gitignore"
    if [[ -f "$gitignore" ]]; then
        if ! grep -q "^$WT_DIR_NAME/?$" "$gitignore" 2>/dev/null; then
            echo "$WT_DIR_NAME/" >> "$gitignore"
            log_debug "Added $WT_DIR_NAME to .gitignore"
        fi
    fi

    local git_output
    local git_exit_code

    # Check if branch already exists
    if branch_exists "$branch"; then
        log_info "Branch '$branch' exists, creating worktree..." >&2
        git_output=$(git -C "$repo_root" worktree add "$wt_path" "$branch" 2>&1)
        git_exit_code=$?
    else
        # Branch doesn't exist, create it
        if [[ -n "$base_branch" ]]; then
            log_info "Creating branch '$branch' from '$base_branch'..." >&2
            git_output=$(git -C "$repo_root" worktree add -b "$branch" "$wt_path" "$base_branch" 2>&1)
            git_exit_code=$?
        else
            # Check if remote branch exists
            if remote_branch_exists "$branch"; then
                log_info "Tracking remote branch '$branch'..." >&2
                git_output=$(git -C "$repo_root" worktree add --track -b "$branch" "$wt_path" "origin/$branch" 2>&1)
                git_exit_code=$?
            else
                # Create from current branch
                local current
                current=$(current_branch)
                log_info "Creating branch '$branch' from '$current'..." >&2
                git_output=$(git -C "$repo_root" worktree add -b "$branch" "$wt_path" 2>&1)
                git_exit_code=$?
            fi
        fi
    fi

    if [[ $git_exit_code -eq 0 ]]; then
        log_success "Worktree created at: $wt_path" >&2
        # Only output the path to stdout (this is what gets captured)
        echo "$wt_path"
        return 0
    else
        log_error "Failed to create worktree: $git_output" >&2
        return 1
    fi
}

# Remove a worktree
# Usage: remove_worktree <branch> [force] [keep_branch] [repo_root]
remove_worktree() {
    local branch="$1"
    local force="${2:-0}"
    local keep_branch="${3:-0}"
    local repo_root="${4:-$(git_root)}"

    local wt_path
    wt_path=$(worktree_path "$branch" "$repo_root")

    if [[ ! -d "$wt_path" ]]; then
        log_warn "Worktree not found: $wt_path"
        return 1
    fi

    # Remove the worktree
    local force_flag=""
    if [[ "$force" == "1" ]]; then
        force_flag="--force"
    fi

    log_info "Removing worktree at: $wt_path"
    git -C "$repo_root" worktree remove $force_flag "$wt_path"

    if [[ $? -ne 0 ]]; then
        log_error "Failed to remove worktree. Use --force to force removal."
        return 1
    fi

    # Optionally delete the branch
    if [[ "$keep_branch" == "0" ]]; then
        if branch_exists "$branch"; then
            log_info "Deleting branch: $branch"
            git -C "$repo_root" branch -D "$branch" 2>/dev/null || true
        fi
    fi

    # Prune worktree metadata
    git -C "$repo_root" worktree prune

    log_success "Worktree removed: $branch"
    return 0
}

# Prune stale worktrees
prune_worktrees() {
    local repo_root="${1:-$(git_root)}"

    log_info "Pruning stale worktrees..."
    git -C "$repo_root" worktree prune -v
}

# Get worktree info
worktree_info() {
    local branch="$1"
    local repo_root="${2:-$(git_root)}"

    local wt_path
    wt_path=$(worktree_path "$branch" "$repo_root")

    if [[ ! -d "$wt_path" ]]; then
        return 1
    fi

    echo "path:$wt_path"
    echo "branch:$branch"

    # Get last commit info
    local commit_hash
    commit_hash=$(git -C "$wt_path" rev-parse --short HEAD 2>/dev/null)
    echo "commit:$commit_hash"

    local commit_msg
    commit_msg=$(git -C "$wt_path" log -1 --format="%s" 2>/dev/null)
    echo "message:$commit_msg"

    # Check if dirty
    if [[ -n $(git -C "$wt_path" status --porcelain 2>/dev/null) ]]; then
        echo "dirty:true"
    else
        echo "dirty:false"
    fi
}

# Execute a command in worktree context
exec_in_worktree() {
    local branch="$1"
    shift
    local repo_root="${REPO_ROOT:-$(git_root)}"

    local wt_path
    wt_path=$(worktree_path "$branch" "$repo_root")

    if [[ ! -d "$wt_path" ]]; then
        log_error "Worktree not found for branch: $branch"
        return 1
    fi

    log_debug "Executing in $wt_path: $*"
    (cd "$wt_path" && "$@")
}

# Count worktrees (excluding main)
count_worktrees() {
    local repo_root="${1:-$(git_root)}"
    list_worktrees "$repo_root" | wc -l | tr -d ' '
}

# Get all branches with worktrees
get_worktree_branches() {
    local repo_root="${1:-$(git_root)}"

    git -C "$repo_root" worktree list --porcelain | grep "^branch " | sed 's/branch refs\/heads\///'
}
