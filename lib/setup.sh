#!/bin/bash
# lib/setup.sh - Setup step executor with dependency resolution

# Execute all setup steps for a worktree
execute_setup() {
    local worktree_path="$1"
    local config_file="$2"
    local step_filter="${3:-}"  # Optional: run only a specific step (by name)
    local phase_filter="${4:-}" # Optional: run only steps whose `phase` matches
                                # (used by `wt repair` to run just the safe,
                                # idempotent provisioning steps)

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

        local step_phase
        step_phase=$(get_setup_step "$config_file" "$i" "phase")

        # Skip if step filter provided and doesn't match
        if [[ -n "$step_filter" ]] && [[ "$step_name" != "$step_filter" ]]; then
            continue
        fi

        # Skip if phase filter provided and this step isn't in that phase
        if [[ -n "$phase_filter" ]] && [[ "$step_phase" != "$phase_filter" ]]; then
            continue
        fi

        # Check dependencies. Skipped under a phase filter: a phase-filtered run
        # (e.g. `wt repair`) deliberately runs a subset, so depends_on targets in
        # other phases won't be in `completed` and would spuriously gate the step.
        # Phase steps are expected to be self-contained (see docs: `phase`).
        if [[ -z "$phase_filter" ]]; then
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
        fi

        # Check condition (restricted to test/file-check commands)
        if [[ -n "$condition" ]] && [[ "$condition" != "null" ]]; then
            if [[ "$condition" =~ ^(test |!\ test |\[|\[\[) ]]; then
                if ! (cd "$worktree_path" && eval "$condition" &>/dev/null); then
                    log_info "Skipping '$step_name' - condition not met"
                    skipped+=("$step_name")
                    continue
                fi
            else
                log_warn "Skipping unsafe condition for '$step_name': only test/[ expressions are allowed"
                skipped+=("$step_name")
                continue
            fi
        fi

        log_step "$((i + 1))" "$step_count" "$step_desc"

        # Load step-specific environment
        local step_env
        step_env=$(yq -r ".setup[$i].env // {} | to_entries | .[] | \"\(.key)=\(.value)\"" "$config_file" 2>/dev/null)

        # Export step environment
        export_env_string "$step_env"

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

            export_env_string "$step_env"

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
            errors=$((errors + 1))
        fi

        if [[ -z "$cmd" ]] || [[ "$cmd" == "null" ]]; then
            log_error "Setup step $i ($name): missing 'command'"
            errors=$((errors + 1))
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
                errors=$((errors + 1))
            fi
        done <<< "$deps"
    done

    return $errors
}

# Read the declared required-artifact paths for a project.
# These live under a top-level `setup_requires:` list (a sibling of the
# `setup:` step list, which is a YAML sequence and therefore can't nest a
# `.requires` key). Each entry is a path relative to the worktree root.
# Emits one path per line; nothing when none are declared.
get_setup_requires() {
    local config_file="$1"
    [[ -f "$config_file" ]] || return 0
    yq -r '.setup_requires // [] | .[]' "$config_file" 2>/dev/null
}

# Verify a worktree contains every declared setup artifact.
# Echoes each MISSING path (relative, one per line) to stdout and returns 1 if
# any are missing; returns 0 when all present or none are declared. This catches
# both aborted setup (the artifact-producing step never ran) and silent no-ops
# (a step "succeeded" but didn't actually create the file).
setup_requires_missing() {
    local worktree_path="$1"
    local config_file="$2"
    local rel
    local missing=0

    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        if [[ ! -e "$worktree_path/$rel" ]]; then
            echo "$rel"
            missing=1
        fi
    done < <(get_setup_requires "$config_file")

    return $missing
}

# Record a worktree's provisioning outcome and report whether it is incomplete.
# A worktree is "ok" only when the setup steps succeeded (setup_rc == 0) AND
# every declared setup_requires artifact is present; otherwise it is flagged
# "incomplete" so `wt start` refuses to launch it and `wt repair` can fix it.
# Missing artifacts are logged. Writes the `provisioned` state key.
#
# Usage: finalize_provisioning <project> <branch> <worktree_path> <config> <setup_rc>
# Returns 0 when provisioned ok, 1 when incomplete.
finalize_provisioning() {
    local project="$1"
    local branch="$2"
    local worktree_path="$3"
    local config_file="$4"
    local setup_rc="${5:-0}"

    local missing
    missing=$(setup_requires_missing "$worktree_path" "$config_file")
    local artifacts_ok=$?

    if [[ "$setup_rc" -eq 0 ]] && [[ "$artifacts_ok" -eq 0 ]]; then
        set_worktree_state "$project" "$branch" "provisioned" "ok"
        return 0
    fi

    if [[ -n "$missing" ]]; then
        log_error "Setup did not produce required files:"
        local rel
        while IFS= read -r rel; do
            [[ -z "$rel" ]] && continue
            log_error "  $rel"
        done <<< "$missing"
    fi

    set_worktree_state "$project" "$branch" "provisioned" "incomplete"
    return 1
}

# Preflight guard for `wt start`: refuse to launch a worktree whose setup never
# completed. When the project declares setup_requires, the artifacts are the
# source of truth — this also catches a file deleted after a clean provision.
# Otherwise fall back to the recorded `provisioned` state key. An unset key
# (worktrees from before this feature, or `--no-setup` with nothing declared)
# is treated as OK so existing worktrees keep starting.
#
# Usage: assert_provisioned <project> <branch> <worktree_path> <config>
# Returns 0 when OK to start; logs what's wrong and returns 1 when incomplete.
assert_provisioned() {
    local project="$1"
    local branch="$2"
    local worktree_path="$3"
    local config_file="$4"

    local requires
    requires=$(get_setup_requires "$config_file")

    if [[ -n "$requires" ]]; then
        local missing
        missing=$(setup_requires_missing "$worktree_path" "$config_file")
        [[ -z "$missing" ]] && return 0
        log_error "Worktree '$branch' is missing required setup files:"
        local rel
        while IFS= read -r rel; do
            [[ -z "$rel" ]] && continue
            log_error "  $rel"
        done <<< "$missing"
        return 1
    fi

    # No declared artifacts — consult the recorded provisioning status.
    local provisioned
    provisioned=$(get_worktree_state "$project" "$branch" "provisioned")
    if [[ "$provisioned" == "incomplete" ]]; then
        log_error "Worktree '$branch' was flagged as incompletely provisioned."
        return 1
    fi

    return 0
}
