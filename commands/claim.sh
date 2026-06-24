#!/bin/bash
# commands/claim.sh - Adopt an externally-created worktree into wt

cmd_claim() {
    local wt_path=""
    local branch=""
    local project=""
    local no_setup=0
    local force=0

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
            --no-setup)
                no_setup=1
                shift
                ;;
            --force)
                force=1
                shift
                ;;
            -h|--help)
                show_claim_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_claim_help
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

    # 1. Resolve the worktree path (arg or $PWD), make absolute, verify it's a worktree
    [[ -z "$wt_path" ]] && wt_path="$PWD"
    if [[ ! -d "$wt_path" ]]; then
        die "Path does not exist: $wt_path"
    fi
    wt_path=$(cd "$wt_path" && pwd -P) || die "Cannot resolve path: $wt_path"
    if ! git -C "$wt_path" rev-parse --is-inside-work-tree &>/dev/null; then
        die "Not a git worktree: $wt_path"
    fi

    # 2. Resolve the main repo via the shared git common dir
    local main_repo
    if ! main_repo=$(main_repo_from_path "$wt_path"); then
        die "Could not resolve the main repository for: $wt_path"
    fi

    # 3. Resolve the project (do not rely on CWD — use the resolved main repo)
    if [[ -z "$project" ]]; then
        project=$(project_for_repo_path "$main_repo")
    fi
    if [[ -z "$project" ]]; then
        die "Could not detect project for repo: $main_repo. Use --project or run 'wt init' first."
    fi
    load_project_config "$project"

    # 4. Resolve the branch (--branch or git HEAD)
    if [[ -z "$branch" ]]; then
        branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    fi
    if [[ -z "$branch" ]] || [[ "$branch" == "HEAD" ]]; then
        die "Could not determine branch (detached HEAD?). Specify one with --branch."
    fi

    # 5. Idempotency / guards
    if worktree_state_exists "$project" "$branch"; then
        local existing_path
        existing_path=$(get_worktree_path "$project" "$branch")

        if [[ "$existing_path" == "$wt_path" ]]; then
            # Already claimed at this path — re-run setup (unless --no-setup) and exit.
            log_info "Branch '$branch' is already claimed at this path."
            export BRANCH_NAME="$branch"
            export WORKTREE_PATH="$wt_path"
            export MAIN_REPO="$main_repo"

            local existing_slot
            existing_slot=$(get_worktree_slot "$project" "$branch")
            export_port_vars "$branch" "$PROJECT_CONFIG_FILE" "$existing_slot" "$project"
            export_env_vars "$PROJECT_CONFIG_FILE"

            if [[ "$no_setup" -eq 0 ]]; then
                echo ""
                execute_setup "$wt_path" "$PROJECT_CONFIG_FILE" || log_warn "Setup completed with errors"
            else
                log_info "Skipping setup (--no-setup)"
            fi

            log_success "Re-claimed worktree: $branch"
            return 0
        elif [[ "$force" -eq 0 ]]; then
            die "Branch '$branch' is already claimed at a different path: $existing_path. Use --force to re-claim at $wt_path."
        else
            log_warn "Re-claiming '$branch' from $existing_path to $wt_path (--force)"
        fi
    fi

    # Run pre_create hook (matches create's lifecycle). The worktree already
    # exists, so WORKTREE_PATH/MAIN_REPO are available up front.
    export BRANCH_NAME="$branch"
    export WORKTREE_PATH="$wt_path"
    export MAIN_REPO="$main_repo"
    run_hook "$PROJECT_CONFIG_FILE" "pre_create"

    # Track state for cleanup on interrupt: if we claim a slot then fail before
    # writing state, release it (mirrors create's trap).
    local _claim_cleanup_project=""
    local _claim_cleanup_branch=""
    local _claim_cleanup_slot=""

    _claim_cleanup() {
        if [[ -n "$_claim_cleanup_slot" ]]; then
            log_warn "Interrupted — cleaning up partial state..."
            release_slot "$_claim_cleanup_project" "$_claim_cleanup_branch" 2>/dev/null || true
            delete_worktree_state "$_claim_cleanup_project" "$_claim_cleanup_branch" 2>/dev/null || true
        fi
    }
    trap _claim_cleanup INT TERM

    # 6. Claim a slot for reserved ports
    local slot
    if ! slot=$(claim_slot "$project" "$branch" "$PROJECT_RESERVED_SLOTS"); then
        die "No available slots. Maximum $PROJECT_RESERVED_SLOTS concurrent worktrees with reserved ports. Stop or delete an existing worktree first."
    fi
    _claim_cleanup_project="$project"
    _claim_cleanup_branch="$branch"
    _claim_cleanup_slot="$slot"

    log_info "Claimed slot $slot for worktree"

    # 7. Store state (record the real path; flag it as claimed for display)
    create_worktree_state "$project" "$branch" "$wt_path" "$slot"
    set_worktree_state "$project" "$branch" "source" "claimed"

    # 8. Export port + env variables for setup
    export_port_vars "$branch" "$PROJECT_CONFIG_FILE" "$slot" "$project"
    export_env_vars "$PROJECT_CONFIG_FILE"

    # State written — disable the cleanup trap
    _claim_cleanup_slot=""
    trap - INT TERM

    # 10. Run setup steps (non-fatal summary, matches create). Do NOT open
    # tmux / attach — Orca owns the terminal.
    local setup_failed=0
    if [[ "$no_setup" -eq 0 ]]; then
        echo ""
        if ! execute_setup "$wt_path" "$PROJECT_CONFIG_FILE"; then
            log_warn "Setup completed with errors"
            setup_failed=1
        fi
    else
        log_info "Skipping setup (--no-setup)"
    fi

    # 11. Run post_create hook if defined
    run_hook "$PROJECT_CONFIG_FILE" "post_create"

    echo ""
    if [[ "$setup_failed" -eq 1 ]]; then
        log_warn "Worktree claimed but setup had errors. You may need to run setup manually."
    else
        log_success "Worktree claimed!"
    fi
    echo ""
    print_kv "Branch" "$branch"
    print_kv "Path" "$wt_path"
    print_kv "Slot" "$slot"
    print_kv "Project" "$project"
    echo ""
    echo "Next steps:"
    echo "  wt start $branch --all    # Start all services"
    echo "  wt attach $branch         # Attach to tmux"
}

show_claim_help() {
    cat << 'EOF'
Usage: wt claim [path] [options]

Adopt an existing git worktree (created by Orca or any external tool) into wt:
register state, claim a port slot, and run the project's setup steps. After
claiming, all wt commands operate on the worktree as if `wt create` had made it.

Arguments:
  [path]            Path to the existing worktree (default: current directory)

Options:
  --branch <name>   Override branch detection (default: git HEAD of the path)
  -p, --project     Override project detection
  --no-setup        Register state + slot only; skip setup steps
  --force           Re-claim even if the branch is already claimed elsewhere
  -h, --help        Show this help message

Examples:
  wt claim                                  # claim the worktree in $PWD
  wt claim ~/orca/workspaces/app/feature    # claim a specific path
  wt claim "$ORCA_WORKTREE_PATH"            # Orca setup hook
  wt claim . --no-setup                     # register state only
EOF
}
