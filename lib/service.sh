#!/bin/bash
# lib/service.sh - Service lifecycle management

# Find the pane index for a service in the config
find_service_pane_index() {
    local config_file="$1"
    local service_name="$2"

    local pane_count
    pane_count=$(yaml_array_length "$config_file" ".tmux.windows[0].panes")

    log_debug "find_service_pane_index: service=$service_name pane_count=$pane_count"

    for ((p = 0; p < pane_count; p++)); do
        local pane_service
        pane_service=$(yq -r ".tmux.windows[0].panes[$p].service // \"\"" "$config_file" 2>/dev/null)

        if [[ "$pane_service" == "$service_name" ]]; then
            # Config index matches tmux pane index directly
            # Layout: panes 0,1,2 = top row services, pane 3 = bottom (claude)
            log_debug "find_service_pane_index: found $service_name at pane $p"
            echo "$p"
            return 0
        fi
    done

    echo ""
    return 1
}

# Start a service
start_service() {
    local project="$1"
    local branch="$2"
    local service_name="$3"
    local config_file="$4"

    local worktree_path
    worktree_path=$(get_worktree_path "$project" "$branch")

    if [[ -z "$worktree_path" ]] || [[ ! -d "$worktree_path" ]]; then
        log_error "Worktree not found for branch: $branch"
        return 1
    fi

    # Get service configuration
    local svc_dir
    svc_dir=$(get_service_config "$config_file" "$service_name" "working_dir")

    local svc_cmd
    svc_cmd=$(get_service_config "$config_file" "$service_name" "command")

    local port_key
    port_key=$(get_service_config "$config_file" "$service_name" "port_key")

    if [[ -z "$svc_cmd" ]] || [[ "$svc_cmd" == "null" ]]; then
        log_error "Service not found or has no command: $service_name"
        return 1
    fi

    # Get port for this service
    local slot
    slot=$(get_worktree_slot "$project" "$branch")

    if [[ -z "$slot" ]]; then
        log_error "Could not find slot for worktree '$branch'. State may be corrupted."
        log_error "Try: wt delete $branch && wt create $branch"
        return 1
    fi

    log_debug "Getting port for service=$service_name port_key=$port_key branch=$branch slot=$slot"

    local port
    port=$(get_service_port "$port_key" "$branch" "$config_file" "$slot")

    log_debug "Got port=$port for $service_name"

    if [[ -z "$port" ]]; then
        log_error "Could not determine port for service: $service_name"
        log_error "  port_key=$port_key, slot=$slot, config=$config_file"
        # Debug: show what calculate_worktree_ports returns
        log_error "  Available ports: $(calculate_worktree_ports "$branch" "$config_file" "$slot" | tr '\n' ' ')"
        return 1
    fi

    # Check if already running
    if is_service_running "$project" "$branch" "$service_name"; then
        log_warn "Service already running: $service_name"
        return 0
    fi

    # Export port variables
    export PORT="$port"
    export_port_vars "$branch" "$config_file" "$slot"

    # Get service environment
    local svc_env
    svc_env=$(yq -r ".services[] | select(.name == \"$service_name\") | .env // {} | to_entries | .[] | \"\(.key)=\(.value)\"" "$config_file" 2>/dev/null)

    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        value=$(eval echo "$value" 2>/dev/null || echo "$value")
        export "$key=$value"
    done <<< "$svc_env"

    # Build exec_dir early so pre_start can use it
    local exec_dir="$worktree_path/$svc_dir"

    # Run pre_start commands in the service's working directory
    local pre_start
    pre_start=$(yq -r ".services[] | select(.name == \"$service_name\") | .pre_start // [] | .[]" "$config_file" 2>/dev/null)

    if [[ -n "$pre_start" ]]; then
        pushd "$exec_dir" > /dev/null 2>&1 || true
        while read -r cmd; do
            [[ -z "$cmd" ]] && continue
            log_debug "Pre-start ($svc_dir): $cmd"
            eval "$cmd" 2>/dev/null || true
        done <<< "$pre_start"
        popd > /dev/null 2>&1 || true
    fi

    # Get tmux session and window
    local tmux_session
    tmux_session=$(get_tmux_session_name "$config_file")
    local window_name
    window_name=$(get_session_name "$project" "$branch")

    log_info "Starting $service_name on port $port..."

    # Find pane for this service within the worktree window
    local pane_idx
    pane_idx=$(find_service_pane_index "$config_file" "$service_name")

    if [[ -n "$pane_idx" ]]; then
        # Send command to the service pane
        tmux send-keys -t "${tmux_session}:${window_name}.${pane_idx}" "cd '$exec_dir' && PORT=$port $svc_cmd" Enter
    else
        # No pane configured, create a new window for the service
        tmux new-window -t "$tmux_session" -n "${window_name}-${service_name}" -c "$exec_dir"
        tmux send-keys -t "${tmux_session}:${window_name}-${service_name}" "PORT=$port $svc_cmd" Enter
    fi

    # Update state (we don't have PID directly since it's in tmux)
    update_service_status "$project" "$branch" "$service_name" "running" "" "$port"

    # Run health check if configured
    local health_type
    health_type=$(yq -r ".services[] | select(.name == \"$service_name\") | .health_check.type // \"\"" "$config_file" 2>/dev/null)

    if [[ -n "$health_type" ]] && [[ "$health_type" != "null" ]]; then
        run_health_check "$service_name" "$port" "$config_file"
    fi

    log_success "Started: $service_name (port $port)"
    return 0
}

