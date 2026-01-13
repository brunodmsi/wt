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

# Set worktree state
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

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        yq -i ".worktrees.\"$sanitized\".$field = $value" "$file"
    else
        yq -i ".worktrees.\"$sanitized\".$field = \"$value\"" "$file"
    fi
}

# Delete worktree state
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

    yq -i "del(.worktrees.\"$sanitized\")" "$file"
    log_debug "Deleted state for worktree: $branch"
}

# Create worktree state entry
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

    yq -i ".worktrees.\"$sanitized\" = {
        \"branch\": \"$branch\",
        \"path\": \"$path\",
        \"slot\": $slot,
        \"created_at\": \"$ts\",
        \"services\": {}
    }" "$file"

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

# Set service state
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

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        yq -i ".worktrees.\"$sanitized\".services.\"$service\".$field = $value" "$file"
    else
        yq -i ".worktrees.\"$sanitized\".services.\"$service\".$field = \"$value\"" "$file"
    fi
}

# Update service status
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

    yq -i ".worktrees.\"$sanitized\".services.\"$service\".status = \"$status\"" "$file"

    if [[ -n "$pid" ]]; then
        yq -i ".worktrees.\"$sanitized\".services.\"$service\".pid = $pid" "$file"
    else
        yq -i ".worktrees.\"$sanitized\".services.\"$service\".pid = null" "$file"
    fi

    if [[ -n "$port" ]]; then
        yq -i ".worktrees.\"$sanitized\".services.\"$service\".port = $port" "$file"
    fi

    if [[ "$status" == "running" ]]; then
        yq -i ".worktrees.\"$sanitized\".services.\"$service\".started_at = \"$ts\"" "$file"
    fi
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
