#!/usr/bin/env bats
# Tests for lib/multiplexer.sh

load test_helper

setup() {
    setup_test_dirs
    load_lib utils
    load_lib config
    load_lib multiplexer

    # Clear any inherited multiplexer env so tests start from a known state.
    unset WT_MULTIPLEXER HERDR_SOCKET_PATH DMUX_SESSION DMUX_PANE_ID TMUX
}

teardown() {
    teardown_test_dirs
}

@test "detect_multiplexer respects WT_MULTIPLEXER override" {
    export WT_MULTIPLEXER="herdr"
    run detect_multiplexer
    [ "$status" -eq 0 ]
    [ "$output" = "herdr" ]
}

@test "detect_multiplexer ignores invalid WT_MULTIPLEXER values" {
    export WT_MULTIPLEXER="bogus"
    # Provide no other signals; PATH still has tmux on most systems.
    run detect_multiplexer
    [ "$status" -eq 0 ]
    [ "$output" != "bogus" ]
}

@test "detect_multiplexer prefers herdr when HERDR_SOCKET_PATH is set" {
    export HERDR_SOCKET_PATH="/tmp/fake.sock"
    export TMUX="/tmp/tmux-1000/default,12345,0"  # Even with TMUX set
    run detect_multiplexer
    [ "$status" -eq 0 ]
    [ "$output" = "herdr" ]
}

@test "detect_multiplexer detects dmux via DMUX_SESSION env" {
    export DMUX_SESSION="myproject"
    run detect_multiplexer
    [ "$status" -eq 0 ]
    [ "$output" = "dmux" ]
}

@test "detect_multiplexer detects dmux via DMUX_PANE_ID env" {
    export DMUX_PANE_ID="abc-123"
    run detect_multiplexer
    [ "$status" -eq 0 ]
    [ "$output" = "dmux" ]
}

@test "detect_multiplexer returns tmux when only tmux is available" {
    # Stub command_exists to make tmux available but no dmux process.
    command_exists() { [[ "$1" == "tmux" ]]; }
    run detect_multiplexer
    [ "$status" -eq 0 ]
    [ "$output" = "tmux" ]
}

@test "detect_multiplexer returns none when nothing available" {
    command_exists() { return 1; }
    run detect_multiplexer
    [ "$status" -eq 0 ]
    [ "$output" = "none" ]
}

@test "multiplexer_open_tab with WT_MULTIPLEXER=none warns and succeeds" {
    export WT_MULTIPLEXER="none"
    run multiplexer_open_tab "branch-x" "/tmp/wt" "/tmp/cfg.yml" 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"No supported multiplexer"* ]]
}

@test "multiplexer_open_tab herdr without herdr CLI logs warning" {
    export WT_MULTIPLEXER="herdr"
    command_exists() { return 1; }
    run multiplexer_open_tab "branch-x" "/tmp/wt" "/tmp/cfg.yml" 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"herdr"* ]]
    [[ "$output" == *"/tmp/wt"* ]]
}

@test "multiplexer_open_tab herdr calls 'herdr tab create' when CLI present" {
    export WT_MULTIPLEXER="herdr"
    export HERDR_STUB_LOG="$TEST_TMPDIR/herdr.log"
    : > "$HERDR_STUB_LOG"

    # Place a stub herdr on PATH so the call is captured.
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/herdr" <<EOF
#!/bin/bash
echo "HERDR_CALL: \$*" >> "$HERDR_STUB_LOG"
echo '{"id":"cli:tab:create","result":{"type":"tab_created"}}'
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/herdr"
    PATH="$TEST_TMPDIR/bin:$PATH" run multiplexer_open_tab "branch-x" "/tmp/wt" "/tmp/cfg.yml" 0
    [ "$status" -eq 0 ]
    log=$(cat "$HERDR_STUB_LOG")
    [[ "$log" == *"tab create"* ]]
    [[ "$log" == *"--cwd /tmp/wt"* ]]
    [[ "$log" == *"--label branch-x"* ]]
    [[ "$log" == *"--focus"* ]]
}

