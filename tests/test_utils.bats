#!/usr/bin/env bats
# tests/test_utils.bats - Unit tests for lib/utils.sh

load test_helper

setup() {
    setup_test_dirs
    load_lib "utils"
}

teardown() {
    teardown_test_dirs
}

# --- sanitize_branch_name ---

@test "sanitize_branch_name replaces slashes with dashes" {
    result=$(sanitize_branch_name "feature/auth")
    [[ "$result" == "feature-auth" ]]
}

@test "sanitize_branch_name handles multiple slashes" {
    result=$(sanitize_branch_name "feat/scope/thing")
    [[ "$result" == "feat-scope-thing" ]]
}

@test "sanitize_branch_name removes dots" {
    result=$(sanitize_branch_name "v1.2.3")
    [[ "$result" == "v123" ]]
}

@test "sanitize_branch_name removes special characters" {
    result=$(sanitize_branch_name "feat@branch#1!")
    [[ "$result" == "featbranch1" ]]
}

@test "sanitize_branch_name preserves underscores" {
    result=$(sanitize_branch_name "my_branch")
    [[ "$result" == "my_branch" ]]
}

@test "sanitize_branch_name preserves dashes" {
    result=$(sanitize_branch_name "my-branch")
    [[ "$result" == "my-branch" ]]
}

@test "sanitize_branch_name handles empty string" {
    result=$(sanitize_branch_name "")
    [[ "$result" == "" ]]
}

# --- expand_path ---

@test "expand_path expands tilde" {
    result=$(expand_path "~/projects")
    [[ "$result" == "$HOME/projects" ]]
}

@test "expand_path passes through absolute paths" {
    result=$(expand_path "/usr/local/bin")
    [[ "$result" == "/usr/local/bin" ]]
}

@test "expand_path only expands leading tilde" {
    result=$(expand_path "/some/path/~/other")
    [[ "$result" == "/some/path/~/other" ]]
}

# --- truncate ---

@test "truncate returns string under limit unchanged" {
    result=$(truncate "hello" 10)
    [[ "$result" == "hello" ]]
}

@test "truncate adds ellipsis for string over limit" {
    result=$(truncate "hello world, this is long" 10)
    [[ "$result" == "hello w..." ]]
}

@test "truncate handles exact-length string" {
    result=$(truncate "abcde" 5)
    [[ "$result" == "abcde" ]]
}

# --- command_exists ---

@test "command_exists returns 0 for known command" {
    command_exists "bash"
}

@test "command_exists returns 1 for nonexistent command" {
    ! command_exists "this_command_does_not_exist_12345"
}
