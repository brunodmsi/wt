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

# --- pane self-detection: no C-c when calling from the service pane ---

@test "start_service skips C-c when TMUX_PANE matches service pane" {
    export WT_LOG_DIR="$TEST_TMPDIR/logs"

    TMUX_LOG="$TEST_TMPDIR/tmux_calls.log"
    export TMUX_LOG

    mkdir -p "$TEST_TMPDIR/mockbin"
    cat > "$TEST_TMPDIR/mockbin/tmux" <<'MOCK'
#!/bin/bash
echo "$@" >> "$TMUX_LOG"
# Return a fake pane_id of %5 for display-message queries
if [[ "$*" == *"display-message"* ]]; then
    echo "%5"
fi
exit 0
MOCK
    chmod +x "$TEST_TMPDIR/mockbin/tmux"
    export PATH="$TEST_TMPDIR/mockbin:$PATH"

    # Simulate being inside the service pane (%5)
    export TMUX_PANE="%5"

    local repo="$TEST_TMPDIR/repo_self"
    git init "$repo" --initial-branch=main > /dev/null 2>&1 || git init "$repo" > /dev/null 2>&1
    git -C "$repo" commit --allow-empty -m "init" > /dev/null 2>&1
    create_worktree_state "testproj3" "main" "$repo" 0

    create_yaml_fixture "$TEST_TMPDIR/config3.yaml" "name: testproj3
repo_path: $repo
ports:
  reserved:
    range: {min: 19020, max: 19025}
    slots: 3
    services:
      api: 0
services:
  - name: api
    command: sleep 60
    port_key: api
tmux:
  session: test
  windows:
    - name: dev
      panes:
        - service: api"

    export PROJECT_CONFIG_FILE="$TEST_TMPDIR/config3.yaml"
    claim_slot "testproj3" "main" 3

    start_service "testproj3" "main" "api" "$TEST_TMPDIR/config3.yaml"

    # C-c must NOT appear in tmux calls
    ! grep -q "send-keys.*C-c" "$TMUX_LOG"

    # tail -f must still be queued
    grep -q "tail" "$TMUX_LOG"

    local stored_pid
    stored_pid=$(get_service_state "testproj3" "main" "api" "pid")
    kill "$stored_pid" 2>/dev/null || true
}

@test "start_service sends C-c when TMUX_PANE differs from service pane" {
    export WT_LOG_DIR="$TEST_TMPDIR/logs"

    TMUX_LOG="$TEST_TMPDIR/tmux_calls2.log"
    export TMUX_LOG

    mkdir -p "$TEST_TMPDIR/mockbin2"
    cat > "$TEST_TMPDIR/mockbin2/tmux" <<'MOCK'
#!/bin/bash
echo "$@" >> "$TMUX_LOG"
if [[ "$*" == *"display-message"* ]]; then
    echo "%5"
fi
exit 0
MOCK
    chmod +x "$TEST_TMPDIR/mockbin2/tmux"
    export PATH="$TEST_TMPDIR/mockbin2:$PATH"

    # Simulate being in a DIFFERENT pane (%9)
    export TMUX_PANE="%9"

    local repo="$TEST_TMPDIR/repo_other"
    git init "$repo" --initial-branch=main > /dev/null 2>&1 || git init "$repo" > /dev/null 2>&1
    git -C "$repo" commit --allow-empty -m "init" > /dev/null 2>&1
    create_worktree_state "testproj4" "main" "$repo" 0

    create_yaml_fixture "$TEST_TMPDIR/config4.yaml" "name: testproj4
repo_path: $repo
ports:
  reserved:
    range: {min: 19030, max: 19035}
    slots: 3
    services:
      api: 0
services:
  - name: api
    command: sleep 60
    port_key: api
tmux:
  session: test
  windows:
    - name: dev
      panes:
        - service: api"

    export PROJECT_CONFIG_FILE="$TEST_TMPDIR/config4.yaml"
    claim_slot "testproj4" "main" 3

    start_service "testproj4" "main" "api" "$TEST_TMPDIR/config4.yaml"

    # C-c MUST appear since we're in a different pane
    grep -q "send-keys.*C-c" "$TMUX_LOG"

    local stored_pid
    stored_pid=$(get_service_state "testproj4" "main" "api" "pid")
    kill "$stored_pid" 2>/dev/null || true
}

# --- get_service_log_path ---

@test "get_service_log_path returns path under WT_LOG_DIR" {
    export WT_LOG_DIR="$TEST_TMPDIR/logs"
    result=$(get_service_log_path "myproj" "feature/auth" "api")
    [[ "$result" == "$TEST_TMPDIR/logs/myproj/feature-auth/api.log" ]]
}

@test "get_service_log_path creates log directory" {
    export WT_LOG_DIR="$TEST_TMPDIR/logs"
    get_service_log_path "myproj" "feature/auth" "api" > /dev/null
    [[ -d "$TEST_TMPDIR/logs/myproj/feature-auth" ]]
}

# --- stop_service kills by PID ---

