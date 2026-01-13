#!/bin/bash
# commands/attach.sh - Attach to a worktree's tmux session

cmd_attach() {
    local branch=""
    local window=""
    local project=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -w|--window)
                window="$2"
                shift 2
                ;;
            -p|--project)
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_attach_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_attach_help
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
        show_attach_help
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

    # Get session name
    local session
    session=$(get_session_name "$project" "$branch")

    # Check if session exists
    if ! session_exists "$session"; then
        # Try to create it if worktree exists
        if worktree_exists "$branch" "$PROJECT_REPO_PATH"; then
            log_info "Session not found, creating..."
            local wt_path
            wt_path=$(get_worktree_path "$project" "$branch")
            create_session "$session" "$wt_path" "$PROJECT_CONFIG_FILE"
        else
            die "No worktree or session found for branch: $branch"
        fi
    fi

    # Attach
    attach_session "$session" "$window"
}

show_attach_help() {
    cat << 'EOF'
Usage: wt attach <branch> [options]

Attach to the tmux session for a worktree.

Arguments:
  <branch>          Branch name of the worktree

Options:
  -w, --window      Select a specific window
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt attach feature/auth
  wt attach feature/auth --window servers
EOF
}
