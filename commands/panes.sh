#!/bin/bash
# commands/panes.sh - List panes for a worktree window

cmd_panes() {
    local branch=""
    local project=""
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
                show_panes_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_panes_help
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
        branch="$detected_branch"
    elif [[ ${#positionals[@]} -gt 0 ]]; then
        branch="${positionals[0]}"
    else
        log_error "Branch name is required (not in a worktree)"
        show_panes_help
        return 1
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    # Get tmux session and window
    local tmux_session
    tmux_session=$(get_tmux_session_name "$PROJECT_CONFIG_FILE")
    local window_name
    window_name=$(get_session_name "$project" "$branch")

    if ! session_exists "$tmux_session"; then
        die "Tmux session does not exist: $tmux_session"
    fi
    if ! window_exists "$tmux_session" "$window_name"; then
        die "Tmux window does not exist: $window_name"
    fi

    echo ""
    echo -e "${BOLD}Panes for: ${CYAN}$branch${NC}"
    echo "$(printf '%.0s-' {1..60})"
    echo ""

    # Print table header
    printf "${BOLD}%-6s %-20s %-8s %-15s${NC}\n" "PANE" "SERVICE/COMMAND" "ACTIVE" "SIZE"
    printf "%s\n" "$(printf '%.0s-' {1..55})"

    # Get pane info from tmux
    local pane_info
    pane_info=$(list_window_panes "$tmux_session" "$window_name")

    # Get pane count from config for cross-referencing
    local config_pane_count
    config_pane_count=$(yaml_array_length "$PROJECT_CONFIG_FILE" ".tmux.windows[0].panes")

    while IFS=: read -r idx active cmd size; do
        [[ -z "$idx" ]] && continue

        # Try to resolve service name from config
        local label="$cmd"
        if (( idx < config_pane_count )); then
            local pane_service
            pane_service=$(yq -r ".tmux.windows[0].panes[$idx].service // \"\"" "$PROJECT_CONFIG_FILE" 2>/dev/null)
            if [[ -n "$pane_service" ]] && [[ "$pane_service" != "null" ]]; then
                label="$pane_service"
            else
                local pane_cmd
                pane_cmd=$(yq -r ".tmux.windows[0].panes[$idx].command // .tmux.windows[0].panes[$idx] // \"\"" "$PROJECT_CONFIG_FILE" 2>/dev/null)
                if [[ -n "$pane_cmd" ]] && [[ "$pane_cmd" != "null" ]]; then
                    label=$(truncate "$pane_cmd" 18)
                fi
            fi
        fi

        local active_str="no"
        if [[ "$active" == "1" ]]; then
            active_str="${GREEN}yes${NC}"
        fi

        printf "%-6s %-20s " "$idx" "$label"
        printf "%-8b " "$active_str"
        printf "%-15s\n" "$size"
    done <<< "$pane_info"

    echo ""
}

show_panes_help() {
    cat << 'EOF'
Usage: wt panes [branch] [options]
       wt panes [options]  (inside worktree)

List tmux panes for a worktree window with service/command info.

Arguments:
  <branch>          Branch name (auto-detected inside worktree)

Options:
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt panes feature/auth
  wt panes                    # Inside worktree
  wt panes -p myproject
EOF
}
