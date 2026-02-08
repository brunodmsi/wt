#!/bin/bash
# lib/tmux.sh - tmux session management

# Default session name (can be overridden in config)
# Prefer current tmux session, fall back to "wt" if not inside tmux
if [[ -z "${WT_TMUX_SESSION:-}" ]]; then
    if [[ -n "${TMUX:-}" ]]; then
        WT_TMUX_SESSION=$(tmux display-message -p '#S' 2>/dev/null) || WT_TMUX_SESSION="wt"
    else
        WT_TMUX_SESSION="wt"
    fi
fi

# Check if tmux is available
ensure_tmux() {
    if ! command_exists tmux; then
        die "tmux is required but not installed. Install with: brew install tmux"
    fi
}

# Check if a tmux session exists
session_exists() {
    local session="$1"
    tmux has-session -t "$session" 2>/dev/null
}

# Check if a window exists in a session
window_exists() {
    local session="$1"
    local window="$2"
    tmux list-windows -t "$session" -F "#{window_name}" 2>/dev/null | grep -q "^${window}$"
}

# Get next available window index in a session
get_next_available_window_index() {
    local session="$1"
    local used_indices
    used_indices=$(tmux list-windows -t "$session" -F "#{window_index}" 2>/dev/null | sort -n)

    local next=0
    for idx in $used_indices; do
        if [[ "$idx" -eq "$next" ]]; then
            ((next++))
        else
            break
        fi
    done
    echo "$next"
}

# Get session name from config or default
get_tmux_session_name() {
    local config_file="$1"
    local session_name
    session_name=$(yaml_get "$config_file" ".tmux.session" "")
    echo "${session_name:-$WT_TMUX_SESSION}"
}

# Create or get the main tmux session, then add a window for this worktree
# Window name = sanitized branch name
create_session() {
    local window_name="$1"  # This is now the window name (branch)
    local root_dir="$2"
    local config_file="$3"
    local window_index="${4:-}"  # Optional: specific window index

    ensure_tmux

    # Get the main session name
    local session
    session=$(get_tmux_session_name "$config_file")

    # Create session if it doesn't exist
    if ! session_exists "$session"; then
        log_info "Creating tmux session: $session"
        if ! tmux new-session -d -s "$session" -c "$root_dir" -n "$window_name"; then
            log_error "Failed to create tmux session '$session'. Is tmux available?"
            return 1
        fi
        if [[ -n "$window_index" ]] && [[ "$window_index" != "0" ]]; then
            if ! tmux move-window -s "${session}:0" -t "${session}:${window_index}"; then
                log_warn "Failed to move window to index $window_index"
            fi
        fi
    else
        # Session exists, check if window already exists
        if window_exists "$session" "$window_name"; then
            log_warn "Window already exists: $session:$window_name"
            return 0
        fi
        # Add new window to existing session
        log_info "Adding window '$window_name' to session '$session'"

        if [[ -n "$window_index" ]]; then
            # Check if requested index is occupied
            if tmux list-windows -t "$session" -F "#{window_index}" | grep -q "^${window_index}$"; then
                log_info "Window index $window_index is occupied, moving existing window..."
                local next_index
                next_index=$(get_next_available_window_index "$session")
                if ! tmux move-window -s "${session}:${window_index}" -t "${session}:${next_index}"; then
                    log_warn "Failed to move existing window from index $window_index"
                else
                    log_info "Moved existing window from index $window_index to $next_index"
                fi
            fi
            if ! tmux new-window -t "${session}:${window_index}" -n "$window_name" -c "$root_dir"; then
                log_error "Failed to create window at index $window_index"
                return 1
            fi
        else
            local new_index
            new_index=$(get_next_available_window_index "$session")
            if ! tmux new-window -t "${session}:${new_index}" -n "$window_name" -c "$root_dir"; then
                log_error "Failed to create window '$window_name'"
                return 1
            fi
        fi
    fi

    # Setup panes in the window from config
    setup_window_panes_for_worktree "$session" "$window_name" "$root_dir" "$config_file"

    log_success "Window '$window_name' ready in session '$session'"
    return 0
}

