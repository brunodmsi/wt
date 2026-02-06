#!/bin/bash
# lib/state.sh - State file management for worktrees and services

# Get state file path for a project
state_file() {
    local project="$1"
    echo "$WT_STATE_DIR/${project}.state.yaml"
}

# Initialize state file if needed
init_state_file() {
    local project="$1"
    local file
    file=$(state_file "$project")

    if [[ ! -f "$file" ]]; then
        cat > "$file" << EOF
# Runtime state for project: $project
worktrees: {}
EOF
    fi
}

# Get worktree state
get_worktree_state() {
    local project="$1"
    local branch="$2"
    local field="$3"

    local file
    file=$(state_file "$project")

    if [[ ! -f "$file" ]]; then
        echo ""
        return
    fi

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    yaml_get "$file" ".worktrees.\"$sanitized\".$field" ""
}

# Set worktree state (with file locking)
set_worktree_state() {
    local project="$1"
    local branch="$2"
    local field="$3"
    local value="$4"

    init_state_file "$project"
    local file
    file=$(state_file "$project")

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    with_file_lock "$file" _set_worktree_state_locked "$sanitized" "$field" "$value" "$file"
}

_set_worktree_state_locked() {
    local sanitized="$1"
    local field="$2"
    local value="$3"
    local file="$4"

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        yq -i ".worktrees.\"$sanitized\".$field = $value" "$file"
    else
        VALUE="$value" yq -i ".worktrees.\"$sanitized\".$field = strenv(VALUE)" "$file"
    fi
}

# Delete worktree state (with file locking)
delete_worktree_state() {
    local project="$1"
    local branch="$2"

    local file
    file=$(state_file "$project")

    if [[ ! -f "$file" ]]; then
        return
    fi

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    with_file_lock "$file" _delete_worktree_state_locked "$sanitized" "$file" "$branch"
}

_delete_worktree_state_locked() {
    local sanitized="$1"
    local file="$2"
    local branch="$3"

    yq -i "del(.worktrees.\"$sanitized\")" "$file"
    log_debug "Deleted state for worktree: $branch"
}

# Create worktree state entry (with file locking)
create_worktree_state() {
    local project="$1"
    local branch="$2"
    local path="$3"
    local slot="$4"

    init_state_file "$project"
    local file
    file=$(state_file "$project")

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    local ts
    ts=$(timestamp)

    with_file_lock "$file" _create_worktree_state_locked "$sanitized" "$branch" "$path" "$slot" "$ts" "$file"
}

_create_worktree_state_locked() {
    local sanitized="$1"
    local branch="$2"
    local path="$3"
    local slot="$4"
    local ts="$5"
    local file="$6"

    BRANCH="$branch" PATH_VAL="$path" TS="$ts" yq -i "
        .worktrees.\"$sanitized\".branch = strenv(BRANCH) |
        .worktrees.\"$sanitized\".path = strenv(PATH_VAL) |
        .worktrees.\"$sanitized\".slot = $slot |
        .worktrees.\"$sanitized\".created_at = strenv(TS) |
        .worktrees.\"$sanitized\".services = {}
    " "$file"

    log_debug "Created state for worktree: $branch"
}

# Get service state
get_service_state() {
    local project="$1"
    local branch="$2"
    local service="$3"
    local field="$4"

    local file
    file=$(state_file "$project")

    if [[ ! -f "$file" ]]; then
        echo ""
        return
    fi

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    yaml_get "$file" ".worktrees.\"$sanitized\".services.\"$service\".$field" ""
}

# Set service state (with file locking)
set_service_state() {
    local project="$1"
    local branch="$2"
    local service="$3"
    local field="$4"
    local value="$5"

    init_state_file "$project"
    local file
    file=$(state_file "$project")

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    with_file_lock "$file" _set_service_state_locked "$sanitized" "$service" "$field" "$value" "$file"
}

_set_service_state_locked() {
    local sanitized="$1"
    local service="$2"
    local field="$3"
    local value="$4"
    local file="$5"

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        yq -i ".worktrees.\"$sanitized\".services.\"$service\".$field = $value" "$file"
    else
        VALUE="$value" yq -i ".worktrees.\"$sanitized\".services.\"$service\".$field = strenv(VALUE)" "$file"
    fi
}

# Update service status (with file locking, batched yq)
update_service_status() {
    local project="$1"
    local branch="$2"
    local service="$3"
    local status="$4"
    local pid="${5:-}"
    local port="${6:-}"

    init_state_file "$project"
    local file
    file=$(state_file "$project")

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    local ts
    ts=$(timestamp)

    with_file_lock "$file" _update_service_status_locked "$sanitized" "$service" "$status" "$pid" "$port" "$ts" "$file"
}

_update_service_status_locked() {
    local sanitized="$1"
    local service="$2"
    local status="$3"
    local pid="$4"
    local port="$5"
    local ts="$6"
    local file="$7"

    # Build a single yq expression to batch all updates
    local base=".worktrees.\"$sanitized\".services.\"$service\""
    local expr="${base}.status = strenv(STATUS)"

    if [[ -n "$pid" ]]; then
        expr="$expr | ${base}.pid = $pid"
    else
        expr="$expr | ${base}.pid = null"
    fi

    if [[ -n "$port" ]]; then
        expr="$expr | ${base}.port = $port"
    fi

    if [[ "$status" == "running" ]]; then
        expr="$expr | ${base}.started_at = strenv(TS)"
    fi

    STATUS="$status" TS="$ts" yq -i "$expr" "$file"
}

