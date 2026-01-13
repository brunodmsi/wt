#!/bin/bash
# lib/setup.sh - Setup step executor with dependency resolution

# Execute all setup steps for a worktree
execute_setup() {
    local worktree_path="$1"
    local config_file="$2"
    local step_filter="${3:-}"  # Optional: run only specific step

    local step_count
    step_count=$(get_setup_steps "$config_file")

    if [[ "$step_count" -eq 0 ]]; then
        log_info "No setup steps configured"
        return 0
    fi

    log_info "Running setup with $step_count steps..."

    local completed=()
    local failed=()
    local skipped=()

    for ((i = 0; i < step_count; i++)); do
        local step_name
        step_name=$(get_setup_step "$config_file" "$i" "name")

        local step_desc
        step_desc=$(get_setup_step "$config_file" "$i" "description")
        step_desc="${step_desc:-$step_name}"

        local step_cmd
        step_cmd=$(get_setup_step "$config_file" "$i" "command")

        local step_dir
        step_dir=$(get_setup_step "$config_file" "$i" "working_dir")
        step_dir="${step_dir:-.}"

        local on_failure
        on_failure=$(get_setup_step "$config_file" "$i" "on_failure")
        on_failure="${on_failure:-abort}"

        local condition
        condition=$(get_setup_step "$config_file" "$i" "condition")

        # Skip if filter provided and doesn't match
        if [[ -n "$step_filter" ]] && [[ "$step_name" != "$step_filter" ]]; then
            continue
        fi

        # Check dependencies
        local deps_met=true
        local deps
        deps=$(yq -r ".setup[$i].depends_on // [] | .[]" "$config_file" 2>/dev/null)

        while read -r dep; do
            [[ -z "$dep" ]] && continue
            local found=false
            for c in "${completed[@]}"; do
                if [[ "$c" == "$dep" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == "false" ]]; then
                log_warn "Dependency not met for '$step_name': $dep"
                deps_met=false
                break
            fi
        done <<< "$deps"

        if [[ "$deps_met" == "false" ]]; then
            log_error "Skipping '$step_name' - dependencies not met"
            skipped+=("$step_name")
            continue
        fi

        # Check condition
        if [[ -n "$condition" ]] && [[ "$condition" != "null" ]]; then
            if ! (cd "$worktree_path" && eval "$condition" &>/dev/null); then
                log_info "Skipping '$step_name' - condition not met"
                skipped+=("$step_name")
                continue
            fi
        fi

        log_step "$((i + 1))" "$step_count" "$step_desc"

        # Load step-specific environment
        local step_env
        step_env=$(yq -r ".setup[$i].env // {} | to_entries | .[] | \"\(.key)=\(.value)\"" "$config_file" 2>/dev/null)

        # Export step environment
        while IFS='=' read -r key value; do
            [[ -z "$key" ]] && continue
            value=$(eval echo "$value" 2>/dev/null || echo "$value")
            export "$key=$value"
        done <<< "$step_env"

        # Execute command
        local exec_dir="$worktree_path/$step_dir"
        local exit_code=0

        if [[ ! -d "$exec_dir" ]]; then
            log_warn "Directory not found: $exec_dir"
            exit_code=1
        else
            (cd "$exec_dir" && eval "$step_cmd")
            exit_code=$?
        fi

        if [[ $exit_code -eq 0 ]]; then
            completed+=("$step_name")
            log_success "Completed: $step_name"
        else
            failed+=("$step_name")
            log_error "Failed: $step_name (exit code: $exit_code)"

            case "$on_failure" in
                abort)
                    log_error "Aborting setup due to failure"
                    return 1
                    ;;
                continue)
                    log_warn "Continuing despite failure"
                    ;;
                retry)
                    log_info "Retrying '$step_name'..."
                    if (cd "$exec_dir" && eval "$step_cmd"); then
                        # Remove from failed, add to completed
                        failed=("${failed[@]/$step_name}")
                        completed+=("$step_name")
                        log_success "Retry succeeded: $step_name"
                    else
                        log_error "Retry failed: $step_name"
                        return 1
                    fi
                    ;;
            esac
        fi
    done

    echo ""
    log_info "Setup summary:"
    log_info "  Completed: ${#completed[@]}"
    [[ ${#skipped[@]} -gt 0 ]] && log_info "  Skipped: ${#skipped[@]}"
    [[ ${#failed[@]} -gt 0 ]] && log_warn "  Failed: ${#failed[@]}"

    if [[ ${#failed[@]} -gt 0 ]]; then
        return 1
    fi

    return 0
}

# Run a single setup step by name
run_setup_step() {
    local worktree_path="$1"
    local config_file="$2"
    local step_name="$3"

    local step_count
    step_count=$(get_setup_steps "$config_file")

    for ((i = 0; i < step_count; i++)); do
        local name
        name=$(get_setup_step "$config_file" "$i" "name")

        if [[ "$name" == "$step_name" ]]; then
            local step_desc
            step_desc=$(get_setup_step "$config_file" "$i" "description")

            local step_cmd
            step_cmd=$(get_setup_step "$config_file" "$i" "command")

            local step_dir
            step_dir=$(get_setup_step "$config_file" "$i" "working_dir")
            step_dir="${step_dir:-.}"

            log_info "Running: $step_desc"

            local exec_dir="$worktree_path/$step_dir"

            if [[ ! -d "$exec_dir" ]]; then
                log_error "Directory not found: $exec_dir"
                return 1
            fi

            # Load step environment
            local step_env
            step_env=$(yq -r ".setup[$i].env // {} | to_entries | .[] | \"\(.key)=\(.value)\"" "$config_file" 2>/dev/null)

            while IFS='=' read -r key value; do
                [[ -z "$key" ]] && continue
                value=$(eval echo "$value" 2>/dev/null || echo "$value")
                export "$key=$value"
            done <<< "$step_env"

            (cd "$exec_dir" && eval "$step_cmd")
            return $?
        fi
    done

    log_error "Setup step not found: $step_name"
    return 1
}

# List all setup steps
list_setup_steps() {
    local config_file="$1"

    local step_count
    step_count=$(get_setup_steps "$config_file")

    echo "Setup steps:"
    for ((i = 0; i < step_count; i++)); do
        local name
        name=$(get_setup_step "$config_file" "$i" "name")

        local desc
        desc=$(get_setup_step "$config_file" "$i" "description")

        local deps
        deps=$(yq -r ".setup[$i].depends_on // [] | join(\", \")" "$config_file" 2>/dev/null)

        printf "  %d. ${BOLD}%s${NC}" "$((i + 1))" "$name"
        [[ -n "$desc" ]] && printf " - %s" "$desc"
        [[ -n "$deps" ]] && printf " ${DIM}(depends: %s)${NC}" "$deps"
        echo ""
    done
}

# Validate setup configuration
validate_setup_config() {
    local config_file="$1"

    local step_count
    step_count=$(get_setup_steps "$config_file")

    local errors=0

    for ((i = 0; i < step_count; i++)); do
        local name
        name=$(get_setup_step "$config_file" "$i" "name")

        local cmd
        cmd=$(get_setup_step "$config_file" "$i" "command")

        if [[ -z "$name" ]] || [[ "$name" == "null" ]]; then
            log_error "Setup step $i: missing 'name'"
            ((errors++))
        fi

        if [[ -z "$cmd" ]] || [[ "$cmd" == "null" ]]; then
            log_error "Setup step $i ($name): missing 'command'"
            ((errors++))
        fi

        # Check dependencies exist
        local deps
        deps=$(yq -r ".setup[$i].depends_on // [] | .[]" "$config_file" 2>/dev/null)

        while read -r dep; do
            [[ -z "$dep" ]] && continue
            local found=false
            for ((j = 0; j < i; j++)); do
                local other_name
                other_name=$(get_setup_step "$config_file" "$j" "name")
                if [[ "$other_name" == "$dep" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == "false" ]]; then
                log_error "Setup step '$name': dependency '$dep' not found or defined after this step"
                ((errors++))
            fi
        done <<< "$deps"
    done

    return $errors
}