# Setup panes for a worktree window
setup_window_panes_for_worktree() {
    local session="$1"
    local window="$2"
    local root_dir="$3"
    local config_file="$4"

    local layout
    layout=$(yaml_get "$config_file" ".tmux.layout" "tiled")

    local pane_count
    pane_count=$(yaml_array_length "$config_file" ".tmux.windows[0].panes")

    if [[ "$pane_count" -eq 0 ]]; then
        return
    fi

    # Check for custom layout: "services-top"
    if [[ "$layout" == "services-top" ]] && [[ "$pane_count" -gt 1 ]]; then
        setup_services_top_layout_window "$session" "$window" "$root_dir" "$config_file" "$pane_count"
        return
    fi

    # Create additional panes
    for ((p = 1; p < pane_count; p++)); do
        tmux split-window -t "${session}:${window}"
    done

    # Apply layout
    tmux select-layout -t "${session}:${window}" "$layout" 2>/dev/null || true

    # Configure panes
    configure_window_panes "$session" "$window" "$config_file" "$pane_count" "$root_dir"
}

# Wrapper for worktree window layout - delegates to setup_services_top_layout with win_idx=0
setup_services_top_layout_window() {
    local session="$1"
    local window="$2"
    local root_dir="$3"
    local config_file="$4"
    local pane_count="$5"

    # Delegate to the main function with win_idx=0
    setup_services_top_layout "$session" "$window" "$root_dir" "$config_file" "0" "$pane_count"
}

# Configure panes in a window
configure_window_panes() {
    local session="$1"
    local window="$2"
    local config_file="$3"
    local pane_count="$4"
    local root_dir="$5"

    for ((p = 0; p < pane_count; p++)); do
        local pane_config
        pane_config=$(yq ".tmux.windows[0].panes[$p]" "$config_file" 2>/dev/null)

        local pane_type
        pane_type=$(echo "$pane_config" | yq 'type' 2>/dev/null)

        local pane_service=""
        local pane_cmd=""

        if [[ "$pane_type" == "\"string\"" ]]; then
            pane_cmd=$(echo "$pane_config" | yq -r '.' 2>/dev/null)
        else
            pane_service=$(echo "$pane_config" | yq -r '.service // ""' 2>/dev/null)
            pane_cmd=$(echo "$pane_config" | yq -r '.command // ""' 2>/dev/null)
        fi

        if [[ -n "$pane_service" ]] && [[ "$pane_service" != "null" ]]; then
            # Get service working directory
            local svc_working_dir
            svc_working_dir=$(yq -r ".services[] | select(.name == \"$pane_service\") | .working_dir // \"\"" "$config_file" 2>/dev/null)

            # CD to service directory if configured
            if [[ -n "$svc_working_dir" ]] && [[ "$svc_working_dir" != "null" ]] && [[ -n "$root_dir" ]]; then
                tmux send-keys -t "${session}:${window}.${p}" "cd '$root_dir/$svc_working_dir'" Enter
            fi
            tmux send-keys -t "${session}:${window}.${p}" "# Service: $pane_service (use 'wt start' to run)" Enter
        elif [[ -n "$pane_cmd" ]] && [[ "$pane_cmd" != "null" ]] && [[ "$pane_cmd" != "" ]]; then
            # Get optional working_dir for command pane, default to worktree root
            local cmd_working_dir
            cmd_working_dir=$(echo "$pane_config" | yq -r '.working_dir // ""' 2>/dev/null)

            # CD to working directory (or root if not specified)
            if [[ -n "$root_dir" ]]; then
                if [[ -n "$cmd_working_dir" ]] && [[ "$cmd_working_dir" != "null" ]] && [[ "$cmd_working_dir" != "." ]]; then
                    tmux send-keys -t "${session}:${window}.${p}" "cd '$root_dir/$cmd_working_dir'" Enter
                else
                    tmux send-keys -t "${session}:${window}.${p}" "cd '$root_dir'" Enter
                fi
            fi
            tmux send-keys -t "${session}:${window}.${p}" "$pane_cmd" Enter
        fi
    done
}

# Setup tmux windows from configuration
setup_tmux_windows() {
    local session="$1"
    local root_dir="$2"
    local config_file="$3"

    local window_count
    window_count=$(yaml_array_length "$config_file" ".tmux.windows")

    if [[ "$window_count" -eq 0 ]]; then
        # No windows configured, create a default shell window
        tmux rename-window -t "${session}:0" "shell"
        return
    fi

    for ((i = 0; i < window_count; i++)); do
        local window_name
        window_name=$(yaml_get "$config_file" ".tmux.windows[$i].name" "window-$i")

        local window_root
        window_root=$(yaml_get "$config_file" ".tmux.windows[$i].root" "")

        local layout
        layout=$(yaml_get "$config_file" ".tmux.windows[$i].layout" "even-horizontal")

        # Determine window working directory
        local win_dir="$root_dir"
        if [[ -n "$window_root" ]] && [[ "$window_root" != "null" ]]; then
            win_dir="$root_dir/$window_root"
        fi

        # Create or rename window
        if [[ "$i" -eq 0 ]]; then
            tmux rename-window -t "${session}:0" "$window_name"
            tmux send-keys -t "${session}:${window_name}" "cd '$win_dir'" Enter
        else
            tmux new-window -t "$session" -n "$window_name" -c "$win_dir"
        fi

        # Setup panes
        setup_window_panes "$session" "$window_name" "$root_dir" "$config_file" "$i" "$layout"
    done

    # Select first window
    tmux select-window -t "${session}:0"
}

