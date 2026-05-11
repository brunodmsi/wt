#!/bin/bash
# lib/multiplexer.sh - Detect and dispatch to the active terminal multiplexer
#
# Supports tmux, dmux (https://dmux.ai), and herdr (https://herdr.dev).
# dmux runs on top of tmux, so dmux sessions are driven through tmux commands.
# herdr is driven via its CLI: `herdr tab create` opens a tab at the worktree
# path; `herdr tab focus` (used in `wt attach`) selects an existing tab. Only
# tab open/focus is wired through herdr today — multi-pane layouts and the
# service lifecycle (`wt start`/`stop`/`restart`/`status`/`delete`) still drive
# tmux directly, so they are no-ops or broken under herdr. See issue #10.

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
            multiplexer_open_tab_herdr "$window_name" "$root_dir" "$no_attach"
            return $?
            ;;
        none)
            log_warn "No supported multiplexer detected (tmux/dmux/herdr). Worktree created at: $root_dir"
            return 0
            ;;
    esac
}

# herdr integration via `herdr tab create`.
# Honors WT_HERDR_NO_FOCUS=1 (or no_attach) to skip --focus.
multiplexer_open_tab_herdr() {
    local window_name="$1"
    local root_dir="$2"
    local no_attach="${3:-0}"

    if ! command_exists herdr; then
        log_warn "herdr environment detected but 'herdr' CLI not found in PATH"
        log_info "Worktree path: $root_dir"
        return 0
    fi

    local focus_flag="--focus"
    if [[ "$no_attach" == "1" ]] || [[ -n "${WT_HERDR_NO_FOCUS:-}" ]]; then
        focus_flag="--no-focus"
    fi

    local out
    if out=$(herdr tab create --cwd "$root_dir" --label "$window_name" "$focus_flag" 2>&1); then
        log_success "Opened herdr tab '$window_name'"
        log_debug "$out"
        return 0
    fi

    log_warn "herdr tab create failed: $out"
    log_info "Open a new tab in herdr and run: cd '$root_dir'"
    return 1
}

# Warn when the active multiplexer cannot reproduce the project's pane layout
# or run services through it. herdr today only opens a single tab — multi-pane
# layouts and `wt start` are still tmux-only, so we surface that at create time.
# Args: config_file
multiplexer_warn_dropped_features() {
    local config_file="$1"
    local mux
    mux=$(detect_multiplexer)
    [[ "$mux" != "herdr" ]] && return 0
    [[ ! -f "$config_file" ]] && return 0

    local pane_count service_count
    pane_count=$(yq '[.tmux.windows[]?.panes[]?] | length' "$config_file" 2>/dev/null || echo 0)
    service_count=$(yq '.services // [] | length' "$config_file" 2>/dev/null || echo 0)
    [[ "$pane_count" == "null" ]] && pane_count=0
    [[ "$service_count" == "null" ]] && service_count=0

    if [[ "$pane_count" -gt 1 ]] || [[ "$service_count" -gt 0 ]]; then
        log_warn "herdr backend opens a single tab — project's multi-pane layout and services will not run inside it."
        log_warn "  Panes in config: $pane_count   Services: $service_count"
        log_warn "  'wt start' still drives tmux directly and will not target the herdr tab. Use WT_MULTIPLEXER=tmux to keep the full layout."
    fi
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
