#!/bin/bash
# commands/stop.sh - Stop services in a worktree

cmd_stop() {
    local branch=""
    local service=""
    local all=0
    local project=""
    local positional=""

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
                show_stop_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_stop_help
                return 1
                ;;
            *)
                # Collect positional argument
                if [[ -z "$positional" ]]; then
                    positional="$1"
                fi
                shift
                ;;
        esac
    done

    # Try to detect branch from current directory
    local detected_branch
    detected_branch=$(detect_worktree_branch)

    # Interpret positional argument based on context
    if [[ -n "$detected_branch" ]]; then
        # We're in a worktree - positional arg is the service name
        branch="$detected_branch"
        if [[ -n "$positional" ]] && [[ -z "$service" ]]; then
            service="$positional"
        fi
        log_debug "In worktree, detected branch: $branch"
    else
        # Not in a worktree - positional arg is the branch name
        branch="$positional"
        if [[ -z "$branch" ]]; then
            log_error "Branch name is required (not in a worktree)"
            show_stop_help
            return 1
        fi
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

    # Stop services
    if [[ "$all" -eq 1 ]]; then
        stop_all_services "$project" "$branch" "$PROJECT_CONFIG_FILE"
    elif [[ -n "$service" ]]; then
        stop_service "$project" "$branch" "$service" "$PROJECT_CONFIG_FILE"
    else
        log_error "Specify a service name, --all, or --service <name>"
        show_stop_help
        return 1
    fi
}

show_stop_help() {
    cat << 'EOF'
Usage: wt stop [service] [options]
       wt stop <branch> --service <name> [options]
       wt stop <branch> --all [options]

Stop services in a worktree.

When run inside a worktree, the branch is auto-detected and the first
argument is treated as the service name.

Arguments:
  <service>         Service name (when inside a worktree)
  <branch>          Branch name (when outside a worktree)

Options:
  -s, --service     Stop a specific service
  -a, --all         Stop all services
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt stop api-server               # Inside worktree: stop specific service
  wt stop --all                    # Inside worktree: stop all services
  wt stop feature/auth --all       # Outside worktree: specify branch
  wt stop feature/auth --service api-server
EOF
}
