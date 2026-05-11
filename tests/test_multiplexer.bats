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
    [[ "$output" != *"herdr backend"* ]]
}

@test "multiplexer_warn_dropped_features warns under herdr with multi-pane config" {
    export WT_MULTIPLEXER="herdr"
    local cfg="$TEST_TMPDIR/cfg.yml"
    create_yaml_fixture "$cfg" "tmux:
  windows:
    - name: dev
      panes:
        - command: 'a'
        - command: 'b'
        - command: 'c'
services:
  - name: svc-a"
    run multiplexer_warn_dropped_features "$cfg"
    [ "$status" -eq 0 ]
    [[ "$output" == *"herdr backend"* ]]
    [[ "$output" == *"Panes in config: 3"* ]]
    [[ "$output" == *"Services: 1"* ]]
}

@test "multiplexer_warn_dropped_features silent under herdr with single-pane no-services config" {
    export WT_MULTIPLEXER="herdr"
    local cfg="$TEST_TMPDIR/cfg.yml"
    create_yaml_fixture "$cfg" "tmux:
  windows:
    - name: dev
      panes:
        - command: 'a'"
    run multiplexer_warn_dropped_features "$cfg"
    [ "$status" -eq 0 ]
    [[ "$output" != *"herdr backend"* ]]
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
