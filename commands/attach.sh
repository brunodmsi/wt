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

    # If no branch specified, try to detect from current directory
    if [[ -z "$branch" ]]; then
        branch=$(detect_worktree_branch)
        if [[ -z "$branch" ]]; then
            log_error "Branch name is required"
            show_attach_help
            return 1
        fi
        log_info "Detected worktree branch: $branch"
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

    # Get window name (sanitized branch)
    local window_name
    window_name=$(get_session_name "$project" "$branch")

    # Get tmux session name from config
    local tmux_session
    tmux_session=$(get_tmux_session_name "$PROJECT_CONFIG_FILE")

    # Check if window exists, create if needed
    if ! session_exists "$tmux_session" || ! window_exists "$tmux_session" "$window_name"; then
        if worktree_exists "$branch" "$PROJECT_REPO_PATH"; then
            log_info "Window not found, creating..."
            local wt_path
            wt_path=$(get_worktree_path "$project" "$branch")
            create_session "$window_name" "$wt_path" "$PROJECT_CONFIG_FILE"
        else
            die "No worktree found for branch: $branch"
        fi
    fi

    # Attach to session and select window
    attach_session "$window_name" "$PROJECT_CONFIG_FILE"
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