@test "multiplexer_open_tab herdr passes --no-focus when no_attach=1" {
    export WT_MULTIPLEXER="herdr"
    export HERDR_STUB_LOG="$TEST_TMPDIR/herdr.log"
    : > "$HERDR_STUB_LOG"

    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/herdr" <<EOF
#!/bin/bash
echo "HERDR_CALL: \$*" >> "$HERDR_STUB_LOG"
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/herdr"
    PATH="$TEST_TMPDIR/bin:$PATH" run multiplexer_open_tab "branch-x" "/tmp/wt" "/tmp/cfg.yml" 1
    [ "$status" -eq 0 ]
    log=$(cat "$HERDR_STUB_LOG")
    [[ "$log" == *"--no-focus"* ]]
    [[ "$log" != *"--focus "* ]] && [[ "$log" != *--focus$'\n'* ]]
}

@test "multiplexer_warn_dropped_features is silent for tmux" {
    export WT_MULTIPLEXER="tmux"
    local cfg="$TEST_TMPDIR/cfg.yml"
    create_yaml_fixture "$cfg" "tmux:
  windows:
    - name: dev
      panes:
        - command: 'a'
        - command: 'b'
services:
  - name: svc-a"
    run multiplexer_warn_dropped_features "$cfg"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "multiplexer_warn_dropped_features warns about missing jq under herdr w/ multi-pane" {
    export WT_MULTIPLEXER="herdr"
    command_exists() { [[ "$1" != "jq" ]]; }
    local cfg="$TEST_TMPDIR/cfg.yml"
    create_yaml_fixture "$cfg" "tmux:
  windows:
    - name: dev
      panes:
        - command: 'a'
        - command: 'b'"
    run multiplexer_warn_dropped_features "$cfg"
    [ "$status" -eq 0 ]
    [[ "$output" == *"layout mount needs jq"* ]]
}

@test "multiplexer_warn_dropped_features silent under herdr single-pane" {
    export WT_MULTIPLEXER="herdr"
    local cfg="$TEST_TMPDIR/cfg.yml"
    create_yaml_fixture "$cfg" "tmux:
  windows:
    - name: dev
      panes:
        - command: 'a'"
    run multiplexer_warn_dropped_features "$cfg"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "herdr_get_commands returns post_create list" {
    local cfg="$TEST_TMPDIR/cfg.yml"
    create_yaml_fixture "$cfg" "herdr:
  post_create:
    - 'pnpm dev'
    - 'echo ready'"
    run herdr_get_commands "$cfg" "post_create"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pnpm dev"* ]]
    [[ "$output" == *"echo ready"* ]]
}

@test "herdr_get_commands returns empty when section is absent" {
    local cfg="$TEST_TMPDIR/cfg.yml"
    create_yaml_fixture "$cfg" "name: x"
    run herdr_get_commands "$cfg" "post_create"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "multiplexer_open_tab herdr runs post_create commands in new pane" {
    export WT_MULTIPLEXER="herdr"
    export HERDR_STUB_LOG="$TEST_TMPDIR/herdr.log"
    : > "$HERDR_STUB_LOG"

    mkdir -p "$TEST_TMPDIR/bin"
    # Stub herdr that emits the right shape for `tab create` and `pane list`,
    # records every invocation, and acks `pane run`.
    cat > "$TEST_TMPDIR/bin/herdr" <<'EOF'
#!/bin/bash
echo "HERDR_CALL: $*" >> "$HERDR_STUB_LOG"
case "$1 $2" in
    "tab create")
        echo '{"id":"req","result":{"type":"tab_info","tab":{"tab_id":"w1:2","workspace_id":"w1","number":2,"label":"branch-x","focused":true,"pane_count":1,"agent_status":"unknown"}}}'
        ;;
    "pane list")
        echo '{"id":"req","result":{"type":"pane_list","panes":[{"pane_id":"w1-3","workspace_id":"w1","tab_id":"w1:2","focused":true}]}}'
        ;;
    "pane run")
        echo '{"id":"req","result":{"type":"ok"}}'
        ;;
esac
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/herdr"

    local cfg="$TEST_TMPDIR/cfg.yml"
    create_yaml_fixture "$cfg" "herdr:
  post_create:
    - 'pnpm dev'
    - 'tail -f log.txt'"

    PATH="$TEST_TMPDIR/bin:$PATH" run multiplexer_open_tab "branch-x" "/tmp/wt" "$cfg" 0
    [ "$status" -eq 0 ]
    log=$(cat "$HERDR_STUB_LOG")
    [[ "$log" == *"tab create --cwd /tmp/wt --label branch-x --focus"* ]]
    [[ "$log" == *"pane list"* ]]
    [[ "$log" == *"pane run w1-3 pnpm dev"* ]]
    [[ "$log" == *"pane run w1-3 tail -f log.txt"* ]]
}

