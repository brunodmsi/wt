#!/bin/bash
# lib/config.sh - Configuration loading and YAML parsing

# Configuration directories
WT_CONFIG_DIR="${WT_CONFIG_DIR:-$HOME/.config/wt}"
WT_PROJECTS_DIR="$WT_CONFIG_DIR/projects"
WT_DATA_DIR="${WT_DATA_DIR:-$HOME/.local/share/wt}"
WT_STATE_DIR="$WT_DATA_DIR/state"
WT_LOG_DIR="$WT_DATA_DIR/logs"

# Ensure yq is available
ensure_yq() {
    if ! command_exists yq; then
        die "yq is required but not installed. Install with: brew install yq"
    fi
}

# Initialize config directories
init_config_dirs() {
    ensure_dir "$WT_CONFIG_DIR"
    ensure_dir "$WT_PROJECTS_DIR"
    ensure_dir "$WT_DATA_DIR"
    ensure_dir "$WT_STATE_DIR"
    ensure_dir "$WT_LOG_DIR"
}

# Get global config path
global_config_path() {
    echo "$WT_CONFIG_DIR/config.yaml"
}

# Get project config path
project_config_path() {
    local project="$1"
    echo "$WT_PROJECTS_DIR/${project}.yaml"
}

# Check if global config exists
has_global_config() {
    [[ -f "$(global_config_path)" ]]
}

# Check if project config exists
has_project_config() {
    local project="$1"
    [[ -f "$(project_config_path "$project")" ]]
}

