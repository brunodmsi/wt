#!/bin/bash
# commands/restart.sh - Restart services in a worktree

cmd_restart() {
    local branch=""
    local service=""
    local all=0
    local project=""
    local -a positionals=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--service)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                service="$2"
                shift 2
                ;;
            -a|--all)
                all=1
                shift
                ;;
            -p|--project)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_restart_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_restart_help
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

    local -a services=()
    if [[ -n "$detected_branch" ]]; then
        branch="$detected_branch"
        if [[ ${#positionals[@]} -gt 0 ]] && [[ -z "$service" ]]; then
            services=("${positionals[@]}")
        elif [[ -n "$service" ]]; then
            services=("$service")
        fi
    else
        if [[ ${#positionals[@]} -gt 0 ]]; then
            branch="${positionals[0]}"
            if [[ ${#positionals[@]} -gt 1 ]]; then
                services=("${positionals[@]:1}")
            elif [[ -n "$service" ]]; then
                services=("$service")
            fi
        fi
        if [[ -z "$branch" ]]; then
            log_error "Branch name is required (not in a worktree)"
            show_restart_help
            return 1
        fi
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    if ! worktree_exists "$branch" "$PROJECT_REPO_PATH"; then
        die "Worktree not found for branch: $branch"
    fi

    local slot
    slot=$(get_worktree_slot "$project" "$branch")
    [[ -z "$slot" ]] && die "Could not find slot for worktree. State may be corrupted."

    export_port_vars "$branch" "$PROJECT_CONFIG_FILE" "$slot"
    export_env_vars "$PROJECT_CONFIG_FILE"
    export BRANCH_NAME="$branch"
    export WORKTREE_PATH="$(get_worktree_path "$project" "$branch")"

    # Resolve the list of services to restart
    local -a target_services=()
    if [[ "$all" -eq 1 ]]; then
        while read -r name; do
            [[ -z "$name" ]] && continue
            target_services+=("$name")
        done < <(yq -r '.services[].name' "$PROJECT_CONFIG_FILE" 2>/dev/null)
    elif [[ ${#services[@]} -gt 0 ]]; then
        target_services=("${services[@]}")
    else
        log_error "Specify service name(s), --all, or --service <name>"
        show_restart_help
        return 1
    fi

    local failed=0

    for svc in "${target_services[@]}"; do
        log_info "Restarting $svc..."

        # Stop: kill existing process cleanly
        stop_service "$project" "$branch" "$svc" "$PROJECT_CONFIG_FILE"

        # Start: fresh launch
        if ! start_service "$project" "$branch" "$svc" "$PROJECT_CONFIG_FILE"; then
            ((failed++)) || true
        fi
    done

    if [[ "$failed" -gt 0 ]]; then
        log_warn "$failed service(s) failed to restart"
        return 1
    fi

    log_success "Restarted ${#target_services[@]} service(s)"
}

show_restart_help() {
    cat << 'EOF'
Usage: wt restart [service...] [options]
       wt restart <branch> [service...] [options]
       wt restart --all [options]

Restart services in a worktree. Stops each service cleanly then starts
it again with a fresh log file.

Arguments:
  <service...>      One or more service names
  <branch>          Branch name (required when outside a worktree)

Options:
  -s, --service     Restart a specific service (alternative syntax)
  -a, --all         Restart all configured services
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt restart api-server            # Restart one service
  wt restart api-server indexer    # Restart multiple services
  wt restart --all                 # Restart all services
  wt restart feature/auth --all    # Outside worktree: specify branch
EOF
}
