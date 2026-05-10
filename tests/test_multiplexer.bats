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
