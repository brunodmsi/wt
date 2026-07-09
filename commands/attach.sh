#!/bin/bash
# commands/attach.sh - Attach to a worktree's tmux session

cmd_attach() {
    local branch=""
    local window=""
    local project=""
    local here=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -w|--window)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                window="$2"
                shift 2
                ;;
            --here)
                here=1
                shift
                ;;
            -p|--project)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                project="$2"
                shift 2
                ;;
            -h|--help)
                show_attach_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_attach_help
                return 1
                ;;
            *)
                if [[ -z "$branch" ]]; then
                    branch="$1"
                fi
                shift
                ;;
        esac
    done

    # If no branch specified, try to detect from current directory
    if [[ -z "$branch" ]]; then
        branch=$(detect_worktree_branch)
        if [[ -z "$branch" ]]; then
            log_error "Branch name is required"
            show_attach_help
            return 1
        fi
        log_info "Detected worktree branch: $branch"
    fi

    project=$(require_project "$project")
    load_project_config "$project"

    local _attach_mux _attach_wt_path _attach_label
    _attach_mux=$(detect_multiplexer)
    _attach_wt_path=$(get_worktree_path "$project" "$branch")
    _attach_label=$(get_session_name "$project" "$branch")

    # --here: never create or switch to another tab/window. Operate on the
    # caller's current pane: cd into the worktree, then run post_attach.
    if [[ "$here" -eq 1 ]]; then
        if [[ ! -d "$_attach_wt_path" ]]; then
            die "Worktree not found for branch: $branch (path: $_attach_wt_path)"
        fi
        _attach_here_in_current_pane "$_attach_mux" "$_attach_wt_path" "$branch"
        return $?
    fi

    # Bail early when the active multiplexer doesn't support attach.
    case "$_attach_mux" in
        herdr)
            if ! command_exists herdr; then
                die "herdr CLI not found in PATH. Install herdr or set WT_MULTIPLEXER=tmux."
            fi
            if ! command_exists jq; then
                die "jq is required to look up herdr tabs by label (prevents duplicate tabs). Install with 'brew install jq' or set WT_MULTIPLEXER=tmux."
            fi

            # Scope tab lookup to the active workspace so identically-named
            # tabs in other workspaces don't collide.
            local _herdr_tab_list_args=()
            if [[ -n "${HERDR_ACTIVE_WORKSPACE_ID:-}" ]]; then
                _herdr_tab_list_args+=(--workspace "$HERDR_ACTIVE_WORKSPACE_ID")
            fi

            local _attach_tab_id
            _attach_tab_id=$(herdr tab list ${_herdr_tab_list_args[@]+"${_herdr_tab_list_args[@]}"} 2>/dev/null \
                | jq -r --arg L "$_attach_label" '.result.tabs[]? | select(.label == $L) | .tab_id' 2>/dev/null \
                | head -1)
            if [[ -n "$_attach_tab_id" ]]; then
                if herdr tab focus "$_attach_tab_id" >/dev/null 2>&1; then
                    log_success "Focused herdr tab '$_attach_label'"
                    # Focus-only path intentionally does NOT run post_attach
                    # so repeated attach calls don't re-run side effects.
                    return 0
                fi
                log_warn "Found tab '$_attach_label' but failed to focus it; opening a new one"
            fi

            # Tab missing — create a new one. Run post_attach (not post_create)
            # because the user invoked `wt attach`. Layout mount is shared
            # with `wt create` via multiplexer_open_tab_herdr.
            multiplexer_open_tab_herdr "$_attach_label" "$_attach_wt_path" 0 \
                "$project" "$branch" "$PROJECT_CONFIG_FILE" "post_attach"
            return $?
            ;;
        none)
            log_warn "No multiplexer available; cd into the worktree manually:"
            echo "  cd '$_attach_wt_path'"
            return 0
            ;;
    esac

    # Get window name (sanitized branch)
    local window_name
    window_name=$(get_session_name "$project" "$branch")

    # Get tmux session name from config
    local tmux_session
    tmux_session=$(get_tmux_session_name "$PROJECT_CONFIG_FILE")

    # Check if window exists, create if needed. Resolve the worktree path from
    # state (authoritative for claimed worktrees that live outside
    # <repo>/.worktrees), falling back to the convention path.
    if ! session_exists "$tmux_session" || ! window_exists "$tmux_session" "$window_name"; then
        local wt_path
        wt_path=$(get_worktree_path "$project" "$branch")
        [[ -z "$wt_path" ]] && wt_path=$(worktree_path "$branch" "$PROJECT_REPO_PATH")
        if [[ -d "$wt_path" ]]; then
            log_info "Window not found, creating..."
            create_session "$window_name" "$wt_path" "$PROJECT_CONFIG_FILE" "$window"
        else
            die "No worktree found for branch: $branch"
        fi
    fi

    # Attach to session and select window
    attach_session "$window_name" "$PROJECT_CONFIG_FILE"
}

