#!/bin/bash
# commands/ports.sh - Show and manage port assignments for worktrees

# Print port table header
# Usage: _ports_table_header <title> <check_availability>
_ports_table_header() {
    local title="$1"
    local check_availability="$2"

    echo -e "${BOLD}${title}${NC}"
    printf "%-25s %-8s %-10s" "SERVICE" "PORT" "OVERRIDE"
    [[ "$check_availability" -eq 1 ]] && printf " %-12s" "STATUS"
    echo ""
    printf "%s\n" "$(printf '%.0s-' {1..60})"
}

# Print a single port row with override and availability info
# Usage: _ports_table_row <service> <port> <project> <branch> <check_availability>
_ports_table_row() {
    local service="$1"
    local port="$2"
    local project="$3"
    local branch="$4"
    local check_availability="$5"

    local override
    override=$(get_port_override "$project" "$branch" "$service")
    local effective_port="$port"

    printf "%-25s %-8s" "$service" "$port"

    if [[ -n "$override" ]]; then
        printf " ${CYAN}%-10s${NC}" "$override"
        effective_port="$override"
    else
        printf " %-10s" "-"
    fi

    if [[ "$check_availability" -eq 1 ]]; then
        if port_in_use "$effective_port"; then
            printf " ${RED}in use${NC}"
        else
            printf " ${GREEN}available${NC}"
        fi
    fi
    echo ""
}

cmd_ports() {
    local subcommand=""
    local branch=""
    local project=""
    local check_availability=0

    # Check for subcommand
    if [[ $# -gt 0 ]] && [[ "$1" != -* ]]; then
        case "$1" in
            set|clear)
                subcommand="$1"
                shift
                ;;
        esac
    fi

    # Route to subcommand handlers
    case "$subcommand" in
        set)
            cmd_ports_set "$@"
            return $?
            ;;
        clear)
            cmd_ports_clear "$@"
            return $?
            ;;
    esac

    # Parse arguments for show (default)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--check)
                check_availability=1
                shift
                ;;
            -p|--project)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_ports_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_ports_help
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
        show_ports_help
        return 1
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    # Get slot
    local slot
    slot=$(get_slot_for_worktree "$project" "$branch")

    if [[ -z "$slot" ]]; then
        # Calculate what slot would be assigned (for preview)
        log_info "Worktree not created yet, showing projected ports..."
        slot=0
    fi

    echo ""
    echo -e "${BOLD}Port Assignments for: ${CYAN}$branch${NC}"
    echo "$(printf '%.0s-' {1..50})"
    echo ""

    print_kv "Project" "$project"
    print_kv "Slot" "$slot"
    echo ""

    # Check for any port overrides
    local overrides
    overrides=$(list_port_overrides "$project" "$branch" 2>/dev/null)

    # Reserved ports section
    local reserved_min
    reserved_min=$(yaml_get "$PROJECT_CONFIG_FILE" ".ports.reserved.range.min" "3000")

    local reserved_services
    reserved_services=$(yq -r '.ports.reserved.services // {} | to_entries | .[] | "\(.key):\(.value)"' "$PROJECT_CONFIG_FILE" 2>/dev/null)

    if [[ -n "$reserved_services" ]]; then
        _ports_table_header "Reserved Ports (Slot $slot)" "$check_availability"

        while IFS=: read -r service offset; do
            [[ -z "$service" ]] && continue
            local port
            port=$(calculate_reserved_port "$slot" "$offset" "$reserved_min")
            _ports_table_row "$service" "$port" "$project" "$branch" "$check_availability"
        done <<< "$reserved_services"
        echo ""
    fi

    # Dynamic ports section
    local dynamic_services
    dynamic_services=$(yq -r '.ports.dynamic.services // {} | keys | .[]' "$PROJECT_CONFIG_FILE" 2>/dev/null)

    if [[ -n "$dynamic_services" ]]; then
        _ports_table_header "Dynamic Ports" "$check_availability"

        local dynamic_min
        dynamic_min=$(yaml_get "$PROJECT_CONFIG_FILE" ".ports.dynamic.range.min" "4000")

        local dynamic_max
        dynamic_max=$(yaml_get "$PROJECT_CONFIG_FILE" ".ports.dynamic.range.max" "5000")

        while read -r service; do
            [[ -z "$service" ]] && continue
            local port
            port=$(calculate_dynamic_port "$branch" "$dynamic_min" "$dynamic_max")
            _ports_table_row "$service" "$port" "$project" "$branch" "$check_availability"
        done <<< "$dynamic_services"
        echo ""
    fi

    # Environment variables (with overrides applied)
    echo -e "${BOLD}Environment Variables (effective)${NC}"
    printf "%s\n" "$(printf '%.0s-' {1..60})"

    while IFS=: read -r service port; do
        [[ -z "$service" ]] && continue
        local var_name
        var_name="PORT_$(echo "$service" | tr '[:lower:]-' '[:upper:]_')"

        # Check for override
        local override
        override=$(get_port_override "$project" "$branch" "$service")
        local effective_port="${override:-$port}"

        echo "export $var_name=$effective_port"
    done < <(calculate_worktree_ports "$branch" "$PROJECT_CONFIG_FILE" "$slot")

    echo ""
}

