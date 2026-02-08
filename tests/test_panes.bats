#!/usr/bin/env bats
# tests/test_panes.bats - Integration tests for wt panes command

load test_helper

setup() {
    setup_test_dirs
    load_lib "utils"
    load_lib "config"
    load_lib "port"
    load_lib "state"
    load_lib "worktree"
    load_lib "setup"
    load_lib "tmux"
    load_lib "service"
    source "$WT_SCRIPT_DIR/commands/panes.sh"

    if ! command_exists tmux; then
        skip "tmux not available"
    fi

    # Ensure clean state
    tmux kill-session -t "wt-test-panes" 2>/dev/null || true
}

teardown() {
    tmux kill-session -t "wt-test-panes" 2>/dev/null || true
    teardown_test_dirs
}

@test "panes shows help with --help" {
    run cmd_panes --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"List tmux panes"* ]]
}

@test "panes errors without branch when outside worktree" {
    run cmd_panes 2>&1
    [[ "$status" -ne 0 ]]
}

@test "list_window_panes returns pane info" {
    tmux new-session -d -s "wt-test-panes" -n "testwin" -x 200 -y 50

    run list_window_panes "wt-test-panes" "testwin"
    [[ "$status" -eq 0 ]]
    # Should contain pane 0 info
    [[ "$output" == *"0:"* ]]
}

@test "list_window_panes shows multiple panes after split" {
    tmux new-session -d -s "wt-test-panes" -n "testwin"
    tmux resize-window -t "wt-test-panes" -x 200 -y 50
    tmux split-window -t "wt-test-panes:testwin"

    run list_window_panes "wt-test-panes" "testwin"
    [[ "$status" -eq 0 ]]
    # Should have at least 2 lines (2 panes)
    local line_count
    line_count=$(echo "$output" | wc -l | tr -d ' ')
    (( line_count >= 2 ))
}
