#!/usr/bin/env bats
# tests/test_config.bats - Unit tests for lib/config.sh

load test_helper

setup() {
    setup_test_dirs
    load_lib "utils"
    load_lib "config"
}

teardown() {
    teardown_test_dirs
}

# --- yaml_get ---

@test "yaml_get returns existing key" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" "name: myproject"
    result=$(yaml_get "$TEST_TMPDIR/test.yaml" ".name")
    [[ "$result" == "myproject" ]]
}

@test "yaml_get returns default for missing key" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" "name: myproject"
    result=$(yaml_get "$TEST_TMPDIR/test.yaml" ".missing" "default_val")
    [[ "$result" == "default_val" ]]
}

@test "yaml_get returns default for missing file" {
    result=$(yaml_get "$TEST_TMPDIR/nonexistent.yaml" ".name" "fallback")
    [[ "$result" == "fallback" ]]
}

@test "yaml_get returns nested value" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" 'ports:
  reserved:
    range:
      min: 3000'
    result=$(yaml_get "$TEST_TMPDIR/test.yaml" ".ports.reserved.range.min")
    [[ "$result" == "3000" ]]
}

# --- yaml_set ---

@test "yaml_set creates key in existing file" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" "{}"
    yaml_set "$TEST_TMPDIR/test.yaml" ".name" "newproject"
    result=$(yaml_get "$TEST_TMPDIR/test.yaml" ".name")
    [[ "$result" == "newproject" ]]
}

@test "yaml_set creates file if it does not exist" {
    yaml_set "$TEST_TMPDIR/new.yaml" ".name" "created"
    result=$(yaml_get "$TEST_TMPDIR/new.yaml" ".name")
    [[ "$result" == "created" ]]
}

@test "yaml_set overwrites existing key" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" "name: old"
    yaml_set "$TEST_TMPDIR/test.yaml" ".name" "new"
    result=$(yaml_get "$TEST_TMPDIR/test.yaml" ".name")
    [[ "$result" == "new" ]]
}

# --- yaml_set_num ---

@test "yaml_set_num sets numeric value" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" "{}"
    yaml_set_num "$TEST_TMPDIR/test.yaml" ".port" "3000"
    result=$(yaml_get "$TEST_TMPDIR/test.yaml" ".port")
    [[ "$result" == "3000" ]]
}

@test "yaml_set_num creates file if missing" {
    yaml_set_num "$TEST_TMPDIR/num.yaml" ".count" "42"
    result=$(yaml_get "$TEST_TMPDIR/num.yaml" ".count")
    [[ "$result" == "42" ]]
}

# --- yaml_delete ---

@test "yaml_delete removes existing key" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" 'name: myproject
version: 1'
    yaml_delete "$TEST_TMPDIR/test.yaml" ".version"
    result=$(yaml_get "$TEST_TMPDIR/test.yaml" ".version" "gone")
    [[ "$result" == "gone" ]]
}

@test "yaml_delete is no-op for missing file" {
    # Should not error
    yaml_delete "$TEST_TMPDIR/nonexistent.yaml" ".name"
}

# --- yaml_array_length ---

@test "yaml_array_length returns correct count" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" 'items:
  - one
  - two
  - three'
    result=$(yaml_array_length "$TEST_TMPDIR/test.yaml" ".items")
    [[ "$result" == "3" ]]
}

@test "yaml_array_length returns 0 for empty array" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" "items: []"
    result=$(yaml_array_length "$TEST_TMPDIR/test.yaml" ".items")
    [[ "$result" == "0" ]]
}

@test "yaml_array_length returns 0 for missing file" {
    result=$(yaml_array_length "$TEST_TMPDIR/nonexistent.yaml" ".items")
    [[ "$result" == "0" ]]
}

# --- project_config_path ---

@test "project_config_path returns correct path" {
    result=$(project_config_path "myproject")
    [[ "$result" == "$WT_PROJECTS_DIR/myproject.yaml" ]]
}

# --- has_project_config ---

@test "has_project_config returns true when config exists" {
    create_yaml_fixture "$WT_PROJECTS_DIR/testproj.yaml" "name: testproj"
    has_project_config "testproj"
}

@test "has_project_config returns false when config missing" {
    ! has_project_config "nonexistent"
}
