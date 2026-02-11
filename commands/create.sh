#!/bin/bash
# commands/create.sh - Create a new worktree

cmd_create() {
    local branch=""
    local base_branch=""
    local no_setup=0
    local project=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                base_branch="$2"
                shift 2
                ;;
            --no-setup)
                no_setup=1
                shift
                ;;
            -p|--project)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_create_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_create_help
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
        show_create_help
        return 1
    fi

    project=$(require_project "$project" "Could not detect project. Use --project or run 'wt init' first.")
    load_project_config "$project"

    # Verify we're in or at the repo
    local repo_root="$PROJECT_REPO_PATH"
    if [[ ! -d "$repo_root/.git" ]] && [[ ! -f "$repo_root/.git" ]]; then
        die "Not a git repository: $repo_root"
    fi

    # Check if worktree already exists
    if worktree_exists "$branch" "$repo_root"; then
        die "Worktree already exists for branch: $branch"
    fi

    # Run pre_create hook if defined
    export BRANCH_NAME="$branch"
    run_hook "$PROJECT_CONFIG_FILE" "pre_create"

    # Track state for cleanup on interrupt
    local _create_cleanup_project=""
    local _create_cleanup_branch=""
    local _create_cleanup_slot=""
    local _create_cleanup_wt_path=""

    _create_cleanup() {
        if [[ -n "$_create_cleanup_slot" ]]; then
            log_warn "Interrupted — cleaning up partial state..."
            release_slot "$_create_cleanup_project" "$_create_cleanup_branch" 2>/dev/null || true
            delete_worktree_state "$_create_cleanup_project" "$_create_cleanup_branch" 2>/dev/null || true
            if [[ -n "$_create_cleanup_wt_path" ]] && [[ -d "$_create_cleanup_wt_path" ]]; then
                git -C "$repo_root" worktree remove --force "$_create_cleanup_wt_path" 2>/dev/null || true
                git -C "$repo_root" worktree prune 2>/dev/null || true
            fi
        fi
    }
    trap _create_cleanup INT TERM

    # Claim a slot for reserved ports
    local slot
    if ! slot=$(claim_slot "$project" "$branch" "$PROJECT_RESERVED_SLOTS"); then
        die "No available slots. Maximum $PROJECT_RESERVED_SLOTS concurrent worktrees with reserved ports. Stop or delete an existing worktree first."
    fi
    _create_cleanup_project="$project"
    _create_cleanup_branch="$branch"
    _create_cleanup_slot="$slot"

    log_info "Claimed slot $slot for worktree"

    # Create the worktree
    local wt_path
    if ! wt_path=$(create_worktree "$branch" "$base_branch" "$repo_root"); then
        release_slot "$project" "$branch"
        _create_cleanup_slot=""  # Prevent double cleanup
        die "Failed to create worktree"
    fi
    _create_cleanup_wt_path="$wt_path"

    # Store state
    create_worktree_state "$project" "$branch" "$wt_path" "$slot"

    # Export port variables for setup
    export_port_vars "$branch" "$PROJECT_CONFIG_FILE" "$slot"

    # Export global env vars
    export_env_vars "$PROJECT_CONFIG_FILE"

    # Run setup steps
    local setup_failed=0
    if [[ "$no_setup" -eq 0 ]]; then
        echo ""
        if ! execute_setup "$wt_path" "$PROJECT_CONFIG_FILE"; then
            log_warn "Setup completed with errors"
            setup_failed=1
        fi
    else
        log_info "Skipping setup (--no-setup)"
    fi

    # Create tmux window in the main session
    echo ""
    local window_name
    window_name=$(get_session_name "$project" "$branch")

    create_session "$window_name" "$wt_path" "$PROJECT_CONFIG_FILE"
    set_session_state "$project" "$branch" "$window_name"

    # Creation complete, disable cleanup trap
    _create_cleanup_slot=""
    trap - INT TERM

    # Run post_create hook if defined
    export WORKTREE_PATH="$wt_path"
    export BRANCH_NAME="$branch"
    run_hook "$PROJECT_CONFIG_FILE" "post_create"

    echo ""
    if [[ "$setup_failed" -eq 1 ]]; then
        log_warn "Worktree created but setup had errors. You may need to run setup manually."
    else
        log_success "Worktree ready!"
    fi
    echo ""
    local tmux_session
    tmux_session=$(get_tmux_session_name "$PROJECT_CONFIG_FILE")
    print_kv "Branch" "$branch"
    print_kv "Path" "$wt_path"
    print_kv "Slot" "$slot"
    print_kv "tmux" "$tmux_session:$window_name"
    echo ""
    echo "Next steps:"
    echo "  wt start $branch --all    # Start all services"
    echo "  wt attach $branch         # Attach to tmux"
}

show_create_help() {
    cat << 'EOF'
Usage: wt create <branch> [options]

Create a new worktree for the specified branch.

Arguments:
  <branch>          Branch name for the worktree

Options:
  --from <branch>   Base branch to create from (default: current branch)
  --no-setup        Skip running setup steps
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt create feature/auth
  wt create feature/auth --from develop
  wt create bugfix/issue-123 --no-setup
EOF
}
