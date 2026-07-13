#!/usr/bin/env bats
# tests/test_version.bats - `wt --version` reporting
#
# --version is handled before the dependency check, so these don't need yq.
# Driven as subprocesses so the real git-describe path runs under set -e.

load test_helper

setup() {
    setup_test_dirs
    export WT_MULTIPLEXER=none
}

teardown() {
    teardown_test_dirs
}

@test "version: prints the baked-in version" {
    run "$WT_SCRIPT_DIR/wt.sh" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"version 1.1.0"* ]]
}

@test "version: appends git describe info when run from a checkout" {
    # Stage the tool inside its own git repo so describe resolves.
    local repo="$TEST_TMPDIR/repo"
    mkdir -p "$repo"
    cp -R "$WT_SCRIPT_DIR/wt.sh" "$WT_SCRIPT_DIR/lib" "$WT_SCRIPT_DIR/commands" \
          "$WT_SCRIPT_DIR/completions" "$repo/"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "t@t.co"
    git -C "$repo" config user.name "t"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "v0"

    run env WT_MULTIPLEXER=none "$repo/wt.sh" --version
    [ "$status" -eq 0 ]
    # e.g. "wt version 1.1.0 (abc1234)"
    [[ "$output" == *"version 1.1.0 ("* ]]
}

@test "version: falls back to the constant outside a checkout" {
    # Stage the tool in a plain (non-git) dir.
    local plain="$TEST_TMPDIR/plain"
    mkdir -p "$plain"
    cp -R "$WT_SCRIPT_DIR/wt.sh" "$WT_SCRIPT_DIR/lib" "$WT_SCRIPT_DIR/commands" \
          "$WT_SCRIPT_DIR/completions" "$plain/"

    run env WT_MULTIPLEXER=none "$plain/wt.sh" --version
    [ "$status" -eq 0 ]
    [ "$output" = "wt version 1.1.0" ]
}
