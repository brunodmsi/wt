#!/bin/bash
# lib/service.sh - Service lifecycle management

# Return the log file path for a service
get_service_log_path() {
    local project="$1"
    local branch="$2"
    local service_name="$3"

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")
    local log_dir="$WT_LOG_DIR/${project}/${sanitized}"
    ensure_dir "$log_dir"
    echo "${log_dir}/${service_name}.log"
}

# Find the pane index for a service in the config
# Pane mapping for services-top layout with 5 panes (tmux renumbers by visual position):
#   config 0 (service 1) -> tmux pane 0 (top-left)
#   config 1 (service 2) -> tmux pane 1 (top-middle)
#   config 2 (service 3) -> tmux pane 2 (top-right)
#   config 3 (claude)    -> tmux pane 3 (bottom-left)
#   config 4 (orchestr)  -> tmux pane 4 (bottom-right)
find_service_pane_index() {
    local config_file="$1"
    local service_name="$2"

    # Read all pane services in one yq call
    local pane_services
    pane_services=$(yq -r '.tmux.windows[0].panes[]?.service // ""' "$config_file" 2>/dev/null)

    log_debug "find_service_pane_index: service=$service_name"

    local p=0
    while IFS= read -r svc; do
        if [[ "$svc" == "$service_name" ]]; then
            log_debug "find_service_pane_index: found $service_name at config $p -> tmux pane $p"
            echo "$p"
            return 0
        fi
        ((p++))
    done <<< "$pane_services"

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

    # Get service configuration (single yq call for all fields)
    local svc_config
    svc_config=$(yq -r ".services[] | select(.name == \"$service_name\") | [.working_dir // \".\", .command // \"\", .port_key // \"\"] | @tsv" "$config_file" 2>/dev/null)

    local svc_dir svc_cmd port_key
    IFS=$'\t' read -r svc_dir svc_cmd port_key <<< "$svc_config"

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

    # Calculate all worktree ports once and reuse for both port lookup and export
    local all_ports
    all_ports=$(calculate_worktree_ports "$branch" "$config_file" "$slot")

    # Check for port override first, then fall back to calculated port
    local port=""
    if [[ -n "$project" ]]; then
        port=$(get_port_override "$project" "$branch" "$port_key")
    fi
    if [[ -z "$port" ]]; then
        port=$(echo "$all_ports" | grep "^$port_key:" | cut -d: -f2)
    fi

    log_debug "Got port=$port for $service_name"

    if [[ -z "$port" ]]; then
        log_error "Could not determine port for service: $service_name"
        log_error "  port_key=$port_key, slot=$slot, config=$config_file"
        log_error "  Available ports: $(echo "$all_ports" | tr '\n' ' ')"
        return 1
    fi

    # Check if already running
    if is_service_running "$project" "$branch" "$service_name"; then
        log_warn "Service already running: $service_name"
        return 0
    fi

    # Export port variables using cached port data (avoids recalculating)
    export PORT="$port"
    export_port_vars "$branch" "$config_file" "$slot" "$project" "$all_ports"

    # Build environment string for tmux command
    # Start with PORT
    local env_string="PORT=$port"

    # Get service environment and build env string
    local svc_env
    svc_env=$(yq -r ".services[] | select(.name == \"$service_name\") | .env // {} | to_entries | .[] | \"\(.key)=\(.value)\"" "$config_file" 2>/dev/null)

    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        # Expand variables in value (e.g., ${PORT_GAP_INDEXER})
        value=$(echo "$value" | envsubst 2>/dev/null || echo "$value")
        # Add to env string for tmux command
        env_string="$env_string $key=$value"
        # Also export locally for pre_start commands
        export "$key=$value"
    done <<< "$svc_env"

    # Build exec_dir early so pre_start can use it
    local exec_dir="$worktree_path/$svc_dir"

    if [[ ! -d "$exec_dir" ]]; then
        log_error "Service working directory does not exist: $exec_dir"
        log_error "  Check 'working_dir' for service '$service_name' in config"
        return 1
    fi

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

    # Check if port is available before starting.
    # If the port is occupied but the service is not tracked as running, there
    # is an orphaned process (e.g. from a previous interrupted start). Kill it
    # automatically so the new start can proceed.
    if ! is_port_available "$port"; then
        if ! is_service_running "$project" "$branch" "$service_name"; then
            log_warn "Port $port occupied by untracked process — killing orphan before restart"
            local orphan_pids
            orphan_pids=$(lsof -ti "tcp:${port}" 2>/dev/null || true)
            if [[ -n "$orphan_pids" ]]; then
                echo "$orphan_pids" | xargs kill -KILL 2>/dev/null || true
                sleep 1
            fi
        fi
        if ! is_port_available "$port"; then
            log_error "Port $port is already in use (service: $service_name)"
            log_error "Use 'wt ports set $service_name <port>' to assign a different port"
            return 1
        fi
    fi

    log_info "Starting $service_name on port $port..."

    # Rotate log: preserve previous run, start fresh
    local log_file
    log_file=$(get_service_log_path "$project" "$branch" "$service_name")
    mv "$log_file" "${log_file}.prev" 2>/dev/null || true

    # Launch service as a background process in its own process group.
    # set -m creates a new process group (PGID == PID of subshell).
    # exec replaces the subshell so the service process inherits that PGID.
    # All env vars are already exported above; stdout+stderr go to the log file.
    (set -m; cd "$exec_dir" && exec $svc_cmd) < /dev/null >> "$log_file" 2>&1 &
    local svc_pid=$!
    disown "$svc_pid" 2>/dev/null || true

    # Update state with real PID
    update_service_status "$project" "$branch" "$service_name" "running" "$svc_pid" "$port"

    # Wire up tail -f in the designated tmux pane so output is visible
    local pane_idx
    pane_idx=$(find_service_pane_index "$config_file" "$service_name") || true

    if [[ -n "$pane_idx" ]]; then
        # Only send C-c if we are NOT inside the target pane.
        # If wt start was called from the service pane itself, C-c would
        # interrupt wt start rather than the old tail. In that case, skip it —
        # wt start exits normally and the shell then runs the queued tail -f.
        local target_pane_id current_pane_id
        target_pane_id=$(tmux display-message -t "${tmux_session}:${window_name}.${pane_idx}" -p "#{pane_id}" 2>/dev/null || true)
        current_pane_id="${TMUX_PANE:-}"
        if [[ -z "$current_pane_id" ]] || [[ "$current_pane_id" != "$target_pane_id" ]]; then
            tmux send-keys -t "${tmux_session}:${window_name}.${pane_idx}" C-c
        fi
        tmux send-keys -t "${tmux_session}:${window_name}.${pane_idx}" "tail -n 200 -f '${log_file}'" Enter
    else
        # No pane configured — create a dedicated window and tail there
        tmux new-window -d -t "$tmux_session" -n "${window_name}-${service_name}" -c "$exec_dir"
        tmux send-keys -t "${tmux_session}:${window_name}-${service_name}" "tail -n 200 -f '${log_file}'" Enter
    fi

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

    # Kill the background process by process group (catches child processes too)
    local svc_pid
    svc_pid=$(get_service_state "$project" "$branch" "$service_name" "pid")

    if [[ -n "$svc_pid" ]] && [[ "$svc_pid" != "null" ]]; then
        # SIGTERM to the whole process group (catches child processes),
        # then fall back to a direct PID kill in case the PGID differs
        kill -TERM -- "-${svc_pid}" 2>/dev/null || true
        kill -TERM "$svc_pid" 2>/dev/null || true

        # Wait up to 5s for graceful exit, then force-kill
        local waited=0
        while kill -0 "$svc_pid" 2>/dev/null && [[ $waited -lt 5 ]]; do
            sleep 1
            waited=$((waited + 1))
        done

        kill -KILL -- "-${svc_pid}" 2>/dev/null || true
        kill -KILL "$svc_pid" 2>/dev/null || true
    else
        log_warn "No PID recorded for $service_name — attempting port-based cleanup"
        # Fall back: find and kill any process on the service's port
        local svc_port
        svc_port=$(get_service_state "$project" "$branch" "$service_name" "port")
        if [[ -n "$svc_port" ]] && [[ "$svc_port" != "null" ]]; then
            local port_pids
            port_pids=$(lsof -ti "tcp:${svc_port}" 2>/dev/null || true)
            if [[ -n "$port_pids" ]]; then
                log_info "Killing process(es) on port $svc_port: $port_pids"
                echo "$port_pids" | xargs kill -KILL 2>/dev/null || true
            fi
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

    # Pre-fetch all service names in one yq call
    local service_names
    service_names=$(yq -r '.services[].name' "$config_file" 2>/dev/null)

    if [[ -z "$service_names" ]]; then
        log_info "No services configured"
        return 0
    fi

    local service_count
    service_count=$(echo "$service_names" | wc -l | tr -d ' ')

    log_info "Starting $service_count services..."

    local failed=0

    while read -r name; do
        [[ -z "$name" ]] && continue

        if ! start_service "$project" "$branch" "$name" "$config_file"; then
            ((failed++))
        fi

        # Small delay between service starts
        sleep 1
    done <<< "$service_names"

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

    # Pre-fetch all service names in one yq call
    local service_names
    service_names=$(yq -r '.services[].name' "$config_file" 2>/dev/null)

    if [[ -z "$service_names" ]]; then
        return 0
    fi

    local service_count
    service_count=$(echo "$service_names" | wc -l | tr -d ' ')

    log_info "Stopping $service_count services..."

    local failed=0
    while read -r name; do
        [[ -z "$name" ]] && continue
        if ! stop_service "$project" "$branch" "$name" "$config_file"; then
            ((failed++))
        fi
    done <<< "$service_names"

    if [[ "$failed" -gt 0 ]]; then
        log_warn "$failed service(s) failed to stop"
        return 1
    fi

    log_success "All services stopped"
}

