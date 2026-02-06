#!/bin/bash
# lib/port.sh - Port hashing and slot management

# Calculate dynamic port from branch name hash
# Uses cksum for deterministic, portable hashing
calculate_dynamic_port() {
    local branch="$1"
    local port_min="${2:-4000}"
    local port_max="${3:-5000}"

    local range=$((port_max - port_min))
    local hash
    hash=$(echo -n "$branch" | cksum | awk '{print $1}')

    echo $((port_min + (hash % range)))
}

# Calculate reserved port from slot
# Slot 0: 3000, 3001
# Slot 1: 3002, 3003
# Slot 2: 3004, 3005
calculate_reserved_port() {
    local slot="$1"
    local service_offset="$2"
    local base="${3:-3000}"
    local services_per_slot="${4:-2}"

    echo $((base + (slot * services_per_slot) + service_offset))
}

# Get all ports for a worktree
# Returns: SERVICE_NAME:PORT pairs
calculate_worktree_ports() {
    local branch="$1"
    local config_file="$2"
    local slot="$3"
    local svc_name offset svc_port  # Declare loop vars local

    local reserved_base
    reserved_base=$(yaml_get "$config_file" ".ports.reserved.range.min" "3000")

    local dynamic_min
    dynamic_min=$(yaml_get "$config_file" ".ports.dynamic.range.min" "4000")

    local dynamic_max
    dynamic_max=$(yaml_get "$config_file" ".ports.dynamic.range.max" "5000")

    # Get reserved services
    local reserved_services
    reserved_services=$(yq -r '.ports.reserved.services // {} | to_entries | .[] | "\(.key):\(.value)"' "$config_file" 2>/dev/null)

    # Get dynamic services
    local dynamic_services
    dynamic_services=$(yq -r '.ports.dynamic.services // {} | keys | .[]' "$config_file" 2>/dev/null)

    # Output reserved service ports
    while IFS=: read -r svc_name offset; do
        [[ -z "$svc_name" ]] && continue
        svc_port=$(calculate_reserved_port "$slot" "$offset" "$reserved_base")
        echo "$svc_name:$svc_port"
    done <<< "$reserved_services"

    # Output dynamic service ports
    while read -r svc_name; do
        [[ -z "$svc_name" ]] && continue
        svc_port=$(calculate_dynamic_port "$branch" "$dynamic_min" "$dynamic_max")
        echo "$svc_name:$svc_port"
    done <<< "$dynamic_services"
}

# Export port environment variables for all services
# If project is provided, port overrides are applied
export_port_vars() {
    local branch="$1"
    local config_file="$2"
    local slot="$3"
    local project="${4:-}"
    local svc_name svc_port  # Declare loop vars local to avoid clobbering caller's vars

    while IFS=: read -r svc_name svc_port; do
        [[ -z "$svc_name" ]] && continue

        # Check for port override if project is provided
        local effective_port="$svc_port"
        if [[ -n "$project" ]]; then
            local override
            override=$(get_port_override "$project" "$branch" "$svc_name")
            if [[ -n "$override" ]]; then
                effective_port="$override"
                log_debug "Using port override for $svc_name: $override"
            fi
        fi

        # Export PORT_<SERVICE_NAME> (uppercase, dashes to underscores)
        local var_name
        var_name="PORT_$(echo "$svc_name" | tr '[:lower:]-' '[:upper:]_')"
        export "$var_name=$effective_port"
        log_debug "Exported port: $var_name=$effective_port"
    done < <(calculate_worktree_ports "$branch" "$config_file" "$slot")
}

# Get port for a specific service
# If project is provided, checks for port overrides first
get_service_port() {
    local service="$1"
    local branch="$2"
    local config_file="$3"
    local slot="$4"
    local project="${5:-}"

    # Check for port override if project is provided
    if [[ -n "$project" ]]; then
        local override
        override=$(get_port_override "$project" "$branch" "$service")
        if [[ -n "$override" ]]; then
            log_debug "Using port override for $service: $override"
            echo "$override"
            return 0
        fi
    fi

    calculate_worktree_ports "$branch" "$config_file" "$slot" | grep "^$service:" | cut -d: -f2
}