@test "multiplexer_open_tab herdr without post_create skips pane lookup" {
    export WT_MULTIPLEXER="herdr"
    export HERDR_STUB_LOG="$TEST_TMPDIR/herdr.log"
    : > "$HERDR_STUB_LOG"

    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/herdr" <<'EOF'
#!/bin/bash
echo "HERDR_CALL: $*" >> "$HERDR_STUB_LOG"
echo '{"id":"req","result":{"type":"tab_info","tab":{"tab_id":"w1:2"}}}'
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/herdr"

    local cfg="$TEST_TMPDIR/cfg.yml"
    create_yaml_fixture "$cfg" "name: x"

    PATH="$TEST_TMPDIR/bin:$PATH" run multiplexer_open_tab "branch-x" "/tmp/wt" "$cfg" 0
    [ "$status" -eq 0 ]
    log=$(cat "$HERDR_STUB_LOG")
    [[ "$log" == *"tab create"* ]]
    [[ "$log" != *"pane list"* ]]
    [[ "$log" != *"pane run"* ]]
}

@test "herdr layout mount services-top-2 issues 3 splits + post_create lands in last pane" {
    export WT_MULTIPLEXER="herdr"
    export HERDR_STUB_LOG="$TEST_TMPDIR/herdr.log"
    : > "$HERDR_STUB_LOG"

    mkdir -p "$TEST_TMPDIR/bin"
    # Stub herdr that mints incrementing pane ids per split.
    cat > "$TEST_TMPDIR/bin/herdr" <<'EOF'
#!/bin/bash
log="${HERDR_STUB_LOG:-/dev/null}"
echo "HERDR_CALL: $*" >> "$log"
case "$1 $2" in
    "tab create")
        echo '{"id":"req","result":{"type":"tab_info","tab":{"tab_id":"w1:1"}}}'
        ;;
    "pane list")
        echo '{"id":"req","result":{"type":"pane_list","panes":[{"pane_id":"w1-1","tab_id":"w1:1"}]}}'
        ;;
    "pane split")
        # Use the call count to mint a fresh id (w1-2, w1-3, w1-4).
        n=$(grep -c "pane split" "$log")
        echo "{\"id\":\"req\",\"result\":{\"type\":\"pane_info\",\"pane\":{\"pane_id\":\"w1-$((n + 1))\"}}}"
        ;;
    "pane run") echo '{}' ;;
esac
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/herdr"

    local cfg="$TEST_TMPDIR/cfg.yml"
    create_yaml_fixture "$cfg" "tmux:
  layout: services-top-2
  windows:
    - name: dev
      panes:
        - service: api
        - service: web
        - command: ''
        - command: ''
services:
  - name: api
    working_dir: api
  - name: web
    working_dir: web