# List all worktrees for a project
list_worktree_states() {
    local project="$1"

    local file
    file=$(state_file "$project")

    if [[ ! -f "$file" ]]; then
        return
    fi

    yq -r '.worktrees | keys | .[]' "$file" 2>/dev/null
}

# Get all service states for a worktree
list_service_states() {
    local project="$1"
    local branch="$2"

    local file
    file=$(state_file "$project")

    if [[ ! -f "$file" ]]; then
        return
    fi

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    yq -r ".worktrees.\"$sanitized\".services | to_entries | .[] | \"\(.key):\(.value.status // \"unknown\"):\(.value.port // \"\"):\(.value.pid // \"\")\"" "$file" 2>/dev/null
}

# Check if service is running (by checking PID)
is_service_running() {
    local project="$1"
    local branch="$2"
    local service="$3"

    local pid
    pid=$(get_service_state "$project" "$branch" "$service" "pid")

    if [[ -z "$pid" ]] || [[ "$pid" == "null" ]]; then
        return 1
    fi

    kill -0 "$pid" 2>/dev/null
}

# Clean up stale service states (processes that died)
cleanup_stale_services() {
    local project="$1"
    local branch="$2"
    local svc_name svc_status svc_port svc_pid  # Declare local to avoid clobbering caller's vars

    while IFS=: read -r svc_name svc_status svc_port svc_pid; do
        [[ -z "$svc_name" ]] && continue

        if [[ -n "$svc_pid" ]] && [[ "$svc_pid" != "null" ]]; then
            if ! kill -0 "$svc_pid" 2>/dev/null; then
                log_debug "Cleaning up stale service: $svc_name (PID $svc_pid)"
                update_service_status "$project" "$branch" "$svc_name" "stopped"
            fi
        fi
    done < <(list_service_states "$project" "$branch")
}

# Clean up stale worktree entries (directories that no longer exist)
cleanup_stale_worktrees() {
    local project="$1"

    local file
    file=$(state_file "$project")

    if [[ ! -f "$file" ]]; then
        return
    fi

    local sanitized_branch wt_path
    while read -r sanitized_branch; do
        [[ -z "$sanitized_branch" ]] && continue

        wt_path=$(yaml_get "$file" ".worktrees.\"$sanitized_branch\".path" "")
        if [[ -n "$wt_path" ]] && [[ ! -d "$wt_path" ]]; then
            local branch
            branch=$(yaml_get "$file" ".worktrees.\"$sanitized_branch\".branch" "$sanitized_branch")
            log_warn "Cleaning up stale worktree state: $branch (path $wt_path no longer exists)"
            release_slot "$project" "$branch" 2>/dev/null || true
            with_file_lock "$file" yq -i "del(.worktrees.\"$sanitized_branch\")" "$file"
        fi
    done < <(list_worktree_states "$project")
}

# Get tmux window name for a worktree (just the sanitized branch name)
get_session_name() {
    local project="$1"
    local branch="$2"

    # Window name is just the sanitized branch name
    sanitize_branch_name "$branch"
}

# Store tmux session in state
set_session_state() {
    local project="$1"
    local branch="$2"
    local session="$3"

    set_worktree_state "$project" "$branch" "session" "$session"
}

# Get worktree path from state
get_worktree_path() {
    local project="$1"
    local branch="$2"

    get_worktree_state "$project" "$branch" "path"
}

# Get worktree slot from state
get_worktree_slot() {
    local project="$1"
    local branch="$2"

    get_worktree_state "$project" "$branch" "slot"
}

# Set a port override for a service in a worktree (with file locking)
set_port_override() {
    local project="$1"
    local branch="$2"
    local service="$3"
    local port="$4"

    init_state_file "$project"
    local file
    file=$(state_file "$project")

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    with_file_lock "$file" _set_port_override_locked "$sanitized" "$service" "$port" "$file"
}

_set_port_override_locked() {
    local sanitized="$1"
    local service="$2"
    local port="$3"
    local file="$4"

    yq -i ".worktrees.\"$sanitized\".port_overrides.\"$service\" = $port" "$file"
    log_debug "Set port override for $service: $port"
}

# Get a port override for a service in a worktree
get_port_override() {
    local project="$1"
    local branch="$2"
    local service="$3"

    local file
    file=$(state_file "$project")

    if [[ ! -f "$file" ]]; then
        echo ""
        return
    fi

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    local override
    override=$(yaml_get "$file" ".worktrees.\"$sanitized\".port_overrides.\"$service\"" "")

    # Return empty if null or not set
    if [[ "$override" == "null" ]] || [[ -z "$override" ]]; then
        echo ""
    else
        echo "$override"
    fi
}

# Clear a port override for a service (with file locking)
clear_port_override() {
    local project="$1"
    local branch="$2"
    local service="$3"

    local file
    file=$(state_file "$project")

    if [[ ! -f "$file" ]]; then
        return
    fi

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    with_file_lock "$file" _clear_port_override_locked "$sanitized" "$service" "$file"
}

_clear_port_override_locked() {
    local sanitized="$1"
    local service="$2"
    local file="$3"

    yq -i "del(.worktrees.\"$sanitized\".port_overrides.\"$service\")" "$file"
    log_debug "Cleared port override for $service"
}

# List all port overrides for a worktree
list_port_overrides() {
    local project="$1"
    local branch="$2"

    local file
    file=$(state_file "$project")

    if [[ ! -f "$file" ]]; then
        return
    fi

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    yq -r ".worktrees.\"$sanitized\".port_overrides // {} | to_entries | .[] | \"\(.key):\(.value)\"" "$file" 2>/dev/null
}