# Setup panes for a window
setup_window_panes() {
    local session="$1"
    local window="$2"
    local root_dir="$3"
    local config_file="$4"
    local win_idx="$5"
    local layout="$6"

    local pane_count
    pane_count=$(yaml_array_length "$config_file" ".tmux.windows[$win_idx].panes")

    if [[ "$pane_count" -eq 0 ]]; then
        return
    fi

    # Check for custom layout: "services-top" puts N-1 panes on top row, last pane full-width bottom
    if [[ "$layout" == "services-top" ]] && [[ "$pane_count" -gt 1 ]]; then
        setup_services_top_layout "$session" "$window" "$root_dir" "$config_file" "$win_idx" "$pane_count"
        return
    fi

    # Create additional panes (first pane already exists)
    for ((p = 1; p < pane_count; p++)); do
        tmux split-window -t "${session}:${window}"
    done

    # Apply layout
    tmux select-layout -t "${session}:${window}" "$layout" 2>/dev/null || true

    # Configure each pane
    configure_panes "$session" "$window" "$config_file" "$win_idx" "$pane_count" "$root_dir"
}

# Custom layout: services on top, main panes on bottom
# +----------+----------+----------+
# | service1 | service2 | service3 |  <- 35% height
# +----------+----------+----------+
# |     claude (80%)     |  wt(20%)|  <- 65% height
# +----------------------+---------+
setup_services_top_layout() {
    local session="$1"
    local window="$2"
    local root_dir="$3"
    local config_file="$4"
    local win_idx="$5"
    local pane_count="$6"

    # Pre-fetch all pane configs and service working dirs in 2 yq calls (replaces ~5N calls)
    local all_pane_data
    all_pane_data=$(yq -r ".tmux.windows[$win_idx].panes[] | [.service // \"\", .command // \"\"] | @tsv" "$config_file" 2>/dev/null)

    local all_svc_dirs
    all_svc_dirs=$(yq -r '.services[] | [.name, .working_dir // ""] | @tsv' "$config_file" 2>/dev/null)

    # Count service panes from pre-fetched data
    local service_count=0
    while IFS=$'\t' read -r _svc _cmd; do
        if [[ -n "$_svc" ]] && [[ "$_svc" != "null" ]]; then
            ((service_count++))
        fi
    done <<< "$all_pane_data"

    # Split sequence - tmux renumbers panes visually after each split!
    # We must account for this when targeting panes.

    # Split 1: vertical split - creates bottom pane (65%)
    # After: pane 0 = top, pane 1 = bottom
    tmux split-window -t "${session}:${window}.0" -v -p 65

    # Split 2: horizontal split of top (pane 0) for service 2
    # After visual renumber: pane 0 = top-left, pane 1 = top-right, pane 2 = bottom
    if [[ $service_count -ge 2 ]]; then
        tmux split-window -t "${session}:${window}.0" -h -p 66
    fi

    # Split 3: split top-right (now pane 1 after renumber) for service 3
    # After visual renumber: pane 0 = top-left, pane 1 = top-middle, pane 2 = top-right, pane 3 = bottom
    if [[ $service_count -ge 3 ]]; then
        tmux split-window -t "${session}:${window}.1" -h -p 50
    fi

    # Split 4: split bottom (now pane 3 after renumber) for orchestrator (20%)
    # After: pane 0-2 = top row, pane 3 = bottom-left, pane 4 = bottom-right
    if [[ $pane_count -gt 4 ]]; then
        tmux split-window -t "${session}:${window}.3" -h -p 20
    fi

    # Pane mapping after splits (tmux renumbers by visual position: left-to-right, top-to-bottom):
    # Pane 0 = top-left (config 0 = service 1)
    # Pane 1 = top-middle (config 1 = service 2)
    # Pane 2 = top-right (config 2 = service 3)
    # Pane 3 = bottom-left (config 3 = claude)
    # Pane 4 = bottom-right (config 4 = orchestrator)

    # Build mapping array: config_index -> tmux_pane (sequential due to visual renumbering)
    local -a pane_map=(0 1 2 3 4)

    # Configure each pane using pre-fetched data (no per-pane yq calls)
    local p=0
    while IFS=$'\t' read -r pane_service pane_cmd; do
        [[ $p -ge $pane_count ]] && break
        local tmux_pane="${pane_map[$p]}"

        if [[ -n "$pane_service" ]] && [[ "$pane_service" != "null" ]]; then
            # Look up working_dir from pre-fetched service dirs
            local svc_working_dir=""
            while IFS=$'\t' read -r svc_name svc_dir; do
                if [[ "$svc_name" == "$pane_service" ]]; then
                    svc_working_dir="$svc_dir"
                    break
                fi
            done <<< "$all_svc_dirs"

            if [[ -n "$svc_working_dir" ]] && [[ "$svc_working_dir" != "null" ]] && [[ -n "$root_dir" ]]; then
                tmux send-keys -t "${session}:${window}.${tmux_pane}" "cd '$root_dir/$svc_working_dir'" Enter
            fi
            tmux send-keys -t "${session}:${window}.${tmux_pane}" "# Service: $pane_service (use 'wt start' to run)" Enter
        elif [[ -n "$pane_cmd" ]] && [[ "$pane_cmd" != "null" ]] && [[ "$pane_cmd" != "" ]]; then
            if [[ -n "$root_dir" ]]; then
                tmux send-keys -t "${session}:${window}.${tmux_pane}" "cd '$root_dir'" Enter
            fi
            tmux send-keys -t "${session}:${window}.${tmux_pane}" "$pane_cmd" Enter
        else
            # Empty command pane (orchestrator)
            if [[ -n "$root_dir" ]]; then
                tmux send-keys -t "${session}:${window}.${tmux_pane}" "cd '$root_dir'" Enter
            fi
        fi
        ((p++))
    done <<< "$all_pane_data"

    # Select claude pane (pane 3 = bottom-left) as active
    tmux select-pane -t "${session}:${window}.3"
}

