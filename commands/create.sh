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

    # Detect or validate project
    if [[ -z "$project" ]]; then
        project=$(detect_project)
        if [[ -z "$project" ]]; then
            die "Could not detect project. Use --project or run 'wt init' first."
        fi
    fi

    # Load project configuration
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

    # Claim a slot for reserved ports
    local slot
    if ! slot=$(claim_slot "$project" "$branch" "$PROJECT_RESERVED_SLOTS"); then
        die "No available slots. Maximum $PROJECT_RESERVED_SLOTS concurrent worktrees with reserved ports. Stop or delete an existing worktree first."
    fi

    log_info "Claimed slot $slot for worktree"

    # Create the worktree
    local wt_path
    if ! wt_path=$(create_worktree "$branch" "$base_branch" "$repo_root"); then
        release_slot "$project" "$branch"
        die "Failed to create worktree"
    fi

    # Store state
    create_worktree_state "$project" "$branch" "$wt_path" "$slot"

    # Export port variables for setup
    export_port_vars "$branch" "$PROJECT_CONFIG_FILE" "$slot"

    # Export global env vars
    export_env_vars "$PROJECT_CONFIG_FILE"

    # Run setup steps
    if [[ "$no_setup" -eq 0 ]]; then
        echo ""
        if ! execute_setup "$wt_path" "$PROJECT_CONFIG_FILE"; then
            log_warn "Setup completed with errors"
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

    # Run post_create hook if defined
    local post_create
    post_create=$(yaml_get "$PROJECT_CONFIG_FILE" ".hooks.post_create" "")
    if [[ -n "$post_create" ]] && [[ "$post_create" != "null" ]]; then
        export WORKTREE_PATH="$wt_path"
        export BRANCH_NAME="$branch"
        eval "$post_create"
    fi

    echo ""
    log_success "Worktree ready!"
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