# Slots file path
slots_file() {
    echo "$WT_STATE_DIR/slots.yaml"
}

# Initialize slots file if needed
init_slots_file() {
    local file
    file=$(slots_file)

    if [[ ! -f "$file" ]]; then
        cat > "$file" << 'EOF'
# Slot assignments for reserved ports
# Each slot maps to a set of ports for Privy-dependent services
slots: {}
EOF
    fi
}

# Get slot assignment for a worktree
get_slot_for_worktree() {
    local project="$1"
    local branch="$2"

    local file
    file=$(slots_file)

    if [[ ! -f "$file" ]]; then
        echo ""
        return
    fi

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    yaml_get "$file" ".slots.\"$project\".\"$sanitized\"" ""
}

# Claim a slot for a worktree (with file locking)
# Returns the slot number or fails
claim_slot() {
    local project="$1"
    local branch="$2"
    local max_slots="${3:-3}"

    init_slots_file
    local file
    file=$(slots_file)

    with_file_lock "$file" _claim_slot_locked "$project" "$branch" "$max_slots" "$file"
}

_claim_slot_locked() {
    local project="$1"
    local branch="$2"
    local max_slots="$3"
    local file="$4"

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    # Check if already has a slot
    local existing_slot
    existing_slot=$(yq -r ".slots.\"$project\".\"$sanitized\" // \"\"" "$file" 2>/dev/null)

    if [[ -n "$existing_slot" ]]; then
        echo "$existing_slot"
        return 0
    fi

    # Find available slot
    local used_slots=()
    for ((i = 0; i < max_slots; i++)); do
        used_slots[$i]=0
    done

    # Mark used slots
    local assignments
    assignments=$(yq -r ".slots.\"$project\" // {} | to_entries | .[] | .value" "$file" 2>/dev/null)

    while read -r slot; do
        [[ -z "$slot" ]] && continue
        if [[ "$slot" =~ ^[0-9]+$ ]] && (( slot < max_slots )); then
            used_slots[$slot]=1
        fi
    done <<< "$assignments"

    # Find first available
    for ((i = 0; i < max_slots; i++)); do
        if [[ "${used_slots[$i]}" == "0" ]]; then
            # Claim this slot
            yq -i ".slots.\"$project\".\"$sanitized\" = $i" "$file"
            echo "$i"
            return 0
        fi
    done

    # No slots available
    return 1
}

# Release a slot (with file locking)
release_slot() {
    local project="$1"
    local branch="$2"

    local file
    file=$(slots_file)

    if [[ ! -f "$file" ]]; then
        return
    fi

    with_file_lock "$file" _release_slot_locked "$project" "$branch" "$file"
}

_release_slot_locked() {
    local project="$1"
    local branch="$2"
    local file="$3"

    local sanitized
    sanitized=$(sanitize_branch_name "$branch")

    yq -i "del(.slots.\"$project\".\"$sanitized\")" "$file"
    log_debug "Released slot for $project/$branch"
}

# List all slot assignments for a project
list_slots() {
    local project="$1"

    local file
    file=$(slots_file)

    if [[ ! -f "$file" ]]; then
        return
    fi

    yq -r ".slots.\"$project\" // {} | to_entries | .[] | \"\(.key):\(.value)\"" "$file" 2>/dev/null
}

# Get slot count in use for a project
slots_in_use() {
    local project="$1"

    local file
    file=$(slots_file)

    if [[ ! -f "$file" ]]; then
        echo "0"
        return
    fi

    yq ".slots.\"$project\" // {} | length" "$file" 2>/dev/null || echo "0"
}

# Check if a specific port is available
is_port_available() {
    local port="$1"
    ! port_in_use "$port"
}

# Find an available port in range
find_available_port() {
    local min="$1"
    local max="$2"
    local preferred="${3:-}"

    # Try preferred port first
    if [[ -n "$preferred" ]] && is_port_available "$preferred"; then
        echo "$preferred"
        return 0
    fi

    # Scan range
    for ((port = min; port <= max; port++)); do
        if is_port_available "$port"; then
            echo "$port"
            return 0
        fi
    done

    return 1
}
