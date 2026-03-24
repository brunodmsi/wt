#!/usr/bin/env bats
# tests/test_service.bats - Unit tests for lib/service.sh

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
}

teardown() {
    teardown_test_dirs
}

# --- find_service_pane_index ---

@test "find_service_pane_index returns index for matching service" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'tmux:
  windows:
    - name: dev
      panes:
        - service: api
        - service: web
        - command: echo shell'

    result=$(find_service_pane_index "$TEST_TMPDIR/config.yaml" "api")
    [[ "$result" == "0" ]]
}

@test "find_service_pane_index returns correct index for second service" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'tmux:
  windows:
    - name: dev
      panes:
        - service: api
        - service: web
        - command: echo shell'

    result=$(find_service_pane_index "$TEST_TMPDIR/config.yaml" "web")
    [[ "$result" == "1" ]]
}

@test "find_service_pane_index returns empty for unknown service" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'tmux:
  windows:
    - name: dev
      panes:
        - service: api'

    run find_service_pane_index "$TEST_TMPDIR/config.yaml" "nonexistent"
    [[ "$status" -ne 0 ]]
    [[ "$output" == "" ]]
}

@test "find_service_pane_index skips command panes" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'tmux:
  windows:
    - name: dev
      panes:
        - command: echo shell
        - service: api'

    result=$(find_service_pane_index "$TEST_TMPDIR/config.yaml" "api")
    [[ "$result" == "1" ]]
}

# --- get_service_status ---

@test "get_service_status returns unknown for no state" {
    create_worktree_state "testproj" "main" "/tmp" 0
    result=$(get_service_status "testproj" "main" "api")
    [[ "$result" == "unknown" ]]
}

@test "get_service_status returns running after update" {
    create_worktree_state "testproj" "main" "/tmp" 0
    update_service_status "testproj" "main" "api" "running" "" "3000"
    result=$(get_service_status "testproj" "main" "api")
    [[ "$result" == "running" ]]
}

@test "get_service_status returns stopped after update" {
    create_worktree_state "testproj" "main" "/tmp" 0
    update_service_status "testproj" "main" "api" "running" "" "3000"
    update_service_status "testproj" "main" "api" "stopped"
    result=$(get_service_status "testproj" "main" "api")
    [[ "$result" == "stopped" ]]
}

# --- stop_service / stop_all_services graceful error handling ---

@test "stop_service does not abort when pane index not found" {
    create_worktree_state "testproj" "main" "/tmp" 0
    update_service_status "testproj" "main" "api" "running" "" "3000"

    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'services:
  - name: api
    command: echo hi
tmux:
  session: test
  windows:
    - name: dev
      panes:
        - command: echo shell'

    # stop_service should not abort even though api is not in pane config
    # (tmux commands will fail since no session exists, but the function should
    # still reach the state update)
    run stop_service "testproj" "main" "api" "$TEST_TMPDIR/config.yaml"
    [[ "$status" -eq 0 ]]

    result=$(get_service_status "testproj" "main" "api")
    [[ "$result" == "stopped" ]]
}

@test "stop_all_services stops all services even if one fails to find pane" {
    create_worktree_state "testproj" "main" "/tmp" 0
    update_service_status "testproj" "main" "api" "running" "" "3000"
    update_service_status "testproj" "main" "web" "running" "" "3001"

    # Neither service is mapped to a pane
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'services:
  - name: api
    command: echo api
  - name: web
    command: echo web
tmux:
  session: test
  windows:
    - name: dev
      panes:
        - command: echo shell'

    stop_all_services "testproj" "main" "$TEST_TMPDIR/config.yaml" 2>/dev/null || true

    result_api=$(get_service_status "testproj" "main" "api")
    result_web=$(get_service_status "testproj" "main" "web")
    [[ "$result_api" == "stopped" ]]
    [[ "$result_web" == "stopped" ]]
}

# --- service start/stop require tmux, tested in e2e ---
# These are integration-level tests that need tmux sessions.
# The core logic is verified through the state and port tests above.
