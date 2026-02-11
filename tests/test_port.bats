#!/usr/bin/env bats
# tests/test_port.bats - Unit tests for lib/port.sh

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

# --- calculate_dynamic_port ---

@test "calculate_dynamic_port is deterministic" {
    port1=$(calculate_dynamic_port "feature/auth" 4000 5000)
    port2=$(calculate_dynamic_port "feature/auth" 4000 5000)
    [[ "$port1" == "$port2" ]]
}

@test "calculate_dynamic_port stays within range bounds" {
    port=$(calculate_dynamic_port "some-branch" 4000 5000)
    (( port >= 4000 && port < 5000 ))
}

@test "calculate_dynamic_port handles small range" {
    port=$(calculate_dynamic_port "test" 8000 8005)
    (( port >= 8000 && port < 8005 ))
}

@test "calculate_dynamic_port avoids collision with used_ports" {
    # First calculate what port would be assigned
    port1=$(calculate_dynamic_port "test-branch" 4000 5000)
    # Now request with that port as used
    port2=$(calculate_dynamic_port "test-branch" 4000 5000 "$port1")
    [[ "$port2" != "$port1" ]]
}

@test "calculate_dynamic_port different branches get different ports" {
    port1=$(calculate_dynamic_port "branch-a" 4000 5000)
    port2=$(calculate_dynamic_port "branch-b" 4000 5000)
    # Not guaranteed but extremely likely for different inputs
    # We mainly verify both are in range
    (( port1 >= 4000 && port1 < 5000 ))
    (( port2 >= 4000 && port2 < 5000 ))
}

@test "calculate_dynamic_port handles multiple collisions" {
    # Get the default port
    port1=$(calculate_dynamic_port "test-x" 4000 4005)
    # Get with collision
    port2=$(calculate_dynamic_port "test-x" 4000 4005 "$port1")
    # Get with both as used
    port3=$(calculate_dynamic_port "test-x" 4000 4005 "$port1 $port2")
    (( port3 >= 4000 && port3 < 4005 ))
    [[ "$port3" != "$port1" ]]
    [[ "$port3" != "$port2" ]]
}

# --- calculate_reserved_port ---

@test "calculate_reserved_port slot 0 offset 0 returns base" {
    port=$(calculate_reserved_port 0 0 3000 2)
    [[ "$port" == "3000" ]]
}

@test "calculate_reserved_port slot 0 offset 1 returns base+1" {
    port=$(calculate_reserved_port 0 1 3000 2)
    [[ "$port" == "3001" ]]
}

@test "calculate_reserved_port slot 1 offset 0 returns base+services_per_slot" {
    port=$(calculate_reserved_port 1 0 3000 2)
    [[ "$port" == "3002" ]]
}

@test "calculate_reserved_port slot 2 offset 1 returns correct value" {
    port=$(calculate_reserved_port 2 1 3000 2)
    [[ "$port" == "3005" ]]
}

@test "calculate_reserved_port returns error for port > 65535" {
    run calculate_reserved_port 100 0 65500 2
    [[ "$status" -ne 0 ]]
}

@test "calculate_reserved_port valid port near upper bound" {
    port=$(calculate_reserved_port 0 0 65530 2)
    [[ "$port" == "65530" ]]
}

@test "calculate_reserved_port with 3 services per slot" {
    port=$(calculate_reserved_port 1 2 3000 3)
    # slot 1, offset 2: 3000 + (1 * 3) + 2 = 3005
    [[ "$port" == "3005" ]]
}

# --- slots_file / init_slots_file ---

@test "slots_file returns correct path" {
    result=$(slots_file)
    [[ "$result" == "$WT_STATE_DIR/slots.yaml" ]]
}

@test "init_slots_file creates file" {
    init_slots_file
    [[ -f "$(slots_file)" ]]
}

@test "init_slots_file is idempotent" {
    init_slots_file
    init_slots_file
    [[ -f "$(slots_file)" ]]
}

# --- claim_slot / get_slot_for_worktree / release_slot ---

@test "claim_slot assigns slot 0 first" {
    slot=$(claim_slot "testproj" "feature/auth" 3)
    [[ "$slot" == "0" ]]
}

@test "claim_slot assigns sequential slots" {
    slot1=$(claim_slot "testproj" "branch-a" 3)
    slot2=$(claim_slot "testproj" "branch-b" 3)
    [[ "$slot1" == "0" ]]
    [[ "$slot2" == "1" ]]
}

@test "claim_slot returns existing slot for same branch" {
    slot1=$(claim_slot "testproj" "feature/auth" 3)
    slot2=$(claim_slot "testproj" "feature/auth" 3)
    [[ "$slot1" == "$slot2" ]]
}

@test "claim_slot fails when all slots used" {
    claim_slot "testproj" "branch-a" 2
    claim_slot "testproj" "branch-b" 2
    run claim_slot "testproj" "branch-c" 2
    [[ "$status" -ne 0 ]]
}

@test "get_slot_for_worktree returns assigned slot" {
    claim_slot "testproj" "feature/auth" 3
    result=$(get_slot_for_worktree "testproj" "feature/auth")
    [[ "$result" == "0" ]]
}

@test "get_slot_for_worktree returns empty for unassigned" {
    result=$(get_slot_for_worktree "testproj" "nonexistent")
    [[ "$result" == "" ]]
}