herdr:
  post_create:
    - 'echo orchestrator'"

    # Use real state dirs (setup_test_dirs already exported WT_STATE_DIR).
    load_lib state
    PATH="$TEST_TMPDIR/bin:$PATH" run multiplexer_open_tab "branch-x" "/tmp/wt" "$cfg" 0 "p" "branch-x"
    [ "$status" -eq 0 ]

    log=$(cat "$HERDR_STUB_LOG")
    # Exactly 3 splits for 4-pane services-top-2.
    splits=$(grep -c "pane split " <<< "$log")
    [ "$splits" -eq 3 ]
    [[ "$log" == *"pane split w1-1 --direction down"* ]]
    [[ "$log" == *"pane split w1-1 --direction right"* ]]
    # post_create should land in the LAST pane (w1-4).
    [[ "$log" == *"pane run w1-4 echo orchestrator"* ]]
    # Service panes should have got their cd commands routed.
    [[ "$log" == *"cd '/tmp/wt/api'"* ]]
    [[ "$log" == *"cd '/tmp/wt/web'"* ]]
}

@test "herdr layout mount persists service pane_id to state" {
    export WT_MULTIPLEXER="herdr"
    export HERDR_STUB_LOG="$TEST_TMPDIR/herdr.log"
    : > "$HERDR_STUB_LOG"

    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/herdr" <<'EOF'
#!/bin/bash
log="${HERDR_STUB_LOG:-/dev/null}"
echo "HERDR_CALL: $*" >> "$log"
case "$1 $2" in
    "tab create") echo '{"id":"req","result":{"type":"tab_info","tab":{"tab_id":"t1"}}}' ;;
    "pane list")  echo '{"id":"req","result":{"type":"pane_list","panes":[{"pane_id":"p1","tab_id":"t1"}]}}' ;;
    "pane split")
        n=$(grep -c "pane split" "$log")
        echo "{\"result\":{\"pane\":{\"pane_id\":\"p$((n + 1))\"}}}"
        ;;
    "pane run") echo '{}' ;;
esac
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/herdr"

    local cfg="$TEST_TMPDIR/cfg.yml"
    create_yaml_fixture "$cfg" "tmux:
  layout: services-top-2
  windows:
    - name: dev
      panes:
        - service: api
        - service: web
        - command: ''
        - command: ''
services:
  - name: api
  - name: web"

    load_lib state
    PATH="$TEST_TMPDIR/bin:$PATH" multiplexer_open_tab "branch-x" "/tmp/wt" "$cfg" 0 "p" "branch-x" >/dev/null 2>&1

    # services-top-2 split sequence (mirrors lib/tmux.sh):
    #   1. split p1 down  -> p2 (bottom-left, config[2])
    #   2. split p1 right -> p3 (top-right, config[1] = web)
    #   3. split p2 right -> p4 (bottom-right, config[3])
    # So api (config[0]) lives in p1, web (config[1]) lives in p3.
    [[ "$(get_service_state p branch-x api pane_id)" == "p1" ]]
    [[ "$(get_service_state p branch-x web pane_id)" == "p3" ]]
}

@test "multiplexer_close_tab herdr resolves label and calls tab close" {
    export WT_MULTIPLEXER="herdr"
    export HERDR_STUB_LOG="$TEST_TMPDIR/herdr.log"
    : > "$HERDR_STUB_LOG"

    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/herdr" <<'EOF'
#!/bin/bash
log="${HERDR_STUB_LOG:-/dev/null}"
echo "HERDR_CALL: $*" >> "$log"
case "$1 $2" in
    "tab list")
        echo '{"id":"req","result":{"type":"tab_list","tabs":[{"tab_id":"w1:3","label":"feature-x"}]}}'
        ;;
    "tab close") echo '{}' ;;
esac
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/herdr"

    PATH="$TEST_TMPDIR/bin:$PATH" run multiplexer_close_tab "feature-x" "/tmp/cfg.yml"
    [ "$status" -eq 0 ]
    log=$(cat "$HERDR_STUB_LOG")
    [[ "$log" == *"tab list"* ]]
    [[ "$log" == *"tab close w1:3"* ]]
}

