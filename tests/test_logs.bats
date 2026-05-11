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
    load_lib "multiplexer"
    load_lib "tmux"
    load_lib "service"
    source "$WT_SCRIPT_DIR/commands/logs.sh"
}

# Tmux-dependent tests use this; herdr/none tests below don't need it.
require_tmux() {
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
    [[ "$output" == *"Display log output"* ]]
}

@test "logs errors without branch when outside worktree" {
    run cmd_logs 2>&1
    [[ "$status" -ne 0 ]]
}

@test "logs captures pane output from tmux" {
    require_tmux
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
    [[ "$output" == *"Display log output"* ]]
}

# --- herdr fallback (reads on-disk log files instead of tmux panes) ---

@test "logs under herdr tails the service log file" {
    export WT_MULTIPLEXER="herdr"
    local project="logsherdr"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: $project
repo_path: /tmp
services:
  - name: api
    command: echo hi"

    create_worktree_state "$project" "main" "/tmp" 0
    local log_file
    log_file=$(get_service_log_path "$project" "main" "api")
    printf 'line1\nline2\nMARKER_HERDR_LOG\n' > "$log_file"

    run cmd_logs main api -p "$project"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MARKER_HERDR_LOG"* ]]
}

@test "logs --all under herdr iterates each configured service" {
    export WT_MULTIPLEXER="herdr"
    local project="logsherdrall"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: $project
repo_path: /tmp
services:
  - name: api
    command: echo hi
  - name: worker
    command: echo bye"

    create_worktree_state "$project" "main" "/tmp" 0
    printf 'API_LOG_LINE\n' > "$(get_service_log_path "$project" main api)"
    printf 'WORKER_LOG_LINE\n' > "$(get_service_log_path "$project" main worker)"

    run cmd_logs main --all -p "$project"
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== api ==="* ]]
    [[ "$output" == *"API_LOG_LINE"* ]]
    [[ "$output" == *"=== worker ==="* ]]
    [[ "$output" == *"WORKER_LOG_LINE"* ]]
}

@test "logs under herdr rejects numeric pane index" {
    export WT_MULTIPLEXER="herdr"
    local project="logsherdrnum"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: $project
repo_path: /tmp
services:
  - name: api
    command: echo hi"

    create_worktree_state "$project" "main" "/tmp" 0
    run cmd_logs main 0 -p "$project" 2>&1
    [ "$status" -ne 0 ]
    [[ "$output" == *"Numeric pane targets"* ]]
}

@test "logs under herdr reports missing log file gracefully" {
    export WT_MULTIPLEXER="herdr"
    local project="logsherdrnolog"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: $project
repo_path: /tmp
services:
  - name: api
    command: echo hi"

    create_worktree_state "$project" "main" "/tmp" 0
    run cmd_logs main api -p "$project" 2>&1
    [ "$status" -ne 0 ]
    [[ "$output" == *"No log file"* ]]
}
