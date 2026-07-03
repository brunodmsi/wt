#!/bin/bash
# tests/test_helper.bash - Common test helpers for BATS tests

# Resolve project root (parent of tests/)
WT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WT_SCRIPT_DIR

# Create temporary directories for test isolation
setup_test_dirs() {
    TEST_TMPDIR="$(mktemp -d)"
    export WT_CONFIG_DIR="$TEST_TMPDIR/config"
    export WT_PROJECTS_DIR="$WT_CONFIG_DIR/projects"
    export WT_DATA_DIR="$TEST_TMPDIR/data"
    export WT_STATE_DIR="$WT_DATA_DIR/state"
    export WT_LOG_DIR="$WT_DATA_DIR/logs"

    mkdir -p "$WT_CONFIG_DIR" "$WT_PROJECTS_DIR" "$WT_DATA_DIR" "$WT_STATE_DIR" "$WT_LOG_DIR"

    # Run from an isolated throwaway *main* checkout so the suite is hermetic.
    # Commands under test call git relative to the current directory
    # (detect_worktree_branch, branch_exists, current_branch, ...). Launching
    # from a main checkout makes those deterministic: detect_worktree_branch
    # reports "not in a worktree", and branch/HEAD lookups don't error on an
    # unborn HEAD. Without this the result depends on where the suite is run:
    # it fails from a linked worktree (e.g. a wt-managed checkout, where the
    # ambient branch leaks in) and also from a non-git dir (where create_worktree
    # sees a detached HEAD). Tests needing a different CWD cd into their own
    # fixture repo/worktree explicitly.
    local cwd_repo="$TEST_TMPDIR/.cwd"
    mkdir -p "$cwd_repo"
    git -C "$cwd_repo" init -b main >/dev/null 2>&1
    git -C "$cwd_repo" config user.email "test@test.com"
    git -C "$cwd_repo" config user.name "Test"
    git -C "$cwd_repo" commit --allow-empty -m "init" >/dev/null 2>&1
    cd "$cwd_repo" || return 1
}

# Remove temporary directories
teardown_test_dirs() {
    # Leave the temp dir before removing it, otherwise the shell's CWD becomes
    # a dangling reference and later commands warn about a missing directory.
    cd / || true
    if [[ -n "${TEST_TMPDIR:-}" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

# Source a single lib module (and its dependencies)
# Usage: load_lib "utils"  -> sources lib/utils.sh
load_lib() {
    local lib="$1"
    source "$WT_SCRIPT_DIR/lib/${lib}.sh"
}

# Write a YAML fixture file
# Usage: create_yaml_fixture "$path" "yaml content"
create_yaml_fixture() {
    local path="$1"
    local content="$2"

    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
}