@test "multiplexer_close_tab herdr is a no-op when label not present" {
    export WT_MULTIPLEXER="herdr"
    export HERDR_STUB_LOG="$TEST_TMPDIR/herdr.log"
    : > "$HERDR_STUB_LOG"

    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/herdr" <<'EOF'
#!/bin/bash
log="${HERDR_STUB_LOG:-/dev/null}"
echo "HERDR_CALL: $*" >> "$log"
case "$1 $2" in
    "tab list") echo '{"id":"req","result":{"type":"tab_list","tabs":[]}}' ;;
esac
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/herdr"

    PATH="$TEST_TMPDIR/bin:$PATH" run multiplexer_close_tab "ghost" "/tmp/cfg.yml" 2>&1
    [ "$status" -eq 0 ]
    log=$(cat "$HERDR_STUB_LOG")
    [[ "$log" != *"tab close"* ]]
    # Miss should now surface as a visible WARN, not silent debug.
    [[ "$output" == *"No herdr tab with label 'ghost' found"* ]]
}

@test "multiplexer_close_tab from non-herdr mux still closes the herdr tab" {
    # The realistic scenario: user runs `wt delete` from a plain shell
    # (or tmux), but the worktree was created from inside herdr and its
    # tab is still around in a running herdr session.
    export WT_MULTIPLEXER="tmux"   # detected mux is NOT herdr
    export HERDR_STUB_LOG="$TEST_TMPDIR/herdr.log"
    : > "$HERDR_STUB_LOG"

    mkdir -p "$TEST_TMPDIR/bin"
    # tmux stub: succeeds for kill_session but records nothing relevant.
    cat > "$TEST_TMPDIR/bin/tmux" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/tmux"

    cat > "$TEST_TMPDIR/bin/herdr" <<'EOF'
#!/bin/bash
log="${HERDR_STUB_LOG:-/dev/null}"
echo "HERDR_CALL: $*" >> "$log"
case "$1 $2" in
    "tab list")
        echo '{"id":"req","result":{"type":"tab_list","tabs":[{"tab_id":"w1:9","label":"orphan"}]}}'
        ;;
    "tab close") echo '{}' ;;
esac
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/herdr"

    PATH="$TEST_TMPDIR/bin:$PATH" run multiplexer_close_tab "orphan" "/tmp/cfg.yml"
    [ "$status" -eq 0 ]
    log=$(cat "$HERDR_STUB_LOG")
    [[ "$log" == *"tab close w1:9"* ]]
}

@test "multiplexer_close_tab is silent when herdr CLI is unreachable" {
    # herdr CLI exists but the daemon isn't running (tab list errors).
    export WT_MULTIPLEXER="tmux"
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/tmux" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/tmux"
    cat > "$TEST_TMPDIR/bin/herdr" <<'EOF'
#!/bin/bash
echo "herdr: failed to connect to socket" >&2
exit 1
EOF
    chmod +x "$TEST_TMPDIR/bin/herdr"

    PATH="$TEST_TMPDIR/bin:$PATH" run multiplexer_close_tab "anything" "/tmp/cfg.yml" 2>&1
    [ "$status" -eq 0 ]
    # No noise — we don't want to spam the user when herdr just isn't running.
    [[ "$output" != *"herdr"* ]] || [[ "$output" != *"failed"* ]]
}

@test "multiplexer_close_tab herdr falls back to unscoped lookup across workspaces" {
    export WT_MULTIPLEXER="herdr"
    # Simulate user running wt delete from a pane in a DIFFERENT workspace
    # than where the tab lives.
    export HERDR_ACTIVE_WORKSPACE_ID="w-other"
    export HERDR_STUB_LOG="$TEST_TMPDIR/herdr.log"
    : > "$HERDR_STUB_LOG"

    mkdir -p "$TEST_TMPDIR/bin"
    # Stub: scoped tab list (w-other) is empty; unscoped finds the tab.
    cat > "$TEST_TMPDIR/bin/herdr" <<'EOF'
#!/bin/bash
log="${HERDR_STUB_LOG:-/dev/null}"
echo "HERDR_CALL: $*" >> "$log"
case "$1 $2" in
    "tab list")
        if printf '%s\n' "$@" | grep -q -- "--workspace w-other"; then
            echo '{"id":"req","result":{"type":"tab_list","tabs":[]}}'
        else
            echo '{"id":"req","result":{"type":"tab_list","tabs":[{"tab_id":"wA:5","label":"branch-x"}]}}'
        fi
        ;;
    "tab close") echo '{}' ;;
