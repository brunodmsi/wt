#!/bin/bash
# commands/release.sh - Release a claimed worktree (drop state + slot, keep dir)

cmd_release() {
    local wt_path=""
    local branch=""
    local project=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --branch)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                branch="$2"
                shift 2
                ;;
            -p|--project)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_release_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_release_help
                return 1
                ;;
            *)
                if [[ -z "$wt_path" ]]; then
                    wt_path="$1"
                fi
                shift
                ;;
        esac
    done

    [[ -z "$wt_path" ]] && wt_path="$PWD"

    # 1. Resolve main_repo / branch from the worktree when it still exists.
    # release may run after the directory is gone — then fall back to
    # --branch/--project.
    local main_repo=""
    if [[ -d "$wt_path" ]] && git -C "$wt_path" rev-parse --is-inside-work-tree &>/dev/null; then
        wt_path=$(cd "$wt_path" && pwd -P)
        main_repo=$(main_repo_from_path "$wt_path" 2>/dev/null || true)
        [[ -z "$branch" ]] && branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    fi

    # Resolve the project (explicit --project, else from the main repo path)
    if [[ -z "$project" ]] && [[ -n "$main_repo" ]]; then
        project=$(project_for_repo_path "$main_repo")
    fi
    if [[ -z "$project" ]]; then
        die "Could not detect project. Use --project (the worktree directory may already be gone)."
    fi
    load_project_config "$project"

    if [[ -z "$branch" ]] || [[ "$branch" == "HEAD" ]]; then
        die "Could not determine branch. Specify one with --branch."
    fi

    # 2. Idempotent: nothing to release if there's no state
    if ! worktree_state_exists "$project" "$branch"; then
        log_warn "No claimed worktree state for branch: $branch (nothing to release)"
        return 0
    fi

    # Capture the recorded path before deleting state, for the post_delete hook
    local state_path
    state_path=$(get_worktree_path "$project" "$branch")

    # 3. Stop services and close the multiplexer's window/tab
    log_info "Stopping services..."
    stop_all_services "$project" "$branch" "$PROJECT_CONFIG_FILE" 2>/dev/null || true

    local window_name
    window_name=$(get_session_name "$project" "$branch")
    multiplexer_close_tab "$window_name" "$PROJECT_CONFIG_FILE"

    # Remove service log files for this worktree
    local sanitized_branch
    sanitized_branch=$(sanitize_branch_name "$branch")
    local log_dir="$WT_LOG_DIR/${project}/${sanitized_branch}"
    if [[ -d "$log_dir" ]]; then
        rm -rf "$log_dir"
        log_info "Removed log files"
    fi

    # 4. Release the slot and delete state. NEVER remove the worktree directory
    # — the external tool that created it (e.g. Orca) owns it.
    release_slot "$project" "$branch"
    delete_worktree_state "$project" "$branch"

    # 5. Run post_delete hook if defined
    export WORKTREE_PATH="${state_path:-$wt_path}"
    export BRANCH_NAME="$branch"
    run_hook "$PROJECT_CONFIG_FILE" "post_delete"

    log_success "Released worktree: $branch (directory left intact)"
}

show_release_help() {
    cat << 'EOF'
Usage: wt release [path] [options]      (alias: unclaim)

Release a claimed worktree from wt: stop its services, drop its state and port
slot. Does NOT run `git worktree remove` — the external tool that created the
worktree (e.g. Orca) owns the directory.

Arguments:
  [path]            Path to the worktree (default: current directory)

Options:
  --branch <name>   Override branch detection (required if the dir is gone)
  -p, --project     Override project detection (required if the dir is gone)
  -h, --help        Show this help message

Examples:
  wt release                                  # release the worktree in $PWD
  wt release ~/orca/workspaces/app/feature    # release a specific path
  wt release "$ORCA_WORKTREE_PATH"            # Orca archive hook
  wt release --branch feat -p app             # after the dir was removed
EOF
}