@test "stop_service kills process by PID" {
    export WT_LOG_DIR="$TEST_TMPDIR/logs"
    create_worktree_state "testproj" "main" "/tmp" 0

    # Start a real background process and record its PID
    sleep 60 &
    local test_pid=$!
    update_service_status "testproj" "main" "api" "running" "$test_pid" "3000"

    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'services:
  - name: api
    command: sleep 60
tmux:
  session: test
  windows:
    - name: dev
      panes:
        - service: api'

    stop_service "testproj" "main" "api" "$TEST_TMPDIR/config.yaml"

    # Process should be gone
    ! kill -0 "$test_pid" 2>/dev/null
}

@test "stop_service updates state to stopped" {
    export WT_LOG_DIR="$TEST_TMPDIR/logs"
    create_worktree_state "testproj" "main" "/tmp" 0

    sleep 60 &
    local test_pid=$!
    update_service_status "testproj" "main" "api" "running" "$test_pid" "3000"

    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'services:
  - name: api
    command: sleep 60
tmux:
  session: test
  windows:
    - name: dev
      panes:
        - service: api'

    stop_service "testproj" "main" "api" "$TEST_TMPDIR/config.yaml"

    result=$(get_service_status "testproj" "main" "api")
    [[ "$result" == "stopped" ]]
}

@test "stop_service handles missing PID gracefully" {
    export WT_LOG_DIR="$TEST_TMPDIR/logs"
    create_worktree_state "testproj" "main" "/tmp" 0
    update_service_status "testproj" "main" "api" "running" "" "3000"

    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'services:
  - name: api
    command: sleep 60
tmux:
  session: test'

    # Should not fail even with no PID
    run stop_service "testproj" "main" "api" "$TEST_TMPDIR/config.yaml"
    [[ "$status" -eq 0 ]]

    result=$(get_service_status "testproj" "main" "api")
    [[ "$result" == "stopped" ]]
}

# --- start_service uses bg process + tail -f ---

@test "start_service stores PID in state" {
    export WT_LOG_DIR="$TEST_TMPDIR/logs"

    # Set up a real git repo and worktree path
    local repo="$TEST_TMPDIR/repo"
    git init "$repo" --initial-branch=main > /dev/null 2>&1 || git init "$repo" > /dev/null 2>&1
    git -C "$repo" commit --allow-empty -m "init" > /dev/null 2>&1

    create_worktree_state "testproj" "main" "$repo" 0

    # Mock tmux to swallow all calls
    mkdir -p "$TEST_TMPDIR/bin"
    printf '#!/bin/bash\nexit 0\n' > "$TEST_TMPDIR/bin/tmux"
    chmod +x "$TEST_TMPDIR/bin/tmux"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    create_yaml_fixture "$TEST_TMPDIR/config.yaml" "name: testproj
repo_path: $repo
ports:
  reserved:
    range: {min: 19000, max: 19005}
    slots: 3
    services:
      api: 0
services:
  - name: api
    command: sleep 60
    port_key: api
tmux:
  session: test
  windows:
    - name: dev
      panes:
        - service: api"

    export PROJECT_CONFIG_FILE="$TEST_TMPDIR/config.yaml"
    claim_slot "testproj" "main" 3

    start_service "testproj" "main" "api" "$TEST_TMPDIR/config.yaml"

    local stored_pid
    stored_pid=$(get_service_state "testproj" "main" "api" "pid")
    [[ -n "$stored_pid" ]] && [[ "$stored_pid" != "null" ]]

    # Clean up the background sleep
    kill "$stored_pid" 2>/dev/null || true
}

@test "start_service creates log file" {
    export WT_LOG_DIR="$TEST_TMPDIR/logs"

    local repo="$TEST_TMPDIR/repo2"
    git init "$repo" --initial-branch=main > /dev/null 2>&1 || git init "$repo" > /dev/null 2>&1
    git -C "$repo" commit --allow-empty -m "init" > /dev/null 2>&1

    create_worktree_state "testproj2" "main" "$repo" 0

    mkdir -p "$TEST_TMPDIR/bin"
    printf '#!/bin/bash\nexit 0\n' > "$TEST_TMPDIR/bin/tmux"
    chmod +x "$TEST_TMPDIR/bin/tmux"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    create_yaml_fixture "$TEST_TMPDIR/config2.yaml" "name: testproj2
repo_path: $repo
ports:
  reserved:
    range: {min: 3010, max: 3015}
    slots: 3
    services:
      api: 0
services:
  - name: api
    command: sleep 60
    port_key: api
tmux:
  session: test"

    export PROJECT_CONFIG_FILE="$TEST_TMPDIR/config2.yaml"
    claim_slot "testproj2" "main" 3

    start_service "testproj2" "main" "api" "$TEST_TMPDIR/config2.yaml"

    local log_file
    log_file=$(get_service_log_path "testproj2" "main" "api")
    [[ -f "$log_file" ]]

    local stored_pid
    stored_pid=$(get_service_state "testproj2" "main" "api" "pid")
    kill "$stored_pid" 2>/dev/null || true
}
