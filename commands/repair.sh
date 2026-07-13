#!/bin/bash
# commands/repair.sh - Safely re-provision a registered worktree

cmd_repair() {
    local branch=""
    local project=""
    local -a positionals=()

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
                show_repair_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_repair_help
                return 1
                ;;
            *)
                positionals+=("$1")
                shift
                ;;
        esac
    done

    # Resolve branch: --branch, else first positional, else auto-detect from CWD
    if [[ -z "$branch" ]]; then
        if [[ ${#positionals[@]} -gt 0 ]]; then
            branch="${positionals[0]}"
        else
            branch=$(detect_worktree_branch)
        fi
    fi
    if [[ -z "$branch" ]]; then
        log_error "Branch name is required (not in a worktree)"
        show_repair_help
        return 1
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    # Repair operates on an already-registered worktree — it never creates state
    # or claims a slot. Same state-authoritative rule as claim/release.
    if ! worktree_state_exists "$project" "$branch"; then
        die "No registered worktree for branch '$branch'. Adopt it first with '${WT_CMD} claim'."
    fi
    if ! worktree_dir_exists "$project" "$branch" "$PROJECT_REPO_PATH"; then
        die "Worktree directory not found for branch: $branch"
    fi

    local wt_path
    wt_path=$(get_worktree_path "$project" "$branch")

    local slot
    slot=$(get_worktree_slot "$project" "$branch")
    if [[ -z "$slot" ]]; then
        die "Could not find slot for worktree. State may be corrupted."
    fi

    # Re-export port + env vars for the recorded slot. Reuses export_port_vars
    # against the state-recorded slot, so it works for claimed worktrees whose
    # paths aren't derived from the convention.
    export_port_vars "$branch" "$PROJECT_CONFIG_FILE" "$slot" "$project"
    export_env_vars "$PROJECT_CONFIG_FILE"

    # Provisioning steps reference these (same set that setup exports).
    export BRANCH_NAME="$branch"
    export WORKTREE_PATH="$wt_path"
    local main_repo
    main_repo=$(main_repo_from_path "$wt_path" 2>/dev/null) || main_repo="$PROJECT_REPO_PATH"
    export MAIN_REPO="$main_repo"

    log_info "Repairing '$branch' — re-running only safe provisioning steps (phase: provision)."
    log_info "Submodule branches, node_modules, and dependency installs are left untouched."

    # Run ONLY the provision-phase steps: the safe, idempotent subset (env/config
    # copies + port stamping). The phase filter guarantees branch-moving and
    # dep-installing steps never run under repair.
    local setup_rc=0
    echo ""
    execute_setup "$wt_path" "$PROJECT_CONFIG_FILE" "" "provision" || setup_rc=1

    # Re-verify declared artifacts and update the provisioned state key.
    local setup_failed=0
    finalize_provisioning "$project" "$branch" "$wt_path" "$PROJECT_CONFIG_FILE" "$setup_rc" || setup_failed=1

    echo ""
    if [[ "$setup_failed" -eq 1 ]]; then
        log_error "Repair did not fully provision '$branch'. Review the setup output above."
        log_error "If a required file has no 'phase: provision' step to create it, add one, or copy it in by hand."
        return 2
    fi

    log_success "Repaired worktree: $branch"
    echo ""
    echo "Next steps (services already running keep stale config until restarted):"
    echo "  ${WT_CMD} stop $branch --all"
    echo "  ${WT_CMD} start $branch --all"
}

show_repair_help() {
    cat << 'EOF' | _wt_sub
Usage: wt repair [branch] [options]

Re-provision a registered worktree without disturbing your work. Repair re-runs
ONLY the safe, idempotent provisioning steps — those tagged `phase: provision`
in the project config (typically env/config file copies and port stamping) —
then re-verifies the declared `setup_requires` artifacts and updates the
worktree's provisioned status.

Repair NEVER checks out branches, reinstalls dependencies, or deletes
node_modules, so it is safe on a worktree whose submodules sit on your feature
branch with local changes. It is the tool-sanctioned fix for the "claimed but
setup was incomplete" state reported by `wt claim` / `wt start`.

Arguments:
  [branch]          Branch of the worktree (auto-detected inside a worktree)

Options:
  --branch <name>   Override branch detection
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt repair                       # repair the worktree in the current directory
  wt repair feature/auth          # repair a specific worktree
  wt repair --branch feat -p app  # explicit branch + project
EOF
}