# Stop a service
stop_service() {
    local project="$1"
    local branch="$2"
    local service_name="$3"
    local config_file="$4"

    log_info "Stopping $service_name..."

    # Get tmux session and window names
    local tmux_session
    tmux_session=$(get_tmux_session_name "$config_file")
    local window_name
    window_name=$(get_session_name "$project" "$branch")

    # Find pane for this service within the worktree window
    local pane_idx
    pane_idx=$(find_service_pane_index "$config_file" "$service_name")

    if [[ -n "$pane_idx" ]]; then
        # Interrupt the service pane
        interrupt_pane "$tmux_session" "${window_name}.${pane_idx}"
    else
        # Try service-named window (fallback for services started without pane config)
        if tmux list-windows -t "$tmux_session" -F "#{window_name}" 2>/dev/null | grep -q "^${window_name}-${service_name}$"; then
            interrupt_pane "$tmux_session" "${window_name}-${service_name}"
        fi
    fi

    # Update state
    update_service_status "$project" "$branch" "$service_name" "stopped"

    log_success "Stopped: $service_name"
    return 0
}

# Start all services
start_all_services() {
    local project="$1"
    local branch="$2"
    local config_file="$3"

    local service_count
    service_count=$(get_services "$config_file")

    if [[ "$service_count" -eq 0 ]]; then
        log_info "No services configured"
        return 0
    fi

    log_info "Starting $service_count services..."

    local failed=0

    for ((i = 0; i < service_count; i++)); do
        local name
        name=$(get_service_by_index "$config_file" "$i" "name")

        if ! start_service "$project" "$branch" "$name" "$config_file"; then
            ((failed++))
        fi

        # Small delay between service starts
        sleep 1
    done

    if [[ "$failed" -gt 0 ]]; then
        log_warn "$failed service(s) failed to start"
        return 1
    fi

    log_success "All services started"
    return 0
}

# Stop all services
stop_all_services() {
    local project="$1"
    local branch="$2"
    local config_file="$3"

    local service_count
    service_count=$(get_services "$config_file")

    if [[ "$service_count" -eq 0 ]]; then
        return 0
    fi

    log_info "Stopping $service_count services..."

    for ((i = 0; i < service_count; i++)); do
        local name
        name=$(get_service_by_index "$config_file" "$i" "name")
        stop_service "$project" "$branch" "$name" "$config_file"
    done

    log_success "All services stopped"
}

# Run health check for a service
run_health_check() {
    local service_name="$1"
    local port="$2"
    local config_file="$3"

    local health_type
    health_type=$(yq -r ".services[] | select(.name == \"$service_name\") | .health_check.type" "$config_file" 2>/dev/null)

    local timeout
    timeout=$(yq -r ".services[] | select(.name == \"$service_name\") | .health_check.timeout // 30" "$config_file" 2>/dev/null)

    local interval
    interval=$(yq -r ".services[] | select(.name == \"$service_name\") | .health_check.interval // 2" "$config_file" 2>/dev/null)

    log_info "Running health check for $service_name (${health_type}, timeout: ${timeout}s)..."

    local elapsed=0

    case "$health_type" in
        tcp)
            while ! nc -z localhost "$port" 2>/dev/null; do
                if ((elapsed >= timeout)); then
                    log_warn "Health check timed out for $service_name"
                    return 1
                fi
                sleep "$interval"
                ((elapsed += interval))
            done
            ;;
        http)
            local url
            url=$(yq -r ".services[] | select(.name == \"$service_name\") | .health_check.url" "$config_file" 2>/dev/null)
            url=$(eval echo "$url")

            while ! curl -sf "$url" &>/dev/null; do
                if ((elapsed >= timeout)); then
                    log_warn "Health check timed out for $service_name"
                    return 1
                fi
                sleep "$interval"
                ((elapsed += interval))
            done
            ;;
        *)
            # No health check
            return 0
            ;;
    esac

    log_success "Health check passed for $service_name"
    return 0
}

# Get service status
get_service_status() {
    local project="$1"
    local branch="$2"
    local service_name="$3"

    local status
    status=$(get_service_state "$project" "$branch" "$service_name" "status")

    echo "${status:-unknown}"
}

# List all services with their status
list_services_status() {
    local project="$1"
    local branch="$2"
    local config_file="$3"

    local service_count
    service_count=$(get_services "$config_file")

    local slot
    slot=$(get_worktree_slot "$project" "$branch")

    printf "\n${BOLD}%-25s %-10s %-8s${NC}\n" "SERVICE" "STATUS" "PORT"
    printf "%s\n" "$(printf '%.0s-' {1..45})"

    for ((i = 0; i < service_count; i++)); do
        local name
        name=$(get_service_by_index "$config_file" "$i" "name")

        local port_key
        port_key=$(get_service_by_index "$config_file" "$i" "port_key")

        local port
        port=$(get_service_port "$port_key" "$branch" "$config_file" "$slot")

        local status
        status=$(get_service_status "$project" "$branch" "$name")

        local status_color="$YELLOW"
        case "$status" in
            running) status_color="$GREEN" ;;
            stopped) status_color="$RED" ;;
        esac

        printf "%-25s ${status_color}%-10s${NC} %-8s\n" "$name" "$status" "${port:-N/A}"
    done
}