# Configure panes with commands/services
configure_panes() {
    local session="$1"
    local window="$2"
    local config_file="$3"
    local win_idx="$4"
    local pane_count="$5"
    local root_dir="${6:-}"

    # Pre-fetch all pane configs in a single yq call (handles both string and object panes)
    local all_pane_data
    all_pane_data=$(yq -r ".tmux.windows[$win_idx].panes[] | if type == \"!!str\" then [\"string\", \"\", ., \"\"] else [\"object\", .service // \"\", .command // \"\", .working_dir // \"\"] end | @tsv" "$config_file" 2>/dev/null)

    # Pre-fetch service working dirs for cross-reference
    local all_svc_dirs
    all_svc_dirs=$(yq -r '.services[] | [.name, .working_dir // ""] | @tsv' "$config_file" 2>/dev/null)

    local p=0
    while IFS=$'\t' read -r pane_type pane_service pane_cmd pane_working_dir; do
        [[ $p -ge $pane_count ]] && break

        if [[ "$pane_type" == "string" ]]; then
            # String pane: pane_cmd is in pane_service field (from yq output), swap it
            pane_cmd="$pane_service"
            pane_service=""
        fi

        if [[ -n "$pane_service" ]] && [[ "$pane_service" != "null" ]]; then
            # Look up service working_dir from pre-fetched data
            local svc_working_dir=""
            while IFS=$'\t' read -r svc_name svc_dir; do
                if [[ "$svc_name" == "$pane_service" ]]; then
                    svc_working_dir="$svc_dir"
                    break
                fi
            done <<< "$all_svc_dirs"

            if [[ -n "$svc_working_dir" ]] && [[ "$svc_working_dir" != "null" ]] && [[ -n "$root_dir" ]]; then
                tmux send-keys -t "${session}:${window}.${p}" "cd '$root_dir/$svc_working_dir'" Enter
            fi
            tmux send-keys -t "${session}:${window}.${p}" "# Service: $pane_service (use 'wt start' to run)" Enter
        elif [[ -n "$pane_cmd" ]] && [[ "$pane_cmd" != "null" ]] && [[ "$pane_cmd" != "" ]]; then
            local cmd_working_dir="$pane_working_dir"

            if [[ -n "$root_dir" ]]; then
                if [[ -n "$cmd_working_dir" ]] && [[ "$cmd_working_dir" != "null" ]] && [[ "$cmd_working_dir" != "." ]]; then
                    tmux send-keys -t "${session}:${window}.${p}" "cd '$root_dir/$cmd_working_dir'" Enter
                else
                    tmux send-keys -t "${session}:${window}.${p}" "cd '$root_dir'" Enter
                fi
            fi
            tmux send-keys -t "${session}:${window}.${p}" "$pane_cmd" Enter
        fi
        ((p++))
    done <<< "$all_pane_data"
}