# Run health check for a service
run_health_check() {
    local service_name="$1"
    local port="$2"
    local config_file="$3"

    # Batch health check config (single yq call for all fields)
    local health_config
    health_config=$(yq -r ".services[] | select(.name == \"$service_name\") | .health_check | [.type // \"\", .timeout // 30, .interval // 2, .url // \"\"] | @tsv" "$config_file" 2>/dev/null)

    local health_type timeout interval health_url
    IFS=$'\t' read -r health_type timeout interval health_url <<< "$health_config"

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
            local url="$health_url"
            url=$(echo "$url" | envsubst 2>/dev/null || echo "$url")

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

    # Calculate all ports once for the entire listing
    local all_ports
    all_ports=$(calculate_worktree_ports "$branch" "$config_file" "$slot")

    printf "\n${BOLD}%-25s %-10s %-8s${NC}\n" "SERVICE" "STATUS" "PORT"
    printf "%s\n" "$(printf '%.0s-' {1..45})"

    for ((i = 0; i < service_count; i++)); do
        local name
        name=$(get_service_by_index "$config_file" "$i" "name")

        local port_key
        port_key=$(get_service_by_index "$config_file" "$i" "port_key")

        # Look up port from cached calculation, with override check
        local port=""
        if [[ -n "$project" ]]; then
            port=$(get_port_override "$project" "$branch" "$port_key")
        fi
        if [[ -z "$port" ]]; then
            port=$(echo "$all_ports" | grep "^$port_key:" | cut -d: -f2)
        fi

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
