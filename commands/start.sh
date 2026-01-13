#!/bin/bash
# commands/start.sh - Start services in a worktree

cmd_start() {
    local branch=""
    local service=""
    local all=0
    local attach=0
    local project=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--service)
                service="$2"
                shift 2
                ;;
            -a|--all)
                all=1
                shift
                ;;
            --attach)
                attach=1
                shift
                ;;
            -p|--project)
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_start_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_start_help
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
        show_start_help
        return 1
    fi

    # Detect or validate project
    if [[ -z "$project" ]]; then
        project=$(detect_project)
        if [[ -z "$project" ]]; then
            die "Could not detect project. Use --project option."
        fi
    fi

    # Load project configuration
    load_project_config "$project"

    # Verify worktree exists
    if ! worktree_exists "$branch" "$PROJECT_REPO_PATH"; then
        die "Worktree not found for branch: $branch"
    fi

    # Get slot for this worktree
    local slot
    slot=$(get_worktree_slot "$project" "$branch")

    if [[ -z "$slot" ]]; then
        die "Could not find slot for worktree. State may be corrupted."
    fi

    # Export port and env variables
    export_port_vars "$branch" "$PROJECT_CONFIG_FILE" "$slot"
    export_env_vars "$PROJECT_CONFIG_FILE"

    # Ensure tmux session exists
    local session
    session=$(get_session_name "$project" "$branch")

    if ! session_exists "$session"; then
        local wt_path
        wt_path=$(get_worktree_path "$project" "$branch")
        create_session "$session" "$wt_path" "$PROJECT_CONFIG_FILE"
    fi

    # Clean up stale service states
    cleanup_stale_services "$project" "$branch"

    # Start services
    if [[ "$all" -eq 1 ]]; then
        start_all_services "$project" "$branch" "$PROJECT_CONFIG_FILE"
    elif [[ -n "$service" ]]; then
        start_service "$project" "$branch" "$service" "$PROJECT_CONFIG_FILE"
    else
        log_error "Specify --all or --service <name>"
        show_start_help
        return 1
    fi

    # Run post_start hook if defined
    local post_start
    post_start=$(yaml_get "$PROJECT_CONFIG_FILE" ".hooks.post_start" "")
    if [[ -n "$post_start" ]] && [[ "$post_start" != "null" ]]; then
        export BRANCH_NAME="$branch"
        eval "$post_start"
    fi

    # Optionally attach
    if [[ "$attach" -eq 1 ]]; then
        echo ""
        attach_session "$session"
    fi
}

show_start_help() {
    cat << 'EOF'
Usage: wt start <branch> [options]

Start services in a worktree.

Arguments:
  <branch>          Branch name of the worktree

Options:
  -s, --service     Start a specific service
  -a, --all         Start all configured services
  --attach          Attach to tmux session after starting
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt start feature/auth --all
  wt start feature/auth --service gap-app-v2
  wt start feature/auth --all --attach
EOF
}
