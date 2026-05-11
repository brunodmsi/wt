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
            multiplexer_open_tab_herdr "$window_name" "$root_dir" "$no_attach" "$config_file"
            return $?
            ;;
        none)
            log_warn "No supported multiplexer detected (tmux/dmux/herdr). Worktree created at: $root_dir"
            return 0
            ;;
    esac
}

# Read a list of commands from the herdr.<key> section of the project config.
# Args: config_file key (e.g. "post_create", "post_attach")
# Output: one command per line (empty output if section is missing or empty).
herdr_get_commands() {
    local config_file="$1"
    local key="$2"
    [[ -f "$config_file" ]] || return 0
    yq -r ".herdr.${key} // [] | .[]" "$config_file" 2>/dev/null
}

# Find the pane_id of the first pane in a herdr tab.
# Requires jq. Returns empty on failure.
# Args: tab_id
herdr_get_pane_for_tab() {
    local tab_id="$1"
    [[ -z "$tab_id" ]] && return 1
    command_exists herdr || return 1
    command_exists jq    || return 1
    herdr pane list 2>/dev/null \
        | jq -r --arg T "$tab_id" '.result.panes[]? | select(.tab_id == $T) | .pane_id' 2>/dev/null \
        | head -1
}

# Run each newline-separated command in a herdr pane via `herdr pane run`.
# Args: pane_id commands_multiline
# Returns 0 even when individual commands fail (warns instead) so a single
# bad post_* entry doesn't abort the calling flow.
herdr_run_commands_in_pane() {
    local pane_id="$1"
    local commands="$2"
    [[ -z "$pane_id" ]] && return 0
    [[ -z "$commands" ]] && return 0
    command_exists herdr || { log_warn "herdr CLI missing; cannot run pane commands"; return 0; }

    while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue
        log_debug "herdr pane run $pane_id: $cmd"
        if ! herdr pane run "$pane_id" "$cmd" >/dev/null 2>&1; then
            log_warn "herdr pane command failed: $cmd"
        fi
    done <<< "$commands"
    return 0
}

# herdr integration via `herdr tab create`.
# Honors WT_HERDR_NO_FOCUS=1 (or no_attach) to skip --focus.
# When a config_file is provided and defines `herdr.post_create`, each command
# is queued into the new tab's pane via `herdr pane run`.
multiplexer_open_tab_herdr() {
    local window_name="$1"
    local root_dir="$2"
    local no_attach="${3:-0}"
    local config_file="${4:-}"

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
    if ! out=$(herdr tab create --cwd "$root_dir" --label "$window_name" "$focus_flag" 2>&1); then
        log_warn "herdr tab create failed: $out"
        log_info "Open a new tab in herdr and run: cd '$root_dir'"
        return 1
    fi

    log_success "Opened herdr tab '$window_name'"
    log_debug "$out"

    # Run herdr.post_create commands in the new tab's pane, if any.
    if [[ -n "$config_file" ]]; then
        local post_cmds
        post_cmds=$(herdr_get_commands "$config_file" "post_create")
        if [[ -n "$post_cmds" ]]; then
            if ! command_exists jq; then
                log_warn "jq is required to run herdr.post_create commands (skipping)"
            else
                local tab_id pane_id
                tab_id=$(echo "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
                if [[ -n "$tab_id" ]]; then
                    pane_id=$(herdr_get_pane_for_tab "$tab_id")
                    if [[ -n "$pane_id" ]]; then
                        log_info "Running herdr.post_create commands in pane $pane_id"
                        herdr_run_commands_in_pane "$pane_id" "$post_cmds"
                    else
                        log_warn "Could not resolve pane for new herdr tab $tab_id; skipping post_create"
                    fi
                else
                    log_warn "Could not parse tab_id from herdr response; skipping post_create"
                fi
            fi
        fi
    fi

    return 0
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
