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

@test "get_worktree_state returns empty for missing project" {
    result=$(get_worktree_state "noproject" "main" "branch")
    [[ "$result" == "" ]]
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