esac
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/herdr"

    PATH="$TEST_TMPDIR/bin:$PATH" run multiplexer_close_tab "branch-x" "/tmp/cfg.yml"
    [ "$status" -eq 0 ]
    log=$(cat "$HERDR_STUB_LOG")
    [[ "$log" == *"tab list --workspace w-other"* ]]
    [[ "$log" == *"tab close wA:5"* ]]
}

@test "herdr_pane_interrupt sends C-c to target pane" {
    export HERDR_STUB_LOG="$TEST_TMPDIR/herdr.log"
    : > "$HERDR_STUB_LOG"
    # Caller is not the target — focused pane lookup returns a different id.
    unset HERDR_ACTIVE_PANE_ID

    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/herdr" <<'EOF'
#!/bin/bash
log="${HERDR_STUB_LOG:-/dev/null}"
echo "HERDR_CALL: $*" >> "$log"
case "$1 $2" in
    "pane list")
        echo '{"id":"req","result":{"type":"pane_list","panes":[{"pane_id":"caller","focused":true}]}}'
        ;;
    "pane send-keys") echo '{}' ;;
esac
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/herdr"

    PATH="$TEST_TMPDIR/bin:$PATH" run herdr_pane_interrupt "service-pane"
    [ "$status" -eq 0 ]
    log=$(cat "$HERDR_STUB_LOG")
    [[ "$log" == *"pane send-keys service-pane C-c"* ]]
}

@test "herdr_pane_interrupt skips when target is the focused pane" {
    export HERDR_ACTIVE_PANE_ID="self"
    export HERDR_STUB_LOG="$TEST_TMPDIR/herdr.log"
    : > "$HERDR_STUB_LOG"

    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/herdr" <<'EOF'
#!/bin/bash
log="${HERDR_STUB_LOG:-/dev/null}"
echo "HERDR_CALL: $*" >> "$log"
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/herdr"

    PATH="$TEST_TMPDIR/bin:$PATH" run herdr_pane_interrupt "self"
    [ "$status" -eq 0 ]
    log=$(cat "$HERDR_STUB_LOG")
    [[ "$log" != *"send-keys"* ]]
}

@test "herdr_pane_interrupt is a no-op without a target pane" {
    export HERDR_STUB_LOG="$TEST_TMPDIR/herdr.log"
    : > "$HERDR_STUB_LOG"
    mkdir -p "$TEST_TMPDIR/bin"
    printf '#!/bin/bash\necho HERDR_CALL: $* >> "$HERDR_STUB_LOG"\nexit 0\n' > "$TEST_TMPDIR/bin/herdr"
    chmod +x "$TEST_TMPDIR/bin/herdr"

    PATH="$TEST_TMPDIR/bin:$PATH" run herdr_pane_interrupt ""
    [ "$status" -eq 0 ]
    log=$(cat "$HERDR_STUB_LOG")
    [ -z "$log" ]
}

@test "multiplexer_session_label returns 'herdr' for herdr" {
    export WT_MULTIPLEXER="herdr"
    run multiplexer_session_label "/tmp/cfg.yml"
    [ "$status" -eq 0 ]
    [ "$output" = "herdr" ]
}

@test "multiplexer_session_label returns '-' for none" {
    export WT_MULTIPLEXER="none"
    run multiplexer_session_label "/tmp/cfg.yml"
    [ "$status" -eq 0 ]
    [ "$output" = "-" ]
}
