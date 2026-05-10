#!/bin/bash
# lib/multiplexer.sh - Detect and dispatch to the active terminal multiplexer
#
# Supports tmux, dmux (https://dmux.ai), and herdr (https://herdr.dev).
# dmux runs on top of tmux, so dmux sessions are driven through tmux commands.
# herdr does not expose a programmatic API for spawning panes/tabs, so we
# fall back to a best-effort `herdr` CLI invocation and log instructions.

# Detect which multiplexer is currently active.
# Order: WT_MULTIPLEXER override -> herdr -> dmux -> tmux -> none
# Output: one of "tmux", "dmux", "herdr", "none"
detect_multiplexer() {
    if [[ -n "${WT_MULTIPLEXER:-}" ]]; then
        case "$WT_MULTIPLEXER" in
            tmux|dmux|herdr|none) echo "$WT_MULTIPLEXER"; return 0 ;;
        esac
    fi

    # herdr sets HERDR_SOCKET_PATH for processes spawned by it.
    if [[ -n "${HERDR_SOCKET_PATH:-}" ]]; then
        echo "herdr"
        return 0
    fi

    # dmux runs on tmux. Detect via env var or session/process heuristic.
    if [[ -n "${DMUX_SESSION:-}" ]] || [[ -n "${DMUX_PANE_ID:-}" ]]; then
        echo "dmux"
        return 0
    fi
    if [[ -n "${TMUX:-}" ]] && command_exists tmux; then
        local _sn
        _sn=$(tmux display-message -p '#S' 2>/dev/null || echo "")
        if [[ "$_sn" == dmux* ]]; then
            echo "dmux"
            return 0
        fi
        if command_exists pgrep && pgrep -x dmux >/dev/null 2>&1; then
            echo "dmux"
            return 0
        fi
        echo "tmux"
        return 0
    fi

    if command_exists tmux; then
        echo "tmux"
        return 0
    fi

    echo "none"
}

# Open a new tab/window in the detected multiplexer.
# Args: window_name worktree_path config_file [no_attach]
# Returns 0 on success, non-zero on failure.
multiplexer_open_tab() {
    local window_name="$1"
    local root_dir="$2"
    local config_file="$3"
    local no_attach="${4:-0}"

    local mux
    mux=$(detect_multiplexer)

    case "$mux" in
        tmux|dmux)
            if [[ "$mux" == "dmux" ]]; then
                log_info "dmux detected — opening window via tmux underneath"
            fi
            create_session "$window_name" "$root_dir" "$config_file" "" "$no_attach"
            return $?
            ;;
        herdr)
            multiplexer_open_tab_herdr "$window_name" "$root_dir"
            return $?
            ;;
        none)
            log_warn "No supported multiplexer detected (tmux/dmux/herdr). Worktree created at: $root_dir"
            return 0
            ;;
    esac
}

# Best-effort herdr integration.
# herdr does not document a CLI for spawning panes/tabs from outside, so we
# attempt a few likely subcommands; if none work, we log a clear instruction.
multiplexer_open_tab_herdr() {
    local window_name="$1"
    local root_dir="$2"

    if ! command_exists herdr; then
        log_warn "herdr environment detected but 'herdr' CLI not found in PATH"
        log_info "Worktree path: $root_dir"
        return 0
    fi

    # Try documented session subcommand for spawning a workspace.
    # If herdr ever ships a `tab new` / `pane new` command, prefer that.
    if herdr --help 2>/dev/null | grep -qE '^\s*(tab|pane|window)\s'; then
        if herdr tab new --cwd "$root_dir" --name "$window_name" 2>/dev/null \
           || herdr pane new --cwd "$root_dir" --name "$window_name" 2>/dev/null \
           || herdr window new --cwd "$root_dir" --name "$window_name" 2>/dev/null; then
            log_success "Opened herdr tab '$window_name'"
            return 0
        fi
    fi

    log_warn "herdr has no programmatic pane API; cannot auto-open a tab"
    log_info "Open a new tab in herdr and run: cd '$root_dir'"
    return 0
}

# Get the current multiplexer's session label for display purposes.
multiplexer_session_label() {
    local config_file="$1"
    local mux
    mux=$(detect_multiplexer)
    case "$mux" in
        tmux|dmux) get_tmux_session_name "$config_file" ;;
        herdr) echo "herdr" ;;
        none) echo "-" ;;
    esac
}
