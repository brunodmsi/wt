#!/bin/bash
# commands/send.sh - Send command to a tmux pane

cmd_send() {
    local branch=""
    local project=""
    local target=""
    local -a cmd_parts=()
    local -a positionals=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires an argument"
                    return 1
                fi
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_send_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_send_help
                return 1
                ;;
            *)
                positionals+=("$1")
                shift
                ;;
        esac
    done

    # Try to detect branch from current directory
    local detected_branch
    detected_branch=$(detect_worktree_branch)

    if [[ -n "$detected_branch" ]]; then
        # In a worktree: positionals = target command...
        branch="$detected_branch"
        if [[ ${#positionals[@]} -lt 2 ]]; then
            log_error "Usage: wt send <service|pane_index> <command...>"
            show_send_help
            return 1
        fi
        target="${positionals[0]}"
        cmd_parts=("${positionals[@]:1}")
    else
        # Not in a worktree: positionals = branch target command...
        if [[ ${#positionals[@]} -lt 3 ]]; then
            log_error "Usage: wt send <branch> <service|pane_index> <command...>"
            show_send_help
            return 1
        fi
        branch="${positionals[0]}"
        target="${positionals[1]}"
        cmd_parts=("${positionals[@]:2}")
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    # Resolve pane index: numeric = direct pane index, string = service name lookup
    local pane_idx
    if [[ "$target" =~ ^[0-9]+$ ]]; then
        pane_idx="$target"
    else
        pane_idx=$(find_service_pane_index "$PROJECT_CONFIG_FILE" "$target")
        if [[ -z "$pane_idx" ]]; then
            die "Service not found in pane config: $target"
        fi
    fi

    # Get tmux session and window
    local tmux_session
    tmux_session=$(get_tmux_session_name "$PROJECT_CONFIG_FILE")
    local window_name
    window_name=$(get_session_name "$project" "$branch")

    # Verify session and window exist
    if ! session_exists "$tmux_session"; then
        die "Tmux session does not exist: $tmux_session"
    fi
    if ! window_exists "$tmux_session" "$window_name"; then
        die "Tmux window does not exist: $window_name"
    fi

    # Join command parts and send
    local full_cmd="${cmd_parts[*]}"
    send_to_pane "$tmux_session" "$window_name" "$pane_idx" "$full_cmd"

    log_success "Sent to ${target} (pane $pane_idx): $full_cmd"
}

show_send_help() {
    cat << 'EOF'
Usage: wt send [branch] <service|pane_index> <command...>
       wt send <service|pane_index> <command...>  (inside worktree)

Send a command to a specific tmux pane in a worktree window.

Arguments:
  <branch>          Branch name (auto-detected inside worktree)
  <service>         Service name to target (resolved to pane index)
  <pane_index>      Numeric pane index to target directly
  <command...>      Command string to send

Options:
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt send feature/auth api-server "echo hello"
  wt send api-server "npm restart"          # Inside worktree
  wt send feature/auth 0 "ls -la"           # By pane index
EOF
}