# Load a YAML value with yq
# Usage: yaml_get "file.yaml" ".path.to.value"
yaml_get() {
    local file="$1"
    local path="$2"
    local default="${3:-}"

    if [[ ! -f "$file" ]]; then
        echo "$default"
        return
    fi

    local value
    value=$(yq -e "$path" "$file" 2>/dev/null)

    if [[ $? -ne 0 ]] || [[ "$value" == "null" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# Load a YAML array as bash array
# Usage: yaml_array "file.yaml" ".path.to.array"
yaml_array() {
    local file="$1"
    local path="$2"

    if [[ ! -f "$file" ]]; then
        return
    fi

    yq -r "$path // [] | .[]" "$file" 2>/dev/null
}

# Get length of YAML array
yaml_array_length() {
    local file="$1"
    local path="$2"

    if [[ ! -f "$file" ]]; then
        echo "0"
        return
    fi

    yq "$path | length" "$file" 2>/dev/null || echo "0"
}

# Set a YAML value
# Usage: yaml_set "file.yaml" ".path.to.value" "new_value"
yaml_set() {
    local file="$1"
    local path="$2"
    local value="$3"

    # Create file if it doesn't exist
    if [[ ! -f "$file" ]]; then
        echo "{}" > "$file"
    fi

    yq -i "$path = \"$value\"" "$file"
}

# Set a YAML value (numeric)
yaml_set_num() {
    local file="$1"
    local path="$2"
    local value="$3"

    if [[ ! -f "$file" ]]; then
        echo "{}" > "$file"
    fi

    yq -i "$path = $value" "$file"
}

# Delete a YAML path
yaml_delete() {
    local file="$1"
    local path="$2"

    if [[ -f "$file" ]]; then
        yq -i "del($path)" "$file"
    fi
}

# Detect project from current directory
# Returns empty string if not in a project (does not return error code to avoid set -e issues)
detect_project() {
    if ! is_git_repo 2>/dev/null; then
        echo ""
        return 0
    fi

    local repo_root
    repo_root=$(git_root 2>/dev/null) || { echo ""; return 0; }

    # If we're inside a worktree, get the main repo path
    if [[ "$repo_root" == *"/.worktrees/"* ]]; then
        repo_root="${repo_root%/.worktrees/*}"
    fi

    local project_name
    project_name=$(basename "$repo_root")

    # Check if we have a config for this project
    if has_project_config "$project_name"; then
        echo "$project_name"
        return 0
    fi

    # Check all project configs for matching repo_path
    for config_file in "$WT_PROJECTS_DIR"/*.yaml; do
        [[ -f "$config_file" ]] || continue

        local config_repo_path
        config_repo_path=$(yaml_get "$config_file" ".repo_path" "")
        config_repo_path=$(expand_path "$config_repo_path")

        if [[ "$config_repo_path" == "$repo_root" ]]; then
            basename "$config_file" .yaml
            return 0
        fi
    done

    echo ""
    return 0
}

# Load project configuration
# Sets PROJECT_* variables
load_project_config() {
    local project="$1"

    if ! has_project_config "$project"; then
        die "No configuration found for project: $project"
    fi

    local config_file
    config_file=$(project_config_path "$project")

    PROJECT_NAME=$(yaml_get "$config_file" ".name" "$project")
    PROJECT_REPO_PATH=$(yaml_get "$config_file" ".repo_path")
    PROJECT_REPO_PATH=$(expand_path "$PROJECT_REPO_PATH")
    PROJECT_CONFIG_FILE="$config_file"

    # Port configuration
    PROJECT_RESERVED_PORT_MIN=$(yaml_get "$config_file" ".ports.reserved.range.min" "3000")
    PROJECT_RESERVED_PORT_MAX=$(yaml_get "$config_file" ".ports.reserved.range.max" "3005")
    PROJECT_RESERVED_SLOTS=$(yaml_get "$config_file" ".ports.reserved.slots" "3")
    PROJECT_DYNAMIC_PORT_MIN=$(yaml_get "$config_file" ".ports.dynamic.range.min" "4000")
    PROJECT_DYNAMIC_PORT_MAX=$(yaml_get "$config_file" ".ports.dynamic.range.max" "5000")

    log_debug "Loaded config for project: $PROJECT_NAME"
    log_debug "  Repo path: $PROJECT_REPO_PATH"
    log_debug "  Reserved ports: $PROJECT_RESERVED_PORT_MIN-$PROJECT_RESERVED_PORT_MAX"
    log_debug "  Dynamic ports: $PROJECT_DYNAMIC_PORT_MIN-$PROJECT_DYNAMIC_PORT_MAX"
}

# Get setup steps from config
get_setup_steps() {
    local config_file="$1"
    yaml_array_length "$config_file" ".setup"
}

# Get setup step by index
get_setup_step() {
    local config_file="$1"
    local index="$2"
    local field="$3"

    yaml_get "$config_file" ".setup[$index].$field"
}

# Get services from config
get_services() {
    local config_file="$1"
    yaml_array_length "$config_file" ".services"
}

# Get service by name
get_service_config() {
    local config_file="$1"
    local service_name="$2"
    local field="$3"

    yq ".services[] | select(.name == \"$service_name\") | .$field" "$config_file" 2>/dev/null
}

# Get service by index
get_service_by_index() {
    local config_file="$1"
    local index="$2"
    local field="$3"

    yaml_get "$config_file" ".services[$index].$field"
}

# Get reserved service offset
get_reserved_service_offset() {
    local config_file="$1"
    local service_name="$2"

    yaml_get "$config_file" ".ports.reserved.services.$service_name" ""
}

# Check if service uses dynamic port
is_dynamic_service() {
    local config_file="$1"
    local service_name="$2"

    local result
    result=$(yaml_get "$config_file" ".ports.dynamic.services.$service_name" "")
    [[ -n "$result" ]]
}

# Get environment variables from config
get_env_vars() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        return
    fi

    yq -r '.env // {} | to_entries | .[] | "\(.key)=\(.value)"' "$config_file" 2>/dev/null
}

# Export environment variables from config
export_env_vars() {
    local config_file="$1"

    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        # Expand any variables in value
        value=$(eval echo "$value" 2>/dev/null || echo "$value")
        export "$key=$value"
        log_debug "Exported env: $key=$value"
    done < <(get_env_vars "$config_file")
}

# List all configured projects
list_projects() {
    for config_file in "$WT_PROJECTS_DIR"/*.yaml; do
        [[ -f "$config_file" ]] || continue
        basename "$config_file" .yaml
    done
}
