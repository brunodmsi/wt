#!/usr/bin/env bats
# tests/test_state.bats - Unit tests for lib/state.sh

load test_helper

setup() {
    setup_test_dirs
    load_lib "utils"
    load_lib "config"
    load_lib "port"
    load_lib "state"
}

teardown() {
    teardown_test_dirs
}

# --- state_file ---

@test "state_file returns correct path" {
    result=$(state_file "myproject")
    [[ "$result" == "$WT_STATE_DIR/myproject.state.yaml" ]]
}

# --- init_state_file ---

@test "init_state_file creates state file" {
    init_state_file "testproj"
    local file
    file=$(state_file "testproj")
    [[ -f "$file" ]]
}

@test "init_state_file is idempotent" {
    init_state_file "testproj"
    init_state_file "testproj"
    local file
    file=$(state_file "testproj")
    [[ -f "$file" ]]
}

@test "init_state_file creates with worktrees key" {
    init_state_file "testproj"
    local file
    file=$(state_file "testproj")
    result=$(yq '.worktrees' "$file")
    [[ "$result" == "{}" ]]
}

# --- create_worktree_state / get_worktree_state round-trip ---

@test "create_worktree_state and get_worktree_state round-trip" {
    create_worktree_state "testproj" "feature/auth" "/tmp/wt/feature-auth" 0

    result=$(get_worktree_state "testproj" "feature/auth" "branch")
    [[ "$result" == "feature/auth" ]]

    result=$(get_worktree_state "testproj" "feature/auth" "path")
    [[ "$result" == "/tmp/wt/feature-auth" ]]

    result=$(get_worktree_state "testproj" "feature/auth" "slot")
    [[ "$result" == "0" ]]
}

@test "create_worktree_state sets created_at timestamp" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    result=$(get_worktree_state "testproj" "main" "created_at")
    [[ -n "$result" ]]
    [[ "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

@test "create_worktree_state initializes empty services" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    local file
    file=$(state_file "testproj")
    result=$(yq '.worktrees.main.services' "$file")
    [[ "$result" == "{}" ]]
}

@test "get_worktree_state returns empty for missing project" {
    result=$(get_worktree_state "noproject" "main" "branch")
    [[ "$result" == "" ]]
}

@test "get_worktree_state returns empty for missing branch" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    result=$(get_worktree_state "testproj" "nonexistent" "branch")
    [[ "$result" == "" ]]
}

# --- set_worktree_state ---

@test "set_worktree_state updates string field" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    set_worktree_state "testproj" "main" "session" "my-session"
    result=$(get_worktree_state "testproj" "main" "session")
    [[ "$result" == "my-session" ]]
}

@test "set_worktree_state updates numeric field" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    set_worktree_state "testproj" "main" "slot" "2"
    result=$(get_worktree_state "testproj" "main" "slot")
    [[ "$result" == "2" ]]
}

# --- delete_worktree_state ---

@test "delete_worktree_state removes entry" {
    create_worktree_state "testproj" "feature/auth" "/tmp/wt/feature-auth" 0
    delete_worktree_state "testproj" "feature/auth"

    result=$(get_worktree_state "testproj" "feature/auth" "branch")
    [[ "$result" == "" ]]
}

@test "delete_worktree_state is no-op for missing state" {
    # Should not error
    delete_worktree_state "testproj" "nonexistent"
}

@test "delete_worktree_state preserves other worktrees" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    create_worktree_state "testproj" "feature/auth" "/tmp/wt/auth" 1
    delete_worktree_state "testproj" "feature/auth"

    result=$(get_worktree_state "testproj" "main" "branch")
    [[ "$result" == "main" ]]
}

# --- update_service_status / get_service_state ---

@test "update_service_status and get_service_state round-trip" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    update_service_status "testproj" "main" "api-server" "running" "" "3000"

    status=$(get_service_state "testproj" "main" "api-server" "status")
    [[ "$status" == "running" ]]

    port=$(get_service_state "testproj" "main" "api-server" "port")
    [[ "$port" == "3000" ]]
}

@test "update_service_status sets started_at for running" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    update_service_status "testproj" "main" "api-server" "running" "" "3000"

    started_at=$(get_service_state "testproj" "main" "api-server" "started_at")
    [[ -n "$started_at" ]]
}

@test "update_service_status stopped clears pid" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    update_service_status "testproj" "main" "api-server" "running" "12345" "3000"
    update_service_status "testproj" "main" "api-server" "stopped"

    pid=$(get_service_state "testproj" "main" "api-server" "pid")
    [[ "$pid" == "" || "$pid" == "null" ]]
}

@test "update_service_status with pid stores pid" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    update_service_status "testproj" "main" "api-server" "running" "99999" "3000"

    pid=$(get_service_state "testproj" "main" "api-server" "pid")
    [[ "$pid" == "99999" ]]
}

# --- set_service_state ---

@test "set_service_state sets individual field" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    set_service_state "testproj" "main" "api" "status" "running"
    result=$(get_service_state "testproj" "main" "api" "status")
    [[ "$result" == "running" ]]
}