# Kill a tmux window (not the whole session)
kill_session() {
    local window_name="$1"
    local config_file="${2:-}"

    local session
    if [[ -n "$config_file" ]]; then
        session=$(get_tmux_session_name "$config_file")
    else
        session="$WT_TMUX_SESSION"
    fi

    if ! session_exists "$session"; then
        log_debug "Session does not exist: $session"
        return 0
    fi

    if ! window_exists "$session" "$window_name"; then
        log_debug "Window does not exist: $session:$window_name"
        return 0
    fi

    log_info "Killing tmux window: $session:$window_name"
    tmux kill-window -t "${session}:${window_name}"
}

# Attach to a tmux session and select the worktree window
attach_session() {
    local window_name="$1"
    local config_file="${2:-}"

    ensure_tmux

    local session
    if [[ -n "$config_file" ]]; then
        session=$(get_tmux_session_name "$config_file")
    else
        session="$WT_TMUX_SESSION"
    fi

    if ! session_exists "$session"; then
        log_error "Session does not exist: $session"
        return 1
    fi

    # Select the window
    if [[ -n "$window_name" ]] && window_exists "$session" "$window_name"; then
        tmux select-window -t "${session}:${window_name}" 2>/dev/null
    fi

    # Check if we're already in tmux
    if [[ -n "${TMUX:-}" ]]; then
        tmux switch-client -t "$session"
    else
        tmux attach-session -t "$session"
    fi
}

# List tmux windows in the main session
list_sessions() {
    local session="${1:-$WT_TMUX_SESSION}"
    tmux list-windows -t "$session" -F "#{window_name}" 2>/dev/null || true
}

# Send command to a specific pane
send_to_pane() {
    local session="$1"
    local window="$2"
    local pane="$3"
    local command="$4"

    tmux send-keys -t "${session}:${window}.${pane}" "$command" Enter
}

# Find pane for a service
find_service_pane() {
    local session="$1"
    local service_name="$2"
    local config_file="$3"

    local window_count
    window_count=$(yaml_array_length "$config_file" ".tmux.windows")

    for ((w = 0; w < window_count; w++)); do
        local window_name
        window_name=$(yaml_get "$config_file" ".tmux.windows[$w].name" "window-$w")

        local pane_count
        pane_count=$(yaml_array_length "$config_file" ".tmux.windows[$w].panes")

        for ((p = 0; p < pane_count; p++)); do
            local pane_service
            pane_service=$(yq -r ".tmux.windows[$w].panes[$p].service // \"\"" "$config_file" 2>/dev/null)

            if [[ "$pane_service" == "$service_name" ]]; then
                echo "${window_name}:${p}"
                return 0
            fi
        done
    done

    return 1
}

# Create a new window for a service
create_service_window() {
    local session="$1"
    local service_name="$2"
    local working_dir="$3"

    if ! session_exists "$session"; then
        log_error "Session does not exist: $session"
        return 1
    fi

    # Check if window already exists
    if tmux list-windows -t "$session" -F "#{window_name}" | grep -q "^${service_name}$"; then
        log_debug "Window already exists: $service_name"
        return 0
    fi

    tmux new-window -t "$session" -n "$service_name" -c "$working_dir"
}

# Get session info
session_info() {
    local session="$1"

    if ! session_exists "$session"; then
        return 1
    fi

    tmux list-windows -t "$session" -F "#{window_index}:#{window_name}:#{window_active}"
}

# Capture pane output
# Usage: capture_pane <session> <window> <pane> [lines]
capture_pane() {
    local session="$1"
    local window="$2"
    local pane="$3"
    local lines="${4:-50}"

    tmux capture-pane -t "${session}:${window}.${pane}" -p -S "-${lines}"
}

# List panes in a window with format info
# Returns: index, active, current_command, width x height
list_window_panes() {
    local session="$1"
    local window="$2"

    tmux list-panes -t "${session}:${window}" -F "#{pane_index}:#{pane_active}:#{pane_current_command}:#{pane_width}x#{pane_height}" 2>/dev/null
}

# Send interrupt (Ctrl+C) to a pane
interrupt_pane() {
    local session="$1"
    local target="$2"  # window:pane or just window

    tmux send-keys -t "${session}:${target}" C-c
}
