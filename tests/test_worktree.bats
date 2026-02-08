#!/usr/bin/env bats
# tests/test_worktree.bats - Unit tests for lib/worktree.sh path functions

load test_helper

setup() {
    setup_test_dirs
    load_lib "utils"
    load_lib "config"
    load_lib "worktree"
}

teardown() {
    teardown_test_dirs
}

# --- worktree_path ---

@test "worktree_path constructs correct path" {
    result=$(worktree_path "feature/auth" "/home/user/repo")
    [[ "$result" == "/home/user/repo/.worktrees/feature-auth" ]]
}

@test "worktree_path sanitizes branch name" {
    result=$(worktree_path "feat/scope/thing" "/repo")
    [[ "$result" == "/repo/.worktrees/feat-scope-thing" ]]
}

# --- worktrees_dir ---

@test "worktrees_dir returns correct path" {
    result=$(worktrees_dir "/home/user/repo")
    [[ "$result" == "/home/user/repo/.worktrees" ]]
}
