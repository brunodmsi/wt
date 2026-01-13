#!/bin/bash
# commands/exec.sh - Execute a command in worktree context

cmd_exec() {
    local branch=""
    local project=""
    local cmd_args=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--project)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_exec_help
                return 0
                ;;
            --)
                shift
                cmd_args+=("$@")
                break
                ;;
            -*)
                if [[ -z "$branch" ]]; then
                    log_error "Unknown option: $1"
                    show_exec_help
                    return 1
                fi
                # After branch, all args are part of the command
                cmd_args+=("$1")
                shift
                ;;
            *)
                if [[ -z "$branch" ]]; then
                    branch="$1"
                else
                    cmd_args+=("$1")
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$branch" ]]; then
        log_error "Branch name is required"
        show_exec_help
        return 1
    fi

    if [[ ${#cmd_args[@]} -eq 0 ]]; then
        log_error "Command is required"
        show_exec_help
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

    # Export worktree info
    export WORKTREE_PATH="$wt_path"
    export BRANCH_NAME="$branch"

    # Execute command in worktree directory
    log_debug "Executing in $wt_path: ${cmd_args[*]}"
    (cd "$wt_path" && "${cmd_args[@]}")
}

show_exec_help() {
    cat << 'EOF'
Usage: wt exec <branch> <command...>

Execute a command in the context of a worktree.

The command runs with:
- Working directory set to the worktree path
- PORT variables exported
- Project environment variables set

Arguments:
  <branch>          Branch name of the worktree
  <command...>      Command and arguments to execute

Options:
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt exec feature/auth npm test
  wt exec feature/auth git status
  wt exec feature/auth -- npm run build
EOF
}
