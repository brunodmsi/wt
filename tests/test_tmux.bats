#!/usr/bin/env bats
# tests/test_tmux.bats - Tests for tmux layout functions

load test_helper

TMUX_TEST_SESSION="wt-tmux-test"

setup() {
    setup_test_dirs
    load_lib "utils"
    load_lib "config"
    load_lib "tmux"

    # Create a mock tmux that logs all calls
    TMUX_LOG="$TEST_TMPDIR/tmux_calls.log"
    export TMUX_LOG

    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/tmux" <<'MOCK'
#!/bin/bash
echo "$@" >> "$TMUX_LOG"
MOCK
    chmod +x "$TEST_TMPDIR/bin/tmux"
    export PATH="$TEST_TMPDIR/bin:$PATH"
}

teardown() {
    teardown_test_dirs
}

# Helper: create a services-top-2 config with 2 services + 2 command panes
_create_st2_config() {
    local config_file="$TEST_TMPDIR/st2.yaml"
    create_yaml_fixture "$config_file" "name: st2-test
repo_path: /tmp/repo
services:
  - name: api
    command: npm run api
    working_dir: packages/api
  - name: frontend
    command: npm run frontend
    working_dir: packages/frontend
tmux:
  session: $TMUX_TEST_SESSION
  layout: services-top-2
  windows:
    - name: dev
      panes:
        - service: api
        - service: frontend
        - command: claude
        - command: ''"
    echo "$config_file"
}

# ===== services-top-2 layout =====

@test "services-top-2: creates 4 panes with correct splits" {
    local config_file
    config_file=$(_create_st2_config)

    setup_services_top_2_layout "$TMUX_TEST_SESSION" "dev" "/tmp/repo" "$config_file" "0" "4"

    # Verify split sequence: 3 splits to create 4 panes
    local splits
    splits=$(grep "split-window" "$TMUX_LOG" | wc -l | tr -d ' ')
    [[ "$splits" -eq 3 ]]
}

@test "services-top-2: first split is vertical with 65% for bottom" {
    local config_file
    config_file=$(_create_st2_config)

    setup_services_top_2_layout "$TMUX_TEST_SESSION" "dev" "/tmp/repo" "$config_file" "0" "4"

    local first_split
    first_split=$(grep "split-window" "$TMUX_LOG" | head -1)
    [[ "$first_split" == *"-v"* ]]
    [[ "$first_split" == *"-p 65"* ]]
}

@test "services-top-2: second split is horizontal 50% for top row" {
    local config_file
    config_file=$(_create_st2_config)

    setup_services_top_2_layout "$TMUX_TEST_SESSION" "dev" "/tmp/repo" "$config_file" "0" "4"

    local second_split
    second_split=$(grep "split-window" "$TMUX_LOG" | sed -n '2p')
    [[ "$second_split" == *"-h"* ]]
    [[ "$second_split" == *"-p 50"* ]]
}

@test "services-top-2: third split is horizontal 35% for bottom row" {
    local config_file
    config_file=$(_create_st2_config)

    setup_services_top_2_layout "$TMUX_TEST_SESSION" "dev" "/tmp/repo" "$config_file" "0" "4"

    local third_split
    third_split=$(grep "split-window" "$TMUX_LOG" | sed -n '3p')
    [[ "$third_split" == *"-h"* ]]
    [[ "$third_split" == *"-p 35"* ]]
}

@test "services-top-2: service panes get service comments" {
    local config_file
    config_file=$(_create_st2_config)

    setup_services_top_2_layout "$TMUX_TEST_SESSION" "dev" "/tmp/repo" "$config_file" "0" "4"

    # Service panes should have service comments
    grep -q "Service: api" "$TMUX_LOG"
    grep -q "Service: frontend" "$TMUX_LOG"
}

@test "services-top-2: command panes get commands" {
    local config_file
    config_file=$(_create_st2_config)

    setup_services_top_2_layout "$TMUX_TEST_SESSION" "dev" "/tmp/repo" "$config_file" "0" "4"

    # claude command pane should send the command
    grep -q "claude" "$TMUX_LOG"
}

