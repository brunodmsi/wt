#!/usr/bin/env bats
# tests/test_doctor.bats - Integration tests for wt doctor command

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
    source "$WT_SCRIPT_DIR/commands/doctor.sh"
}

teardown() {
    teardown_test_dirs
}

# --- Dependency checks ---

@test "doctor passes dependency checks" {
    run cmd_doctor -p nonexistent 2>&1
    # Should at least check dependencies without crashing
    [[ "$output" == *"Dependencies"* ]]
}

@test "doctor detects git" {
    run cmd_doctor -p nonexistent 2>&1
    [[ "$output" == *"git"* ]]
    [[ "$output" == *"PASS"* ]]
}

@test "doctor detects yq" {
    run cmd_doctor -p nonexistent 2>&1
    [[ "$output" == *"yq"* ]]
}

# --- Config validation ---

@test "doctor validates valid YAML config" {
    local project="testproj"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: testproj
repo_path: /tmp/fake-repo
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

    mkdir -p /tmp/fake-repo

    run cmd_doctor -p "$project" 2>&1
    [[ "$output" == *"YAML syntax is valid"* ]]
    [[ "$output" == *"repo_path is set"* ]]

    rmdir /tmp/fake-repo 2>/dev/null || true
}

@test "doctor detects invalid port range" {
    local project="badports"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: badports
repo_path: /tmp
ports:
  reserved:
    range:
      min: 5000
      max: 3000
  dynamic:
    range:
      min: 4000
      max: 5000
services: []"

    run cmd_doctor -p "$project" 2>&1
    [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"Invalid"* ]]
}

@test "doctor detects overlapping port ranges" {
    local project="overlap"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: overlap
repo_path: /tmp
ports:
  reserved:
    range:
      min: 3000
      max: 4500
  dynamic:
    range:
      min: 4000
      max: 5000
services: []"

    run cmd_doctor -p "$project" 2>&1
    [[ "$output" == *"overlap"* ]] || [[ "$output" == *"FAIL"* ]]
}

@test "doctor detects missing config" {
    run cmd_doctor -p "nonexistent_project_xyz" 2>&1
    [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"not found"* ]] || [[ "$output" == *"WARN"* ]]
}

# --- State consistency ---

@test "doctor detects orphaned worktree state" {
    local project="statetest"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: statetest
repo_path: /tmp
services: []"

    create_worktree_state "$project" "feature/gone" "/tmp/nonexistent-path-xyz" 0

    run cmd_doctor -p "$project" 2>&1
    [[ "$output" == *"Orphaned"* ]] || [[ "$output" == *"WARN"* ]]
}

# --- Summary line ---

@test "doctor shows summary" {
    run cmd_doctor -p nonexistent 2>&1
    [[ "$output" == *"Summary"* ]]
    [[ "$output" == *"passed"* ]]
}
