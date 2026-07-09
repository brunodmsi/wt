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
    value=$(yq "$path" "$file" 2>/dev/null)

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

# Resolve project: use provided value or auto-detect
# Dies with error if project cannot be determined
# Usage: project=$(require_project "$project" ["custom error message"])
require_project() {
    local project="$1"
    local error_msg="${2:-Could not detect project. Use --project option.}"

    if [[ -z "$project" ]]; then
        project=$(detect_project)
        if [[ -z "$project" ]]; then
            die "$error_msg"
        fi
    fi

    echo "$project"
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

    # Resolve the main repo for any linked worktree (Orca, .worktrees, external
    # tools) via the shared git common dir: dirname(<main>/.git) == <main>.
    # Falls back to the /.worktrees/ strip when git is too old for --path-format.
    local common
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    if [[ -n "$common" ]]; then
        repo_root=$(dirname "$common")
    elif [[ "$repo_root" == *"/.worktrees/"* ]]; then
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

# Resolve a project name from a main-repo path, independent of the CWD.
# Used by `wt claim`/`wt release`, which know the main repo from the worktree's
# git common dir rather than from where the command runs. Matches a config
# whose repo_path equals the path, else falls back to the basename if a config
# by that name exists. Echoes "" when nothing matches.
project_for_repo_path() {
    local main_repo="$1"

    [[ -z "$main_repo" ]] && { echo ""; return 0; }

    # Prefer an exact repo_path match
    local config_file config_repo_path
    for config_file in "$WT_PROJECTS_DIR"/*.yaml; do
        [[ -f "$config_file" ]] || continue

        config_repo_path=$(yaml_get "$config_file" ".repo_path" "")
        config_repo_path=$(expand_path "$config_repo_path")

        if [[ -n "$config_repo_path" ]] && [[ "$config_repo_path" == "$main_repo" ]]; then
            basename "$config_file" .yaml
            return 0
        fi
    done

    # Fall back to the basename if a config by that name exists
    local base
    base=$(basename "$main_repo")
    if has_project_config "$base"; then
        echo "$base"
        return 0
    fi

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
    # shellcheck disable=SC2034  # consumed by command modules that source this file
    PROJECT_CONFIG_FILE="$config_file"

    # Port configuration
    PROJECT_RESERVED_PORT_MIN=$(yaml_get "$config_file" ".ports.reserved.range.min" "3000")
    PROJECT_RESERVED_PORT_MAX=$(yaml_get "$config_file" ".ports.reserved.range.max" "3005")
    PROJECT_RESERVED_SLOTS=$(yaml_get "$config_file" ".ports.reserved.slots" "3")
    PROJECT_DYNAMIC_PORT_MIN=$(yaml_get "$config_file" ".ports.dynamic.range.min" "4000")
    PROJECT_DYNAMIC_PORT_MAX=$(yaml_get "$config_file" ".ports.dynamic.range.max" "5000")

    # Validate port ranges
    if ! [[ "$PROJECT_RESERVED_PORT_MIN" =~ ^[0-9]+$ ]] || ! [[ "$PROJECT_RESERVED_PORT_MAX" =~ ^[0-9]+$ ]]; then
        die "Invalid reserved port range: values must be numbers"
    fi
    if ! [[ "$PROJECT_DYNAMIC_PORT_MIN" =~ ^[0-9]+$ ]] || ! [[ "$PROJECT_DYNAMIC_PORT_MAX" =~ ^[0-9]+$ ]]; then
        die "Invalid dynamic port range: values must be numbers"
    fi
    if (( PROJECT_RESERVED_PORT_MIN >= PROJECT_RESERVED_PORT_MAX )); then
        die "Invalid reserved port range: min ($PROJECT_RESERVED_PORT_MIN) must be less than max ($PROJECT_RESERVED_PORT_MAX)"
    fi
    if (( PROJECT_DYNAMIC_PORT_MIN >= PROJECT_DYNAMIC_PORT_MAX )); then
        die "Invalid dynamic port range: min ($PROJECT_DYNAMIC_PORT_MIN) must be less than max ($PROJECT_DYNAMIC_PORT_MAX)"
    fi
    if (( PROJECT_RESERVED_PORT_MIN < 1 || PROJECT_RESERVED_PORT_MAX > 65535 )); then
        die "Reserved port range out of bounds (must be 1-65535)"
    fi
    if (( PROJECT_DYNAMIC_PORT_MIN < 1 || PROJECT_DYNAMIC_PORT_MAX > 65535 )); then
        die "Dynamic port range out of bounds (must be 1-65535)"
    fi

    # Warn if the configured slot count can't fit within the reserved range.
    # Each slot spans (highest service offset + 1) ports; the highest slot is
    # slots-1, so its top port must stay within the range max. Catches configs
    # where slots are over-provisioned and high slots would overshoot the range.
    local _max_offset
    _max_offset=$(yq -r '.ports.reserved.services // {} | to_entries | map(.value) | max // -1' "$config_file" 2>/dev/null)
    [[ "$_max_offset" =~ ^-?[0-9]+$ ]] || _max_offset=-1
    if (( _max_offset >= 0 )) && [[ "$PROJECT_RESERVED_SLOTS" =~ ^[0-9]+$ ]] && (( PROJECT_RESERVED_SLOTS > 0 )); then
        local _per_slot=$((_max_offset + 1))
        local _top_port=$(( PROJECT_RESERVED_PORT_MIN + (PROJECT_RESERVED_SLOTS - 1) * _per_slot + _max_offset ))
        if (( _top_port > PROJECT_RESERVED_PORT_MAX )); then
            log_warn "Reserved slots ($PROJECT_RESERVED_SLOTS) exceed the port range: highest slot needs port $_top_port but range max is $PROJECT_RESERVED_PORT_MAX. Reduce slots or widen ports.reserved.range."
        fi
    fi

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

# Get environment variables from config
get_env_vars() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        return
    fi

    yq -r '.env // {} | to_entries | .[] | "\(.key)=\(.value)"' "$config_file" 2>/dev/null
}

# Export KEY=VALUE lines with variable expansion via envsubst
# Usage: export_env_string "$key_value_lines"
export_env_string() {
    local key value
    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        value=$(echo "$value" | envsubst 2>/dev/null || echo "$value")
        export "$key=$value"
    done <<< "$1"
}

# Export environment variables from config
export_env_vars() {
    local config_file="$1"
    export_env_string "$(get_env_vars "$config_file")"
}

# Run a hook from config if defined
# Export environment variables before calling this function
# Usage: run_hook <config_file> <hook_name>
run_hook() {
    local config_file="$1"
    local hook_name="$2"

    local hook_cmd
    hook_cmd=$(yaml_get "$config_file" ".hooks.$hook_name" "")

    if [[ -n "$hook_cmd" ]] && [[ "$hook_cmd" != "null" ]]; then
        if ! eval "$hook_cmd"; then
            log_warn "$hook_name hook exited with errors"
        fi
    fi
}

# List all configured projects
list_projects() {
    for config_file in "$WT_PROJECTS_DIR"/*.yaml; do
        [[ -f "$config_file" ]] || continue
        basename "$config_file" .yaml
    done
}
