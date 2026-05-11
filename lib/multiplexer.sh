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
# Args: window_name root_dir config_file [no_attach] [project] [branch]
# project + branch are required for herdr to persist per-pane state.
multiplexer_open_tab() {
    local window_name="$1"
    local root_dir="$2"
    local config_file="$3"
    local no_attach="${4:-0}"
    local project="${5:-}"
    local branch="${6:-}"

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
            multiplexer_open_tab_herdr "$window_name" "$root_dir" "$no_attach" "$project" "$branch" "$config_file"
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

# Split a herdr pane and return the new pane_id.
# Args: target_pane_id direction [cwd]
# direction: "right" or "down"
herdr_pane_split() {
    local target="$1"
    local direction="$2"
    local cwd="${3:-}"
    command_exists herdr || return 1
    command_exists jq || return 1
    local args=(pane split "$target" --direction "$direction" --no-focus)
    [[ -n "$cwd" ]] && args+=(--cwd "$cwd")
    local out
    if ! out=$(herdr "${args[@]}" 2>&1); then
        log_warn "herdr pane split failed: $out"
        return 1
    fi
    echo "$out" | jq -r '.result.pane.pane_id // empty' 2>/dev/null
}

# Build a pane layout inside the new tab's initial pane, mirroring the
# project's tmux.layout. Returns newline-separated pane_ids in config order
# (config[0] -> first pane id, etc.).
# Args: initial_pane_id config_file root_dir
herdr_build_layout() {
    local p0="$1"
    local config_file="$2"
    local root_dir="$3"

    [[ -z "$p0" ]] && return 1
    [[ ! -f "$config_file" ]] && { echo "$p0"; return 0; }

    local layout pane_count
    layout=$(yaml_get "$config_file" ".tmux.layout" "tiled")
    pane_count=$(yq '[.tmux.windows[0].panes[]?] | length' "$config_file" 2>/dev/null || echo 0)
    [[ "$pane_count" == "null" ]] && pane_count=0
    [[ "$pane_count" -le 1 ]] && { echo "$p0"; return 0; }

    case "$layout" in
        services-top-2)
            _herdr_layout_services_top_2 "$p0" "$root_dir"
            return $?
            ;;
        services-top)
            _herdr_layout_services_top "$p0" "$root_dir" "$pane_count"
            return $?
            ;;
        *)
            _herdr_layout_generic "$p0" "$root_dir" "$pane_count"
            return $?
            ;;
    esac
}

# 4-pane services-top-2 layout. Splits mirror lib/tmux.sh:setup_services_top_2_layout
# config order: 0=top-left, 1=top-right, 2=bottom-left, 3=bottom-right
_herdr_layout_services_top_2() {
    local p0="$1"
    local cwd="$2"
    local p1 p2 p3
    p2=$(herdr_pane_split "$p0" "down" "$cwd") || return 1
    p1=$(herdr_pane_split "$p0" "right" "$cwd") || return 1
    p3=$(herdr_pane_split "$p2" "right" "$cwd") || return 1
    printf '%s\n%s\n%s\n%s\n' "$p0" "$p1" "$p2" "$p3"
}

# 5-pane services-top layout: 3 service panes on top, 2 command panes bottom.
# config order: 0=top-left, 1=top-mid, 2=top-right, 3=bottom-left, 4=bottom-right
_herdr_layout_services_top() {
    local p0="$1"
    local cwd="$2"
    local count="$3"
    local p1 p2 p3 p4
    p3=$(herdr_pane_split "$p0" "down" "$cwd") || return 1
    p1=$(herdr_pane_split "$p0" "right" "$cwd") || return 1
    p2=$(herdr_pane_split "$p1" "right" "$cwd") || return 1
    if [[ "$count" -ge 5 ]]; then
        p4=$(herdr_pane_split "$p3" "right" "$cwd") || return 1
        printf '%s\n%s\n%s\n%s\n%s\n' "$p0" "$p1" "$p2" "$p3" "$p4"
    else
        printf '%s\n%s\n%s\n%s\n' "$p0" "$p1" "$p2" "$p3"
    fi
}