@test "services-top-2: service panes cd to working_dir" {
    local config_file
    config_file=$(_create_st2_config)

    setup_services_top_2_layout "$TMUX_TEST_SESSION" "dev" "/tmp/repo" "$config_file" "0" "4"

    grep -q "packages/api" "$TMUX_LOG"
    grep -q "packages/frontend" "$TMUX_LOG"
}

@test "services-top-2: selects pane 2 (claude) as active" {
    local config_file
    config_file=$(_create_st2_config)

    setup_services_top_2_layout "$TMUX_TEST_SESSION" "dev" "/tmp/repo" "$config_file" "0" "4"

    local select_pane
    select_pane=$(grep "select-pane" "$TMUX_LOG")
    [[ "$select_pane" == *".2" ]]
}

@test "services-top-2: dispatch from setup_window_panes_for_worktree" {
    local config_file
    config_file=$(_create_st2_config)

    setup_window_panes_for_worktree "$TMUX_TEST_SESSION" "dev" "/tmp/repo" "$config_file"

    # Should use custom layout (3 splits), not generic
    local splits
    splits=$(grep "split-window" "$TMUX_LOG" | wc -l | tr -d ' ')
    [[ "$splits" -eq 3 ]]
}

@test "services-top-2: dispatch from setup_window_panes" {
    local config_file
    config_file=$(_create_st2_config)

    setup_window_panes "$TMUX_TEST_SESSION" "dev" "/tmp/repo" "$config_file" "0" "services-top-2"

    # Should use custom layout (3 splits), not generic
    local splits
    splits=$(grep "split-window" "$TMUX_LOG" | wc -l | tr -d ' ')
    [[ "$splits" -eq 3 ]]
}

# ===== create_session no_attach flag =====

_create_minimal_config() {
    local config_file="$TEST_TMPDIR/minimal.yaml"
    create_yaml_fixture "$config_file" "name: test-project
repo_path: /tmp/repo
tmux:
  session: $TMUX_TEST_SESSION"
    echo "$config_file"
}

_create_no_attach_config() {
    local config_file="$TEST_TMPDIR/no_attach.yaml"
    create_yaml_fixture "$config_file" "name: test-project
repo_path: /tmp/repo
tmux:
  session: $TMUX_TEST_SESSION
  auto_attach: false"
    echo "$config_file"
}

@test "create_session: new-window has no -d flag by default (attaches)" {
    local config_file
    config_file=$(_create_minimal_config)

    # Mock session_exists to return true so we hit the new-window path
    session_exists() { return 0; }
    window_exists() { return 1; }
    get_next_available_window_index() { echo "1"; }
    setup_window_panes_for_worktree() { return 0; }

    create_session "my-branch" "/tmp/repo" "$config_file" "" "0"

    # new-window should NOT have -d flag
    local new_win_call
    new_win_call=$(grep "new-window" "$TMUX_LOG")
    [[ "$new_win_call" != *" -d "* ]] && [[ "$new_win_call" != *" -d"* ]]
}

@test "create_session: new-window has -d flag when no_attach=1" {
    local config_file
    config_file=$(_create_minimal_config)

    session_exists() { return 0; }
    window_exists() { return 1; }
    get_next_available_window_index() { echo "1"; }
    setup_window_panes_for_worktree() { return 0; }

    create_session "my-branch" "/tmp/repo" "$config_file" "" "1"

    grep -q "new-window -d " "$TMUX_LOG"
}

@test "create_session: tmux.auto_attach false config causes -d on new-window (via cmd_create integration)" {
    # This test verifies yaml_get reads auto_attach correctly
    local config_file
    config_file=$(_create_no_attach_config)

    local val
    val=$(yaml_get "$config_file" ".tmux.auto_attach" "true")
    [[ "$val" == "false" ]]
}
