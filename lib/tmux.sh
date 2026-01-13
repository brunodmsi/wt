#!/bin/bash
# lib/tmux.sh - tmux session management

# Default session name (can be overridden in config)
WT_TMUX_SESSION="${WT_TMUX_SESSION:-karma}"

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

    ensure_tmux

    # Get the main session name
    local session
    session=$(get_tmux_session_name "$config_file")

    # Create session if it doesn't exist
    if ! session_exists "$session"; then
        log_info "Creating tmux session: $session"
        tmux new-session -d -s "$session" -c "$root_dir" -n "$window_name"
    else
        # Session exists, check if window already exists
        if window_exists "$session" "$window_name"; then
            log_warn "Window already exists: $session:$window_name"
            return 0
        fi
        # Add new window to existing session
        log_info "Adding window '$window_name' to session '$session'"
        tmux new-window -t "$session" -n "$window_name" -c "$root_dir"
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

# Custom layout for worktree window: services on top, main pane on bottom
# +----------+----------+----------+
# | service1 | service2 | service3 |  <- 35% height
# +----------+----------+----------+
# |       claude (full width)      |  <- 65% height
# +--------------------------------+
setup_services_top_layout_window() {
    local session="$1"
    local window="$2"
    local root_dir="$3"
    local config_file="$4"
    local pane_count="$5"

    local service_count=$((pane_count - 1))

    # Start with pane 0 (the initial pane)
    # First, split vertically: top stays as pane 0, bottom becomes last pane
    tmux split-window -t "${session}:${window}.0" -v -p 65

    # Now pane 0 is top (35%), pane 1 is bottom (65%)
    # Split pane 0 horizontally for each additional service
    for ((s = 1; s < service_count; s++)); do
        tmux split-window -t "${session}:${window}.0" -h -p $((100 / (service_count - s + 1)))
    done

    # After splits, panes are: 0,1,2 = services (top row), 3 = bottom (claude)
    # But pane indices may have shifted. Let's use even-horizontal on top row only.
    # Unfortunately tmux doesn't support partial layouts easily, so we manually size.

    # Select pane 0 and apply even-horizontal to just the top panes
    # This is tricky - instead let's just accept the split percentages above

    # Configure panes with their directories and commands
    configure_window_panes "$session" "$window" "$config_file" "$pane_count" "$root_dir"

    # Select bottom pane (claude)
    tmux select-pane -t "${session}:${window}.$((pane_count - 1))"
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

# Custom layout: services on top (vertical), main pane on bottom (full-width)
# +----------+----------+----------+
# | service1 | service2 | service3 |
# +----------+----------+----------+
# |       main pane (full width)   |
# +--------------------------------+
setup_services_top_layout() {
    local session="$1"
    local window="$2"
    local root_dir="$3"
    local config_file="$4"
    local win_idx="$5"
    local pane_count="$6"

    local service_count=$((pane_count - 1))

    # First, split vertically: top (35%) for services, bottom (65%) for main pane
    tmux split-window -t "${session}:${window}.0" -v -p 65

    # Now pane 0 is top, pane 1 is bottom
    # Split top pane horizontally for each additional service with equal widths
    for ((s = 1; s < service_count; s++)); do
        tmux split-window -t "${session}:${window}.0" -h -p $((100 / (service_count - s + 1)))
    done

    # Configure each pane
    # After our splits: panes 0,1,2 are services (top), pane 3 is bottom (claude)
    # But tmux renumbers, so let's configure by iterating
    for ((p = 0; p < pane_count; p++)); do
        local pane_config
        pane_config=$(yq ".tmux.windows[$win_idx].panes[$p]" "$config_file" 2>/dev/null)

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

    # Select the bottom pane (claude) as active
    tmux select-pane -t "${session}:${window}.$((pane_count - 1))"
}

# Configure panes with commands/services
configure_panes() {
    local session="$1"
    local window="$2"
    local config_file="$3"
    local win_idx="$4"
    local pane_count="$5"
    local root_dir="${6:-}"

    for ((p = 0; p < pane_count; p++)); do
        local pane_config
        pane_config=$(yq ".tmux.windows[$win_idx].panes[$p]" "$config_file" 2>/dev/null)

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

# Send interrupt (Ctrl+C) to a pane
interrupt_pane() {
    local session="$1"
    local target="$2"  # window:pane or just window

    tmux send-keys -t "${session}:${target}" C-c
}
