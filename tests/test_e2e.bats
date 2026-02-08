#!/usr/bin/env bats
# tests/test_e2e.bats - End-to-end integration test

load test_helper

E2E_SESSION="wt-e2e-test"

setup() {
    setup_test_dirs

    # Source all libs like wt.sh does
    load_lib "utils"

    if ! command_exists tmux; then
        skip "tmux not available"
    fi
    load_lib "config"
    load_lib "port"
    load_lib "state"
    load_lib "worktree"
    load_lib "setup"
    load_lib "tmux"
    load_lib "service"
    source "$WT_SCRIPT_DIR/commands/doctor.sh"
    source "$WT_SCRIPT_DIR/commands/send.sh"
    source "$WT_SCRIPT_DIR/commands/logs.sh"
    source "$WT_SCRIPT_DIR/commands/panes.sh"
}

teardown() {
    tmux kill-session -t "$E2E_SESSION" 2>/dev/null || true
    teardown_test_dirs
}

@test "e2e: full lifecycle with tmux session" {
    local project="e2e-project"

    # 1. Create project config
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: $project
repo_path: /tmp
tmux:
  session: $E2E_SESSION
  layout: tiled
  windows:
    - name: main
      panes:
        - service: web
        - command: echo shell
services:
  - name: web
    command: echo running-web
    working_dir: .
    port_key: web
ports:
  reserved:
    range:
      min: 3000
      max: 3010
    services:
      web: 0
  dynamic:
    range:
      min: 4000
      max: 5000"

    # 2. Verify doctor detects the project
    run cmd_doctor -p "$project" 2>&1
    [[ "$output" == *"PASS"* ]]
    [[ "$output" == *"$project"* ]]

    # 3. Create worktree state
    create_worktree_state "$project" "main" "/tmp" 0

    # 4. Create tmux session with a window
    tmux new-session -d -s "$E2E_SESSION" -n "main"
    tmux resize-window -t "$E2E_SESSION" -x 200 -y 50
    tmux split-window -t "$E2E_SESSION:main"

    # 5. Verify panes shows layout
    run list_window_panes "$E2E_SESSION" "main"
    [[ "$status" -eq 0 ]]
    local pane_count
    pane_count=$(echo "$output" | wc -l | tr -d ' ')
    (( pane_count >= 2 ))

    # 6. Send a command to pane 0
    send_to_pane "$E2E_SESSION" "main" "0" "echo e2e-marker-12345"
    sleep 0.5

    # 7. Capture output and verify
    run capture_pane "$E2E_SESSION" "main" "0" 50
    [[ "$output" == *"e2e-marker-12345"* ]]

    # 8. Verify state round-trip
    local branch_state
    branch_state=$(get_worktree_state "$project" "main" "branch")
    [[ "$branch_state" == "main" ]]
}

@test "e2e: doctor summary counts" {
    local project="e2e-counts"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: $project
repo_path: /tmp
ports:
  reserved:
    range:
      min: 3000
      max: 3010
  dynamic:
    range:
      min: 4000
      max: 5000
services: []"

    run cmd_doctor -p "$project" 2>&1
    [[ "$output" == *"Summary"* ]]
    [[ "$output" == *"passed"* ]]
    [[ "$output" == *"failed"* ]]
    [[ "$output" == *"warnings"* ]]
}
