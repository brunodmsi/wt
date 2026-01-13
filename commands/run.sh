#!/bin/bash
# commands/run.sh - Run a specific setup step

cmd_run() {
    local branch=""
    local step_name=""
    local project=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_run_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_run_help
                return 1
                ;;
            *)
                if [[ -z "$branch" ]]; then
                    branch="$1"
                elif [[ -z "$step_name" ]]; then
                    step_name="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$branch" ]]; then
        log_error "Branch name is required"
        show_run_help
        return 1
    fi

    if [[ -z "$step_name" ]]; then
        log_error "Step name is required"
        show_run_help
        return 1
    fi

    # Detect or validate project
    if [[ -z "$project" ]]; then
        project=$(detect_project)
        if [[ -z "$project" ]]; then
            die "Could not detect project. Use --project option."
        fi
    fi

    # Load project configuration
    load_project_config "$project"

    # Verify worktree exists
    if ! worktree_exists "$branch" "$PROJECT_REPO_PATH"; then
        die "Worktree not found for branch: $branch"
    fi

    local wt_path
    wt_path=$(get_worktree_path "$project" "$branch")

    # Get slot and export port variables
    local slot
    slot=$(get_worktree_slot "$project" "$branch")
    export_port_vars "$branch" "$PROJECT_CONFIG_FILE" "$slot"
    export_env_vars "$PROJECT_CONFIG_FILE"

    # Run the step
    run_setup_step "$wt_path" "$PROJECT_CONFIG_FILE" "$step_name"
}

show_run_help() {
    cat << 'EOF'
Usage: wt run <branch> <step-name>

Run a specific setup step in a worktree.

Arguments:
  <branch>          Branch name of the worktree
  <step-name>       Name of the setup step to run

Options:
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

To see available steps, check your project configuration.

Examples:
  wt run feature/auth init-submodules
  wt run feature/auth install-deps-app
EOF
}
