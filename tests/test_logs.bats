#!/usr/bin/env bats
# tests/test_logs.bats - Integration tests for wt logs command

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
    source "$WT_SCRIPT_DIR/commands/logs.sh"

    if ! command_exists tmux; then
        skip "tmux not available"
    fi
}

teardown() {
    tmux kill-session -t "wt-test-logs" 2>/dev/null || true
    teardown_test_dirs
}

@test "logs shows help with --help" {
    run cmd_logs --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Capture"* ]]
}

@test "logs errors without branch when outside worktree" {
    run cmd_logs 2>&1
    [[ "$status" -ne 0 ]]
}

@test "logs captures pane output from tmux" {
    local project="logstest"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: logstest
repo_path: /tmp
tmux:
  session: wt-test-logs
  windows:
    - name: test
      panes:
        - command: echo hello
services: []"

    # Create tmux session and send a known command
    tmux new-session -d -s "wt-test-logs" -n "main" -x 200 -y 50
    tmux send-keys -t "wt-test-logs:main.0" "echo wt-logs-test-marker" Enter
    sleep 0.5

    create_worktree_state "$project" "main" "/tmp" 0

    run capture_pane "wt-test-logs" "main" "0" 50
    [[ "$output" == *"wt-logs-test-marker"* ]]
}

@test "logs --all flag is accepted" {
    run cmd_logs --all --help 2>&1
    # --help takes precedence
    [[ "$output" == *"Capture"* ]]
}