# Generic layout: alternating right/down splits until N panes.
_herdr_layout_generic() {
    local p0="$1"
    local cwd="$2"
    local count="$3"
    local panes=("$p0")
    local i=1
    while [[ "$i" -lt "$count" ]]; do
        local target="${panes[$((i / 2))]}"
        local direction
        if (( i % 2 == 1 )); then
            direction="right"
        else
            direction="down"
        fi
        local new_pid
        new_pid=$(herdr_pane_split "$target" "$direction" "$cwd") || return 1
        panes+=("$new_pid")
        i=$((i + 1))
    done
    printf '%s\n' "${panes[@]}"
}

# Configure each pane from config: send `cd <dir>` and the comment/command
# defined in config[i]. Stores pane_id back into state under
# `worktrees.<branch>.services.<svc>.pane_id` and
# `worktrees.<branch>.panes.<index>` for later lookup.
# Args: project branch config_file root_dir pane_ids_multiline
herdr_configure_panes() {
    local project="$1"
    local branch="$2"
    local config_file="$3"
    local root_dir="$4"
    local pane_ids="$5"

    local pane_count
    pane_count=$(yq '[.tmux.windows[0].panes[]?] | length' "$config_file" 2>/dev/null || echo 0)
    [[ "$pane_count" == "null" ]] && pane_count=0
    [[ "$pane_count" -le 0 ]] && return 0

    # Pre-fetch pane data + service working dirs (matches tmux flow).
    local all_pane_data all_svc_dirs
    all_pane_data=$(yq -r '.tmux.windows[0].panes[] | [.service // "", .command // "", .working_dir // ""] | @tsv' "$config_file" 2>/dev/null)
    all_svc_dirs=$(yq -r '.services[]? | [.name, .working_dir // ""] | @tsv' "$config_file" 2>/dev/null)

    local -a pane_arr=()
    while IFS= read -r pid; do
        [[ -n "$pid" ]] && pane_arr+=("$pid")
    done <<< "$pane_ids"

    local p=0
    while IFS=$'\t' read -r pane_service pane_cmd pane_dir; do
        [[ $p -ge $pane_count ]] && break
        [[ $p -ge ${#pane_arr[@]} ]] && break
        local pid="${pane_arr[$p]}"

        if [[ -n "$pane_service" ]] && [[ "$pane_service" != "null" ]]; then
            local svc_working_dir=""
            while IFS=$'\t' read -r svc_name svc_dir; do
                if [[ "$svc_name" == "$pane_service" ]]; then
                    svc_working_dir="$svc_dir"
                    break
                fi
            done <<< "$all_svc_dirs"

            if [[ -n "$svc_working_dir" ]] && [[ "$svc_working_dir" != "null" ]] && [[ -n "$root_dir" ]]; then
                herdr pane run "$pid" "cd '$root_dir/$svc_working_dir'" >/dev/null 2>&1 || true
            fi
            herdr pane run "$pid" "echo '# Service: $pane_service (use wt start to run)'" >/dev/null 2>&1 || true
            # Persist pane_id under the service so start_service can find it
            set_service_state "$project" "$branch" "$pane_service" "pane_id" "$pid"
        elif [[ -n "$pane_cmd" ]] && [[ "$pane_cmd" != "null" ]] && [[ "$pane_cmd" != "" ]]; then
            local target_dir="$root_dir"
            if [[ -n "$pane_dir" ]] && [[ "$pane_dir" != "null" ]] && [[ "$pane_dir" != "." ]]; then
                target_dir="$root_dir/$pane_dir"
            fi
            herdr pane run "$pid" "cd '$target_dir'" >/dev/null 2>&1 || true
            herdr pane run "$pid" "$pane_cmd" >/dev/null 2>&1 || true
        else
            # Empty command pane (orchestrator-style)
            [[ -n "$root_dir" ]] && herdr pane run "$pid" "cd '$root_dir'" >/dev/null 2>&1 || true
        fi
        p=$((p + 1))
    done <<< "$all_pane_data"

    return 0
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
#
# Flow when a config_file is provided:
#   1. tab create
#   2. resolve initial pane_id
#   3. if tmux.windows[0].panes has >1 entry, mount the layout via pane.split
#      and persist pane_ids to state per service
#   4. send `cd <dir>` and the configured command/comment to each pane
#   5. run herdr.post_create in the LAST pane of the layout (the
#      "orchestrator" position) — or in the initial pane when single-pane.
#
# Args: window_name root_dir no_attach [project branch config_file [hook_name]]
# hook_name: "post_create" (default) or "post_attach" — selects which herdr.*
# command list to run in the last pane after layout mount.
multiplexer_open_tab_herdr() {
    local window_name="$1"
    local root_dir="$2"
    local no_attach="${3:-0}"
    local project="" branch="" config_file="" hook_name="post_create"
    if [[ $# -ge 7 ]]; then
        project="${4:-}"; branch="${5:-}"; config_file="${6:-}"; hook_name="${7:-post_create}"
    elif [[ $# -ge 6 ]]; then
        project="${4:-}"; branch="${5:-}"; config_file="${6:-}"
    elif [[ $# -ge 4 ]]; then
        config_file="${4:-}"
    fi

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

    # Without a config file we have nothing more to do.
    [[ -z "$config_file" ]] && return 0

    # Short-circuit when there's nothing to mount or run: no multi-pane
    # layout AND no post_* commands. This avoids an extra `herdr pane list`
    # round-trip for trivial configs.
    local pane_count post_cmds
    pane_count=$(yq '[.tmux.windows[0].panes[]?] | length' "$config_file" 2>/dev/null || echo 0)
    [[ "$pane_count" == "null" ]] && pane_count=0
    post_cmds=$(herdr_get_commands "$config_file" "$hook_name")
    if [[ "$pane_count" -le 1 ]] && [[ -z "$post_cmds" ]]; then
        return 0
    fi

    # Everything below needs jq to parse responses.
    if ! command_exists jq; then
        log_warn "jq missing; skipping herdr layout mount and post_$hook_name"
        return 0
    fi

    local tab_id initial_pane
    tab_id=$(echo "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
    [[ -z "$tab_id" ]] && { log_warn "Could not parse tab_id; skipping layout/$hook_name"; return 0; }
    initial_pane=$(herdr_get_pane_for_tab "$tab_id")
    [[ -z "$initial_pane" ]] && { log_warn "Could not resolve initial pane; skipping layout/$hook_name"; return 0; }

    local last_pane="$initial_pane"

    if [[ "$pane_count" -gt 1 ]]; then
        log_info "Mounting herdr layout ($pane_count panes)"
        local layout_pane_ids
        if layout_pane_ids=$(herdr_build_layout "$initial_pane" "$config_file" "$root_dir"); then
            if [[ -n "$project" ]] && [[ -n "$branch" ]]; then
                herdr_configure_panes "$project" "$branch" "$config_file" "$root_dir" "$layout_pane_ids"
            fi
            # The last pane id in the layout becomes the orchestrator target.
            last_pane=$(echo "$layout_pane_ids" | awk 'NF{p=$0} END{print p}')
        else
            log_warn "Layout mount failed; falling back to single-pane tab"
        fi
    fi

    # Run herdr.<hook_name> in the orchestrator pane (last in layout, or
    # the initial pane when single-pane). post_cmds was already loaded
    # above for the short-circuit check.
    if [[ -n "$post_cmds" ]] && [[ -n "$last_pane" ]]; then
        log_info "Running herdr.$hook_name commands in pane $last_pane"
        herdr_run_commands_in_pane "$last_pane" "$post_cmds"
    fi

    return 0
}

# Warn about herdr-side limitations at create time. With layout mount in
# place, only the truly missing pieces stay here: jq required for layout
# mount, and the fact that herdr's pane.split is 50/50 (no percentage
# sizing) so sizes won't match tmux exactly.
# Args: config_file
multiplexer_warn_dropped_features() {
    local config_file="$1"
    local mux
    mux=$(detect_multiplexer)
    [[ "$mux" != "herdr" ]] && return 0
    [[ ! -f "$config_file" ]] && return 0

    local pane_count
    pane_count=$(yq '[.tmux.windows[]?.panes[]?] | length' "$config_file" 2>/dev/null || echo 0)
    [[ "$pane_count" == "null" ]] && pane_count=0

    if [[ "$pane_count" -gt 1 ]] && ! command_exists jq; then
        log_warn "herdr layout mount needs jq — install with 'brew install jq' or set WT_MULTIPLEXER=tmux."
    fi
    return 0
}

# Close a herdr tab matching the given label. Returns 0 even on failure
# (best-effort cleanup). Used by multiplexer_close_tab and as a fallback
# even when the detected multiplexer isn't herdr — the user may have a
# herdr session running that owns a tab for this worktree.
#
# Args: label [verbose=0]
# verbose=1 surfaces "tab not found" as a WARN; verbose=0 stays silent
# (used when this is a defensive cleanup from a non-herdr context).
_herdr_close_tab_by_label() {
    local label="$1"
    local verbose="${2:-0}"
    command_exists herdr || return 0
    command_exists jq || return 0

    # Fast probe: is herdr reachable? If `tab list` errors (no running
    # server) bail silently so wt delete outside of herdr stays quiet.
    local raw
    if ! raw=$(herdr tab list 2>/dev/null); then
        return 0
    fi
    if [[ -z "$raw" ]]; then
        return 0
    fi

    # Prefer the active workspace scope when available (cross-workspace
    # label collision safety), then fall back to unscoped match.
    local tab_id=""
    if [[ -n "${HERDR_ACTIVE_WORKSPACE_ID:-}" ]]; then
        tab_id=$(herdr tab list --workspace "$HERDR_ACTIVE_WORKSPACE_ID" 2>/dev/null \
            | jq -r --arg L "$label" '.result.tabs[]? | select(.label == $L) | .tab_id' 2>/dev/null \
            | head -1)
    fi
    if [[ -z "$tab_id" ]]; then
        tab_id=$(echo "$raw" \
            | jq -r --arg L "$label" '.result.tabs[]? | select(.label == $L) | .tab_id' 2>/dev/null \
            | head -1)
    fi
    if [[ -z "$tab_id" ]]; then
        if [[ "$verbose" -eq 1 ]]; then
            log_warn "No herdr tab with label '$label' found to close — leaving herdr untouched"
            log_debug "Active workspace: ${HERDR_ACTIVE_WORKSPACE_ID:-<unset>}"
            log_debug "tab list output: $raw"
        else
            log_debug "No herdr tab labeled '$label' found"
        fi
        return 0
    fi
    local close_out
    if close_out=$(herdr tab close "$tab_id" 2>&1); then
        log_info "Closed herdr tab '$label' ($tab_id)"
    else
        log_warn "herdr tab close $tab_id failed: $close_out"
    fi
    return 0
}

# Close the active multiplexer's window/tab for a given label. Used by
# `wt delete` to clean up after a worktree.
#
# Always also tries to close a matching herdr tab, even when the active
# multiplexer isn't herdr — `wt delete` is often run from a plain shell
# (or tmux) while the herdr session that created the tab is still
# running in the background. Without this, the herdr tab leaks.
#
# Args: label config_file
multiplexer_close_tab() {
    local label="$1"
    local config_file="$2"
    local mux
    mux=$(detect_multiplexer)

    local verbose=0
    case "$mux" in
        tmux|dmux)
            kill_session "$label" "$config_file" || true
            ;;
        herdr)
            verbose=1  # user is asking from inside herdr; warn on miss
            ;;
        none) ;;
    esac

    # Best-effort herdr cleanup regardless of detected mux. No-op if
    # herdr isn't installed or no session is running. Verbose only when
    # herdr is the active mux so plain-shell `wt delete` stays quiet
    # when there's nothing to clean.
    _herdr_close_tab_by_label "$label" "$verbose"
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