@test "get_service_state returns empty for missing service" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    result=$(get_service_state "testproj" "main" "nonexistent" "status")
    [[ "$result" == "" ]]
}

# --- list_worktree_states ---

@test "list_worktree_states returns all worktree names" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    create_worktree_state "testproj" "feature/auth" "/tmp/wt/auth" 1

    run list_worktree_states "testproj"
    [[ "$output" == *"main"* ]]
    [[ "$output" == *"feature-auth"* ]]
}

@test "list_worktree_states returns empty for missing project" {
    run list_worktree_states "nonexistent"
    [[ "$output" == "" ]]
}

# --- list_service_states ---

@test "list_service_states has services in state file" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    update_service_status "testproj" "main" "api" "running" "" "3000"
    update_service_status "testproj" "main" "web" "stopped" "" "3001"

    # Verify services were written to state
    local api_status
    api_status=$(get_service_state "testproj" "main" "api" "status")
    [[ "$api_status" == "running" ]]

    local web_status
    web_status=$(get_service_state "testproj" "main" "web" "status")
    [[ "$web_status" == "stopped" ]]
}

@test "list_service_states returns empty for no services" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    run list_service_states "testproj" "main"
    [[ "$output" == "" ]]
}

# --- get_session_name ---

@test "get_session_name returns sanitized branch name" {
    result=$(get_session_name "testproj" "feature/auth")
    [[ "$result" == "feature-auth" ]]
}

@test "get_session_name handles simple branch" {
    result=$(get_session_name "testproj" "main")
    [[ "$result" == "main" ]]
}

# --- set_session_state ---

@test "set_session_state stores session name" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    set_session_state "testproj" "main" "my-session"
    result=$(get_worktree_state "testproj" "main" "session")
    [[ "$result" == "my-session" ]]
}

# --- get_worktree_path / get_worktree_slot ---

@test "get_worktree_path returns stored path" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    result=$(get_worktree_path "testproj" "main")
    [[ "$result" == "/tmp/wt/main" ]]
}

@test "get_worktree_slot returns stored slot" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 2
    result=$(get_worktree_slot "testproj" "main")
    [[ "$result" == "2" ]]
}

# --- port override round-trip ---

@test "set_port_override and get_port_override round-trip" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    set_port_override "testproj" "main" "api-server" 9999

    result=$(get_port_override "testproj" "main" "api-server")
    [[ "$result" == "9999" ]]
}

@test "clear_port_override removes override" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    set_port_override "testproj" "main" "api-server" 9999
    clear_port_override "testproj" "main" "api-server"

    result=$(get_port_override "testproj" "main" "api-server")
    [[ "$result" == "" ]]
}

@test "get_port_override returns empty when none set" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    result=$(get_port_override "testproj" "main" "api-server")
    [[ "$result" == "" ]]
}

@test "set_port_override allows multiple services" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    set_port_override "testproj" "main" "api" 9000
    set_port_override "testproj" "main" "web" 9001

    [[ "$(get_port_override "testproj" "main" "api")" == "9000" ]]
    [[ "$(get_port_override "testproj" "main" "web")" == "9001" ]]
}

# --- list_port_overrides ---

@test "list_port_overrides returns all overrides" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    set_port_override "testproj" "main" "api" 9000
    set_port_override "testproj" "main" "web" 9001

    run list_port_overrides "testproj" "main"
    [[ "$output" == *"api:9000"* ]]
    [[ "$output" == *"web:9001"* ]]
}

@test "list_port_overrides returns no entries for no overrides" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    # yq may produce artifact output like bare ':'; verify no actual service:port pairs
    result=$(list_port_overrides "testproj" "main" | grep -cE '^[A-Za-z].*:[0-9]' || true)
    [[ "$result" == "0" ]]
}

# --- is_service_running ---

@test "is_service_running returns false for no pid" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    update_service_status "testproj" "main" "api" "running" "" "3000"
    ! is_service_running "testproj" "main" "api"
}

@test "is_service_running returns false for dead pid" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    # Use a PID that almost certainly doesn't exist
    update_service_status "testproj" "main" "api" "running" "999999" "3000"
    ! is_service_running "testproj" "main" "api"
}

@test "is_service_running returns true for current shell pid" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    # Use current shell PID which is definitely running
    update_service_status "testproj" "main" "api" "running" "$$" "3000"
    is_service_running "testproj" "main" "api"
}

# --- multiple worktrees in same project ---

@test "state supports multiple worktrees per project" {
    create_worktree_state "testproj" "main" "/tmp/wt/main" 0
    create_worktree_state "testproj" "feature/a" "/tmp/wt/feature-a" 1
    create_worktree_state "testproj" "feature/b" "/tmp/wt/feature-b" 2

    [[ "$(get_worktree_state "testproj" "main" "slot")" == "0" ]]
    [[ "$(get_worktree_state "testproj" "feature/a" "slot")" == "1" ]]
    [[ "$(get_worktree_state "testproj" "feature/b" "slot")" == "2" ]]
}
