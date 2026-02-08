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
}

# Remove temporary directories
teardown_test_dirs() {
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