show_ports_help() {
    cat << 'EOF'
Usage: wt ports <branch> [options]
       wt ports set <service> <port> [branch] [options]
       wt ports clear <service> [branch] [options]

Show and manage port assignments for worktrees.

Subcommands:
  set <service> <port>   Override port for a service in a worktree
  clear <service>        Remove port override for a service

Arguments:
  <branch>          Branch name of the worktree

Options:
  -c, --check       Check if ports are currently in use
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt ports feature/auth
  wt ports feature/auth --check
  wt ports set api-server 4500 feature/auth
  wt ports clear api-server feature/auth
EOF
}

# Set port override for a service
cmd_ports_set() {
    local service=""
    local port=""
    local branch=""
    local project=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_ports_set_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_ports_set_help
                return 1
                ;;
            *)
                if [[ -z "$service" ]]; then
                    service="$1"
                elif [[ -z "$port" ]]; then
                    port="$1"
                elif [[ -z "$branch" ]]; then
                    branch="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$service" ]] || [[ -z "$port" ]]; then
        log_error "Service name and port are required"
        show_ports_set_help
        return 1
    fi

    # Validate port is a number
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        log_error "Port must be a number"
        return 1
    fi

    project=$(require_project "$project")

    # Auto-detect branch from current git branch if not specified
    if [[ -z "$branch" ]]; then
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [[ -z "$branch" ]]; then
            log_error "Branch name is required (could not auto-detect)"
            show_ports_set_help
            return 1
        fi
        log_info "Using current branch: $branch"
    fi

    # Check if worktree exists
    local worktree_path
    worktree_path=$(get_worktree_path "$project" "$branch")
    if [[ -z "$worktree_path" ]]; then
        log_error "Worktree not found for branch: $branch"
        return 1
    fi

    # Warn if port is currently in use
    if ! is_port_available "$port"; then
        log_warn "Port $port is currently in use. Override will be set, but the service may fail to start until the port is freed."
    fi

    # Set the override
    set_port_override "$project" "$branch" "$service" "$port"
    log_success "Port override set: $service -> $port (branch: $branch)"

    # Show note about restarting
    echo ""
    log_info "Restart the service to apply: wt stop $service && wt start $service"
}

show_ports_set_help() {
    cat << 'EOF'
Usage: wt ports set <service> <port> [branch] [options]

Set a port override for a service in a worktree.

Arguments:
  <service>         Service name (e.g., api-server, frontend)
  <port>            Port number to use
  <branch>          Branch name (defaults to current branch)

Options:
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt ports set api-server 4500
  wt ports set api-server 4500 feature/auth
  wt ports set frontend 3100 --project myproject
EOF
}

# Clear port override for a service
cmd_ports_clear() {
    local service=""
    local branch=""
    local project=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_ports_clear_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_ports_clear_help
                return 1
                ;;
            *)
                if [[ -z "$service" ]]; then
                    service="$1"
                elif [[ -z "$branch" ]]; then
                    branch="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$service" ]]; then
        log_error "Service name is required"
        show_ports_clear_help
        return 1
    fi

    project=$(require_project "$project")

    # Auto-detect branch from current git branch if not specified
    if [[ -z "$branch" ]]; then
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [[ -z "$branch" ]]; then
            log_error "Branch name is required (could not auto-detect)"
            show_ports_clear_help
            return 1
        fi
        log_info "Using current branch: $branch"
    fi

    # Clear the override
    clear_port_override "$project" "$branch" "$service"
    log_success "Port override cleared: $service (branch: $branch)"

    # Show note about restarting
    echo ""
    log_info "Restart the service to use default port: wt stop $service && wt start $service"
}

show_ports_clear_help() {
    cat << 'EOF'
Usage: wt ports clear <service> [branch] [options]

Remove a port override for a service in a worktree.

Arguments:
  <service>         Service name (e.g., api-server, frontend)
  <branch>          Branch name (defaults to current branch)

Options:
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt ports clear api-server
  wt ports clear api-server feature/auth
EOF
}
