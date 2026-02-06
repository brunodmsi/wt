#!/bin/bash
# commands/start.sh - Start services in a worktree

cmd_start() {
    local branch=""
    local service=""
    local all=0
    local attach=0
    local project=""
    local -a positionals=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--service)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires an argument"
                    return 1
                fi
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
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires an argument"
                    return 1
                fi
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
                # Collect positional arguments
                positionals+=("$1")
                shift
                ;;
        esac
    done

    # Try to detect branch from current directory
    local detected_branch
    detected_branch=$(detect_worktree_branch)

    # Interpret positional arguments based on context
    local -a services=()
    if [[ -n "$detected_branch" ]]; then
        # We're in a worktree - positional args are service names
        branch="$detected_branch"
        if [[ ${#positionals[@]} -gt 0 ]] && [[ -z "$service" ]]; then
            services=("${positionals[@]}")
        elif [[ -n "$service" ]]; then
            services=("$service")
        fi
        log_debug "In worktree, detected branch: $branch"
    else
        # Not in a worktree - first positional is branch, rest could be services
        if [[ ${#positionals[@]} -gt 0 ]]; then
            branch="${positionals[0]}"
            # If there are more positionals, they're service names
            if [[ ${#positionals[@]} -gt 1 ]]; then
                services=("${positionals[@]:1}")
            elif [[ -n "$service" ]]; then
                services=("$service")
            fi
        fi
        if [[ -z "$branch" ]]; then
            log_error "Branch name is required (not in a worktree)"
            show_start_help
            return 1
        fi
    fi

    project=$(require_project "$project")
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
    local failed=0
    if [[ "$all" -eq 1 ]]; then
        start_all_services "$project" "$branch" "$PROJECT_CONFIG_FILE"
    elif [[ ${#services[@]} -gt 0 ]]; then
        # Start multiple services sequentially
        for svc in "${services[@]}"; do
            if ! start_service "$project" "$branch" "$svc" "$PROJECT_CONFIG_FILE"; then
                ((failed++))
            fi
            # Small delay between service starts if more than one
            if [[ ${#services[@]} -gt 1 ]]; then
                sleep 1
            fi
        done
        if [[ "$failed" -gt 0 ]]; then
            log_warn "$failed service(s) failed to start"
        fi
    else
        log_error "Specify service name(s), --all, or --service <name>"
        show_start_help
        return 1
    fi

    # Run post_start hook if defined
    local post_start
    post_start=$(yaml_get "$PROJECT_CONFIG_FILE" ".hooks.post_start" "")
    if [[ -n "$post_start" ]] && [[ "$post_start" != "null" ]]; then
        export BRANCH_NAME="$branch"
        if ! eval "$post_start"; then
            log_warn "post_start hook exited with errors"
        fi
    fi

    # Optionally attach
    if [[ "$attach" -eq 1 ]]; then
        echo ""
        attach_session "$session"
    fi
}

show_start_help() {
    cat << 'EOF'
Usage: wt start [service...] [options]
       wt start <branch> [service...] [options]
       wt start --all [options]

Start services in a worktree.

When run inside a worktree, the branch is auto-detected and positional
arguments are treated as service names. Multiple services can be
specified and will be started sequentially.

Arguments:
  <service...>      One or more service names
  <branch>          Branch name (required when outside a worktree)

Options:
  -s, --service     Start a specific service (alternative syntax)
  -a, --all         Start all configured services
  --attach          Attach to tmux session after starting
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt start api-server              # Start one service
  wt start api-server indexer      # Start multiple services sequentially
  wt start --all                   # Start all services
  wt start feature/auth --all      # Outside worktree: specify branch
EOF
}
