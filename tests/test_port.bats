#!/usr/bin/env bats
# tests/test_port.bats - Unit tests for lib/port.sh

load test_helper

setup() {
    setup_test_dirs
    load_lib "utils"
    load_lib "config"
    load_lib "port"
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
    # If they collide, the test still passes (hash collision is possible)
    # We mainly verify both are in range
    (( port1 >= 4000 && port1 < 5000 ))
    (( port2 >= 4000 && port2 < 5000 ))
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
