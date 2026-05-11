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
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                window="$2"
                shift 2
                ;;
            -p|--project)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
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

    project=$(require_project "$project")
    load_project_config "$project"

    # Bail early when the active multiplexer doesn't support attach.
    local _attach_mux _attach_wt_path
    _attach_mux=$(detect_multiplexer)
    case "$_attach_mux" in
        herdr)
            _attach_wt_path=$(get_worktree_path "$project" "$branch")
            local _attach_label
            _attach_label=$(get_session_name "$project" "$branch")

            if ! command_exists herdr; then
                die "herdr CLI not found in PATH. Install herdr or set WT_MULTIPLEXER=tmux."
            fi
            if ! command_exists jq; then
                die "jq is required to look up herdr tabs by label (prevents duplicate tabs). Install with 'brew install jq' or set WT_MULTIPLEXER=tmux."
            fi

            # Scope tab lookup to the active workspace so identically-named
            # tabs in other workspaces don't collide.
            local _herdr_tab_list_args=()
            if [[ -n "${HERDR_ACTIVE_WORKSPACE_ID:-}" ]]; then
                _herdr_tab_list_args+=(--workspace "$HERDR_ACTIVE_WORKSPACE_ID")
            fi

            local _attach_tab_id
            _attach_tab_id=$(herdr tab list "${_herdr_tab_list_args[@]}" 2>/dev/null \
                | jq -r --arg L "$_attach_label" '.result.tabs[]? | select(.label == $L) | .tab_id' 2>/dev/null \
                | head -1)
            if [[ -n "$_attach_tab_id" ]]; then
                if herdr tab focus "$_attach_tab_id" >/dev/null 2>&1; then
                    log_success "Focused herdr tab '$_attach_label'"
                    return 0
                fi
                log_warn "Found tab '$_attach_label' but failed to focus it; opening a new one"
            fi
            multiplexer_open_tab_herdr "$_attach_label" "$_attach_wt_path" 0
            return $?
            ;;
        none)
            _attach_wt_path=$(get_worktree_path "$project" "$branch")
            log_warn "No multiplexer available; cd into the worktree manually:"
            echo "  cd '$_attach_wt_path'"
            return 0
            ;;
    esac

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
            create_session "$window_name" "$wt_path" "$PROJECT_CONFIG_FILE" "$window"
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
  -w, --window      Create window at specific index (moves existing if occupied)
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt attach feature/auth
  wt attach feature/auth -w 2    # Create at window index 2
EOF
}
