#!/bin/bash
# commands/logs.sh - Capture tmux pane output

cmd_logs() {
    local branch=""
    local project=""
    local lines=50
    local show_all=0
    local target=""
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
            --lines|-n)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires an argument"
                    return 1
                fi
                lines="$2"
                shift 2
                ;;
            --all|-a)
                show_all=1
                shift
                ;;
            -h|--help)
                show_logs_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_logs_help
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
        # In a worktree: positional is service/pane
        branch="$detected_branch"
        if [[ ${#positionals[@]} -gt 0 ]]; then
            target="${positionals[0]}"
        fi
    else
        # Not in a worktree: first positional is branch, second is service/pane
        if [[ ${#positionals[@]} -gt 0 ]]; then
            branch="${positionals[0]}"
        fi
        if [[ ${#positionals[@]} -gt 1 ]]; then
            target="${positionals[1]}"
        fi
    fi

    if [[ -z "$branch" ]]; then
        log_error "Branch name is required (not in a worktree)"
        show_logs_help
        return 1
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    # Under herdr/none we can't capture tmux panes — read the on-disk log
    # files written by start_service instead.
    local _logs_mux
    _logs_mux=$(detect_multiplexer)
    if [[ "$_logs_mux" != "tmux" ]] && [[ "$_logs_mux" != "dmux" ]]; then
        _logs_from_files "$project" "$branch" "$target" "$lines" "$show_all" "$_logs_mux"
        return $?
    fi

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

    if [[ "$show_all" -eq 1 ]]; then
        # Show all panes
        local pane_info
        pane_info=$(list_window_panes "$tmux_session" "$window_name")

        while IFS=: read -r idx _ _ _; do
            [[ -z "$idx" ]] && continue

            # Try to resolve pane name from config
            local pane_label="pane $idx"
            local pane_service
            pane_service=$(yq -r ".tmux.windows[0].panes[$idx].service // \"\"" "$PROJECT_CONFIG_FILE" 2>/dev/null)
            if [[ -n "$pane_service" ]] && [[ "$pane_service" != "null" ]]; then
                pane_label="$pane_service"
            fi

            echo -e "${BOLD}=== $pane_label (pane $idx) ===${NC}"
            capture_pane "$tmux_session" "$window_name" "$idx" "$lines"
            echo ""
        done <<< "$pane_info"
    elif [[ -n "$target" ]]; then
        # Resolve target to pane index
        local pane_idx
        if [[ "$target" =~ ^[0-9]+$ ]]; then
            pane_idx="$target"
        else
            pane_idx=$(find_service_pane_index "$PROJECT_CONFIG_FILE" "$target")
            if [[ -z "$pane_idx" ]]; then
                die "Service not found in pane config: $target"
            fi
        fi

        capture_pane "$tmux_session" "$window_name" "$pane_idx" "$lines"
    else
        # Default: show pane 0
        capture_pane "$tmux_session" "$window_name" "0" "$lines"
    fi
}

# Read service logs from on-disk files (used when tmux isn't the active mux).
# Args: project branch target lines show_all mux_name
_logs_from_files() {
    local project="$1"
    local branch="$2"
    local target="$3"
    local lines="$4"
    local show_all="$5"
    local mux_name="${6:-none}"

    if [[ "$show_all" -eq 1 ]] || [[ -z "$target" ]]; then
        # Iterate every configured service and show its log file.
        local svc_names
        svc_names=$(yq -r '.services[]?.name // ""' "$PROJECT_CONFIG_FILE" 2>/dev/null)
        if [[ -z "$svc_names" ]]; then
            die "No services configured for $project"
        fi
        while IFS= read -r svc; do
            [[ -z "$svc" ]] && continue
            local log_file
            log_file=$(get_service_log_path "$project" "$branch" "$svc")
            echo -e "${BOLD}=== $svc ===${NC}"
            if [[ -f "$log_file" ]]; then
                tail -n "$lines" "$log_file"
            else
                echo "(no log file yet: $log_file)"
            fi
            echo ""
        done <<< "$svc_names"
        return 0
    fi

    # Target is required to be a service name in non-tmux mode (pane index
    # makes no sense without panes).
    if [[ "$target" =~ ^[0-9]+$ ]]; then
        die "Numeric pane targets are not supported under '$mux_name' multiplexer. Pass a service name."
    fi

    local log_file
    log_file=$(get_service_log_path "$project" "$branch" "$target")
    if [[ ! -f "$log_file" ]]; then
        die "No log file for service '$target' at: $log_file"
    fi
    tail -n "$lines" "$log_file"
}

show_logs_help() {
    cat << 'EOF'
Usage: wt logs [branch] [service|pane_index] [options]
       wt logs [service|pane_index] [options]  (inside worktree)

Display log output for a worktree's services. Under tmux/dmux this
captures the pane output directly; under herdr/none it tails the
on-disk log files written by 'wt start'.

Arguments:
  <branch>          Branch name (auto-detected inside worktree)
  <service>         Service name (or pane index — tmux/dmux only)

Options:
  --lines, -n N     Number of lines to capture (default: 50)
  --all, -a         Show output from all services/panes
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt logs feature/auth api-server
  wt logs feature/auth --all
  wt logs api-server --lines 100          # Inside worktree
  wt logs feature/auth 0 -n 20           # By pane index
EOF
}
