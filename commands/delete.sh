#!/bin/bash
# commands/delete.sh - Delete a worktree

cmd_delete() {
    local branch=""
    local force=0
    local keep_branch=0
    local project=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--force)
                force=1
                shift
                ;;
            --keep-branch)
                keep_branch=1
                shift
                ;;
            -p|--project)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_delete_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_delete_help
                return 1
                ;;
            *)
                if [[ -z "$branch" ]]; then
                    branch="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$branch" ]]; then
        log_error "Branch name is required"
        show_delete_help
        return 1
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    local repo_root="$PROJECT_REPO_PATH"

    local wt_path
    wt_path=$(worktree_path "$branch" "$repo_root")

    # Check if worktree exists on disk
    local worktree_on_disk=1
    if ! worktree_exists "$branch" "$repo_root"; then
        # Worktree directory is gone — check if we still have slot/state to clean up
        local has_slot
        has_slot=$(get_slot_for_worktree "$project" "$branch")
        local has_state
        has_state=$(get_worktree_state "$project" "$branch" "branch")

        if [[ -z "$has_slot" ]] && [[ -z "$has_state" ]]; then
            die "Worktree not found for branch: $branch"
        fi

        worktree_on_disk=0
        log_warn "Worktree directory missing, cleaning up slot and state for: $branch"
    fi

    # Confirmation
    if [[ "$force" -eq 0 ]]; then
        if ! confirm "Delete worktree for branch '$branch'?"; then
            log_info "Aborted"
            return 0
        fi
    fi

    # Stop all services first
    log_info "Stopping services..."
    stop_all_services "$project" "$branch" "$PROJECT_CONFIG_FILE" 2>/dev/null || true

    # Kill tmux window
    local window_name
    window_name=$(get_session_name "$project" "$branch")
    kill_session "$window_name" "$PROJECT_CONFIG_FILE" 2>/dev/null || true

    # Run pre_delete hook if defined
    export WORKTREE_PATH="$wt_path"
    export BRANCH_NAME="$branch"
    run_hook "$PROJECT_CONFIG_FILE" "pre_delete"

    # Remove worktree (only if it still exists on disk)
    if [[ "$worktree_on_disk" -eq 1 ]]; then
        if ! remove_worktree "$branch" "$force" "$keep_branch" "$repo_root"; then
            die "Failed to remove worktree"
        fi
    fi

    # Release slot — always attempt even if earlier steps had issues
    release_slot "$project" "$branch" 2>/dev/null || true

    # Delete state
    delete_worktree_state "$project" "$branch" 2>/dev/null || true

    # Run post_delete hook if defined
    run_hook "$PROJECT_CONFIG_FILE" "post_delete"

    log_success "Worktree deleted: $branch"
}

show_delete_help() {
    cat << 'EOF'
Usage: wt delete <branch> [options]

Delete a worktree and optionally the associated branch.

Arguments:
  <branch>          Branch name of the worktree to delete

Options:
  -f, --force       Force deletion even with uncommitted changes
  --keep-branch     Don't delete the git branch
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt delete feature/auth
  wt delete feature/auth --force
  wt delete feature/auth --keep-branch
EOF
}