# Implements `wt attach --here`: cd the caller's current pane into the
# worktree and replay herdr.post_attach commands without creating a new
# tab/window.
_attach_here_in_current_pane() {
    local mux="$1"
    local wt_path="$2"
    local branch="$3"

    local post_cmds=""
    if [[ "$mux" == "herdr" ]] && [[ -n "${PROJECT_CONFIG_FILE:-}" ]]; then
        post_cmds=$(herdr_get_commands "$PROJECT_CONFIG_FILE" "post_attach")
    fi

    case "$mux" in
        herdr)
            command_exists herdr || die "herdr CLI not found in PATH."

            # HERDR_ACTIVE_PANE_ID is only set for keybind-launched commands,
            # not interactive pane shells, so fall back to querying the
            # socket for the focused pane.
            local pane_id="${HERDR_ACTIVE_PANE_ID:-}"
            if [[ -z "$pane_id" ]]; then
                if ! command_exists jq; then
                    die "Cannot determine current herdr pane without jq. Install with 'brew install jq'."
                fi
                pane_id=$(herdr pane list 2>/dev/null \
                    | jq -r '.result.panes[]? | select(.focused == true) | .pane_id' 2>/dev/null \
                    | head -1)
            fi
            if [[ -z "$pane_id" ]]; then
                die "Could not resolve the focused herdr pane. Are you running this from inside herdr?"
            fi

            herdr pane run "$pane_id" "cd '$wt_path'" >/dev/null 2>&1 \
                || { log_warn "Failed to cd in current herdr pane"; return 1; }
            if [[ -n "$post_cmds" ]]; then
                herdr_run_commands_in_pane "$pane_id" "$post_cmds"
            fi
            log_success "Attached --here to $branch in herdr pane $pane_id"
            return 0
            ;;
        tmux|dmux)
            local pane="${TMUX_PANE:-}"
            if [[ -z "$pane" ]]; then
                die "TMUX_PANE is not set — run 'wt attach --here' inside a tmux pane."
            fi
            command_exists tmux || die "tmux CLI not found in PATH."
            tmux send-keys -t "$pane" "cd '$wt_path'" Enter \
                || { log_warn "Failed to cd in current tmux pane"; return 1; }
            log_success "Attached --here to $branch in current tmux pane"
            return 0
            ;;
        none)
            # Without a multiplexer we cannot inject into a pane. Emit cd
            # so the user can `eval` if they want.
            log_warn "No multiplexer detected — run this in your shell to switch in:"
            echo "  cd '$wt_path'"
            return 0
            ;;
    esac
}


show_attach_help() {
    cat << 'EOF' | _wt_sub
Usage: wt attach <branch> [options]

Attach to a worktree's multiplexer session.

Default behavior:
  - tmux/dmux: switch to the worktree's window, creating it if needed
  - herdr:    focus the matching tab, or create one if not present
  - none:     print the cd command

Arguments:
  <branch>          Branch name of the worktree (auto-detected inside one)

Options:
  --here            Don't create or switch tabs/windows. cd the CURRENT pane
                    into the worktree and (under herdr) replay
                    herdr.post_attach commands. Requires HERDR_ACTIVE_PANE_ID
                    or TMUX_PANE to be set.
  -w, --window      tmux only: create window at specific index
  -p, --project     Project name (auto-detected if not specified)
  -h, --help        Show this help message

Examples:
  wt attach feature/auth
  wt attach feature/auth --here     # use the current pane in place
  wt attach feature/auth -w 2       # tmux: create at window index 2
EOF
}
