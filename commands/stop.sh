#!/bin/bash
# commands/stop.sh - Stop services in a worktree

cmd_stop() {
    local branch=""
    local service=""
    local all=0
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
            -p|--project)
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
                if [[ -z "$branch" ]]; then
                    branch="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$branch" ]]; then
        log_error "Branch name is required"
        show_stop_help
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

    # Stop services
    if [[ "$all" -eq 1 ]]; then
        stop_all_services "$project" "$branch" "$PROJECT_CONFIG_FILE"
    elif [[ -n "$service" ]]; then
        stop_service "$project" "$branch" "$service" "$PROJECT_CONFIG_FILE"
    else
        log_error "Specify --all or --service <name>"
        show_stop_help
        return 1
    fi
}

show_stop_help() {
    cat << 'EOF'
Usage: wt stop <branch> [options]

Stop services in a worktree.

Arguments:
  <branch>          Branch name of the worktree

Options:
  -s, --service     Stop a specific service
  -a, --all         Stop all services
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt stop feature/auth --all
  wt stop feature/auth --service gap-app-v2
EOF
}
