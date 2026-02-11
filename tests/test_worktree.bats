#!/usr/bin/env bats
# tests/test_worktree.bats - Unit tests for lib/worktree.sh

load test_helper

setup() {
    setup_test_dirs
    load_lib "utils"
    load_lib "config"
    load_lib "worktree"

    # Create a test git repo for worktree operations
    # Use realpath to resolve macOS symlinks (/var -> /private/var)
    # so paths match what git worktree list returns
    TEST_REPO="$(cd "$TEST_TMPDIR" && pwd -P)/test-repo"
    mkdir -p "$TEST_REPO"
    git -C "$TEST_REPO" init -b main >/dev/null 2>&1
    git -C "$TEST_REPO" config user.email "test@test.com"
    git -C "$TEST_REPO" config user.name "Test"
    touch "$TEST_REPO/README.md"
    git -C "$TEST_REPO" add README.md
    git -C "$TEST_REPO" commit -m "initial" >/dev/null 2>&1
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

@test "worktree_path handles simple branch" {
    result=$(worktree_path "main" "/repo")
    [[ "$result" == "/repo/.worktrees/main" ]]
}

# --- worktrees_dir ---

@test "worktrees_dir returns correct path" {
    result=$(worktrees_dir "/home/user/repo")
    [[ "$result" == "/home/user/repo/.worktrees" ]]
}

# --- worktree_exists ---

@test "worktree_exists returns false for non-existing worktree" {
    ! worktree_exists "feature/nonexistent" "$TEST_REPO"
}

@test "worktree_exists returns true after creating worktree" {
    create_worktree "feature/test-exists" "" "$TEST_REPO" >/dev/null 2>&1
    worktree_exists "feature/test-exists" "$TEST_REPO"
}

# --- create_worktree ---

@test "create_worktree creates a new worktree" {
    wt_path=$(create_worktree "feature/new-wt" "" "$TEST_REPO" 2>/dev/null)
    [[ -d "$wt_path" ]]
    [[ "$wt_path" == *".worktrees/feature-new-wt" ]]
}

@test "create_worktree creates branch" {
    create_worktree "feature/auto-branch" "" "$TEST_REPO" >/dev/null 2>&1
    git -C "$TEST_REPO" show-ref --verify --quiet "refs/heads/feature/auto-branch"
}

@test "create_worktree from specific base branch" {
    # Create a base branch with unique content
    git -C "$TEST_REPO" checkout -b develop >/dev/null 2>&1
    touch "$TEST_REPO/develop-file"
    git -C "$TEST_REPO" add develop-file
    git -C "$TEST_REPO" commit -m "develop commit" >/dev/null 2>&1
    git -C "$TEST_REPO" checkout main >/dev/null 2>&1

    wt_path=$(create_worktree "feature/from-develop" "develop" "$TEST_REPO" 2>/dev/null)
    [[ -d "$wt_path" ]]
    # The file from develop should exist in the worktree
    [[ -f "$wt_path/develop-file" ]]
}

@test "create_worktree for existing local branch" {
    git -C "$TEST_REPO" branch existing-branch >/dev/null 2>&1
    # branch_exists() checks CWD's repo, so cd into TEST_REPO first
    cd "$TEST_REPO"
    wt_path=$(create_worktree "existing-branch" "" "$TEST_REPO" 2>/dev/null)
    [[ -d "$wt_path" ]]
}

@test "create_worktree creates .worktrees directory" {
    create_worktree "feature/dir-test" "" "$TEST_REPO" >/dev/null 2>&1
    [[ -d "$TEST_REPO/.worktrees" ]]
}

# --- remove_worktree ---

@test "remove_worktree removes a worktree" {
    create_worktree "feature/to-remove" "" "$TEST_REPO" >/dev/null 2>&1
    remove_worktree "feature/to-remove" 0 0 "$TEST_REPO" >/dev/null 2>&1
    ! worktree_exists "feature/to-remove" "$TEST_REPO"
}

@test "remove_worktree with keep_branch preserves branch" {
    create_worktree "feature/keep-me" "" "$TEST_REPO" >/dev/null 2>&1
    remove_worktree "feature/keep-me" 0 1 "$TEST_REPO" >/dev/null 2>&1
    # Branch should still exist
    git -C "$TEST_REPO" show-ref --verify --quiet "refs/heads/feature/keep-me"
}

@test "remove_worktree returns error for non-existing worktree" {
    run remove_worktree "nonexistent" 0 0 "$TEST_REPO"
    [[ "$status" -ne 0 ]]
}

# --- list_worktrees ---

@test "list_worktrees returns empty for no worktrees" {
    result=$(list_worktrees "$TEST_REPO" | grep -c '.worktrees' || true)
    [[ "$result" == "0" ]]
}

@test "list_worktrees returns created worktrees" {
    create_worktree "feature/list-a" "" "$TEST_REPO" >/dev/null 2>&1
    create_worktree "feature/list-b" "" "$TEST_REPO" >/dev/null 2>&1
    run list_worktrees "$TEST_REPO"
    [[ "$output" == *"feature-list-a"* ]]
    [[ "$output" == *"feature-list-b"* ]]
}

# --- count_worktrees ---

@test "count_worktrees returns 0 for no worktrees" {
    result=$(list_worktrees "$TEST_REPO" | grep -c '.worktrees' || true)
    [[ "$result" == "0" ]]
}

@test "count_worktrees increases after creating worktrees" {
    create_worktree "feature/count-a" "" "$TEST_REPO" >/dev/null 2>&1
    create_worktree "feature/count-b" "" "$TEST_REPO" >/dev/null 2>&1
    result=$(list_worktrees "$TEST_REPO" | grep -c '.worktrees')
    [[ "$result" == "2" ]]
}

# --- get_worktree_branches ---

@test "get_worktree_branches includes main" {
    run get_worktree_branches "$TEST_REPO"
    [[ "$output" == *"main"* ]]
}

@test "get_worktree_branches includes worktree branches" {
    create_worktree "feature/branch-test" "" "$TEST_REPO" >/dev/null 2>&1
    run get_worktree_branches "$TEST_REPO"
    [[ "$output" == *"feature/branch-test"* ]]
}

# --- exec_in_worktree ---

@test "exec_in_worktree runs command in worktree dir" {
    create_worktree "feature/exec-test" "" "$TEST_REPO" >/dev/null 2>&1
    export REPO_ROOT="$TEST_REPO"
    result=$(exec_in_worktree "feature/exec-test" pwd 2>/dev/null)
    [[ "$result" == *".worktrees/feature-exec-test" ]]
    unset REPO_ROOT
}

@test "exec_in_worktree returns error for missing worktree" {
    export REPO_ROOT="$TEST_REPO"
    run exec_in_worktree "nonexistent" pwd
    [[ "$status" -ne 0 ]]
    unset REPO_ROOT
}

# --- prune_worktrees ---

@test "prune_worktrees does not error on clean repo" {
    run prune_worktrees "$TEST_REPO"
    [[ "$status" -eq 0 ]]
}