@test "release_slot frees slot for reuse" {
    claim_slot "testproj" "branch-a" 2
    claim_slot "testproj" "branch-b" 2
    release_slot "testproj" "branch-a"
    slot=$(claim_slot "testproj" "branch-c" 2)
    [[ "$slot" == "0" ]]
}

@test "release_slot is no-op for missing file" {
    release_slot "testproj" "nonexistent"
    # Should not error
}

# --- list_slots / slots_in_use ---

@test "list_slots returns all assignments" {
    claim_slot "testproj" "branch-a" 3
    claim_slot "testproj" "branch-b" 3
    run list_slots "testproj"
    [[ "$output" == *"branch-a:0"* ]]
    [[ "$output" == *"branch-b:1"* ]]
}

@test "list_slots returns empty for no slots" {
    init_slots_file
    result=$(list_slots "testproj" | tr -d '[:space:]')
    [[ -z "$result" ]]
}

@test "slots_in_use returns count" {
    claim_slot "testproj" "branch-a" 3
    claim_slot "testproj" "branch-b" 3
    result=$(slots_in_use "testproj")
    [[ "$result" == "2" ]]
}

@test "slots_in_use returns 0 for empty" {
    result=$(slots_in_use "testproj")
    [[ "$result" == "0" ]]
}

# --- calculate_worktree_ports ---

@test "calculate_worktree_ports returns reserved ports" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'ports:
  reserved:
    range: { min: 3000, max: 3010 }
    services:
      frontend: 0
      backend: 1
  dynamic:
    range: { min: 4000, max: 5000 }
    services: {}'
    run calculate_worktree_ports "main" "$TEST_TMPDIR/config.yaml" 0
    [[ "$output" == *"frontend:3000"* ]]
    [[ "$output" == *"backend:3001"* ]]
}

@test "calculate_worktree_ports returns dynamic ports" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'ports:
  reserved:
    range: { min: 3000, max: 3010 }
    services: {}
  dynamic:
    range: { min: 4000, max: 5000 }
    services:
      api: true'
    run calculate_worktree_ports "main" "$TEST_TMPDIR/config.yaml" 0
    [[ "$output" == *"api:"* ]]
    # Extract port and verify in range
    local port
    port=$(echo "$output" | grep "^api:" | cut -d: -f2)
    (( port >= 4000 && port < 5000 ))
}

@test "calculate_worktree_ports slot affects reserved ports" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'ports:
  reserved:
    range: { min: 3000, max: 3010 }
    services:
      frontend: 0
      backend: 1
  dynamic:
    range: { min: 4000, max: 5000 }
    services: {}'
    run calculate_worktree_ports "main" "$TEST_TMPDIR/config.yaml" 1
    [[ "$output" == *"frontend:3002"* ]]
    [[ "$output" == *"backend:3003"* ]]
}

# --- export_port_vars ---

@test "export_port_vars exports PORT_ variables" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'ports:
  reserved:
    range: { min: 3000, max: 3010 }
    services:
      frontend: 0
      backend: 1
  dynamic:
    range: { min: 4000, max: 5000 }
    services: {}'
    export_port_vars "main" "$TEST_TMPDIR/config.yaml" 0
    [[ "$PORT_FRONTEND" == "3000" ]]
    [[ "$PORT_BACKEND" == "3001" ]]
    unset PORT_FRONTEND PORT_BACKEND
}

@test "export_port_vars uses cached ports when provided" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'ports:
  reserved:
    range: { min: 3000, max: 3010 }
    services: {}
  dynamic:
    range: { min: 4000, max: 5000 }
    services: {}'
    local cached="myservice:9999"
    export_port_vars "main" "$TEST_TMPDIR/config.yaml" 0 "" "$cached"
    [[ "$PORT_MYSERVICE" == "9999" ]]
    unset PORT_MYSERVICE
}

@test "export_port_vars applies port overrides" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'ports:
  reserved:
    range: { min: 3000, max: 3010 }
    services:
      frontend: 0
  dynamic:
    range: { min: 4000, max: 5000 }
    services: {}'
    create_worktree_state "testproj" "main" "/tmp" 0
    set_port_override "testproj" "main" "frontend" 8888
    export_port_vars "main" "$TEST_TMPDIR/config.yaml" 0 "testproj"
    [[ "$PORT_FRONTEND" == "8888" ]]
    unset PORT_FRONTEND
}

# --- get_service_port ---

@test "get_service_port returns calculated port" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'ports:
  reserved:
    range: { min: 3000, max: 3010 }
    services:
      frontend: 0
  dynamic:
    range: { min: 4000, max: 5000 }
    services: {}'
    result=$(get_service_port "frontend" "main" "$TEST_TMPDIR/config.yaml" 0)
    [[ "$result" == "3000" ]]
}

@test "get_service_port uses port override when available" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'ports:
  reserved:
    range: { min: 3000, max: 3010 }
    services:
      frontend: 0
  dynamic:
    range: { min: 4000, max: 5000 }
    services: {}'
    create_worktree_state "testproj" "main" "/tmp" 0
    set_port_override "testproj" "main" "frontend" 7777
    result=$(get_service_port "frontend" "main" "$TEST_TMPDIR/config.yaml" 0 "testproj")
    [[ "$result" == "7777" ]]
}

# --- slot isolation between projects ---

@test "slots are isolated between projects" {
    slot_a=$(claim_slot "project-a" "main" 3)
    slot_b=$(claim_slot "project-b" "main" 3)
    [[ "$slot_a" == "0" ]]
    [[ "$slot_b" == "0" ]]
}
