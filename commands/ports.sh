#!/bin/bash
# commands/ports.sh - Show port assignments for a worktree

cmd_ports() {
    local branch=""
    local project=""
    local check_availability=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--check)
                check_availability=1
                shift
                ;;
            -p|--project)
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

    # Detect or validate project
    if [[ -z "$project" ]]; then
        project=$(detect_project)
        if [[ -z "$project" ]]; then
            die "Could not detect project. Use --project option."
        fi
    fi

    # Load project configuration
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

    # Reserved ports section
    local reserved_min
    reserved_min=$(yaml_get "$PROJECT_CONFIG_FILE" ".ports.reserved.range.min" "3000")

    local reserved_services
    reserved_services=$(yq -r '.ports.reserved.services // {} | to_entries | .[] | "\(.key):\(.value)"' "$PROJECT_CONFIG_FILE" 2>/dev/null)

    if [[ -n "$reserved_services" ]]; then
        echo -e "${BOLD}Reserved Ports (Slot $slot)${NC}"
        printf "%-25s %-8s" "SERVICE" "PORT"
        [[ "$check_availability" -eq 1 ]] && printf " %-12s" "STATUS"
        echo ""
        printf "%s\n" "$(printf '%.0s-' {1..50})"

        while IFS=: read -r service offset; do
            [[ -z "$service" ]] && continue
            local port
            port=$(calculate_reserved_port "$slot" "$offset" "$reserved_min")

            printf "%-25s %-8s" "$service" "$port"

            if [[ "$check_availability" -eq 1 ]]; then
                if port_in_use "$port"; then
                    printf " ${RED}in use${NC}"
                else
                    printf " ${GREEN}available${NC}"
                fi
            fi
            echo ""
        done <<< "$reserved_services"
        echo ""
    fi

    # Dynamic ports section
    local dynamic_services
    dynamic_services=$(yq -r '.ports.dynamic.services // {} | keys | .[]' "$PROJECT_CONFIG_FILE" 2>/dev/null)

    if [[ -n "$dynamic_services" ]]; then
        echo -e "${BOLD}Dynamic Ports${NC}"
        printf "%-25s %-8s" "SERVICE" "PORT"
        [[ "$check_availability" -eq 1 ]] && printf " %-12s" "STATUS"
        echo ""
        printf "%s\n" "$(printf '%.0s-' {1..50})"

        local dynamic_min
        dynamic_min=$(yaml_get "$PROJECT_CONFIG_FILE" ".ports.dynamic.range.min" "4000")

        local dynamic_max
        dynamic_max=$(yaml_get "$PROJECT_CONFIG_FILE" ".ports.dynamic.range.max" "5000")

        while read -r service; do
            [[ -z "$service" ]] && continue
            local port
            port=$(calculate_dynamic_port "$branch" "$dynamic_min" "$dynamic_max")

            printf "%-25s %-8s" "$service" "$port"

            if [[ "$check_availability" -eq 1 ]]; then
                if port_in_use "$port"; then
                    printf " ${RED}in use${NC}"
                else
                    printf " ${GREEN}available${NC}"
                fi
            fi
            echo ""
        done <<< "$dynamic_services"
        echo ""
    fi

    # Environment variables
    echo -e "${BOLD}Environment Variables${NC}"
    printf "%s\n" "$(printf '%.0s-' {1..50})"

    while IFS=: read -r service port; do
        [[ -z "$service" ]] && continue
        local var_name
        var_name="PORT_$(echo "$service" | tr '[:lower:]-' '[:upper:]_')"
        echo "export $var_name=$port"
    done < <(calculate_worktree_ports "$branch" "$PROJECT_CONFIG_FILE" "$slot")

    echo ""
}

show_ports_help() {
    cat << 'EOF'
Usage: wt ports <branch> [options]

Show port assignments for a worktree.

Arguments:
  <branch>          Branch name of the worktree

Options:
  -c, --check       Check if ports are currently in use
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt ports feature/auth
  wt ports feature/auth --check
EOF
}
