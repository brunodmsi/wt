#!/usr/bin/env bats
# tests/test_update.bats - `wt update` self-update command
#
# Two kinds of checks:
#   1. Unit tests that source cmd_update and exercise arg parsing / the
#      not-a-checkout guard directly (fast, no yq/network).
#   2. End-to-end tests that drive a *staged* wt.sh as a subprocess so
#      `set -euo pipefail` is active and the real git fast-forward path runs.
#      The staged install clones a local "origin" repo, so it's hermetic.

load test_helper

setup() {
    setup_test_dirs
    load_lib "utils"
    source "$WT_SCRIPT_DIR/commands/update.sh"
    export WT_MULTIPLEXER=none
}

teardown() {
    teardown_test_dirs
}

_require_yq() {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
}

# Stage a fake install: an "origin" repo holding the tool, cloned into a
# working checkout that self-updates from it. Sets ORIGIN, CHECKOUT, WT.
stage_install() {
    ORIGIN="$TEST_TMPDIR/origin"
    mkdir -p "$ORIGIN"
    cp -R "$WT_SCRIPT_DIR/wt.sh" "$WT_SCRIPT_DIR/lib" "$WT_SCRIPT_DIR/commands" \
          "$WT_SCRIPT_DIR/completions" "$ORIGIN/"
    git -C "$ORIGIN" init -q -b main
    git -C "$ORIGIN" config user.email "t@t.co"
    git -C "$ORIGIN" config user.name "t"
    git -C "$ORIGIN" add -A
    git -C "$ORIGIN" commit -q -m "v0"

    CHECKOUT="$TEST_TMPDIR/checkout"
    git clone -q "$ORIGIN" "$CHECKOUT"
    WT="$CHECKOUT/wt.sh"
    chmod +x "$WT"
}

# --- unit: arg parsing + guards ---

@test "update: --help prints usage and exits 0" {
    run cmd_update --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: wt update"* ]]
}

@test "update: rejects an unknown option" {
    run cmd_update --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown option"* ]]
}

@test "update: rejects an unexpected argument" {
    run cmd_update some-branch
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unexpected argument"* ]]
}

@test "update: errors when not running from a git checkout" {
    WT_SCRIPT_DIR="$TEST_TMPDIR/nogit"
    mkdir -p "$WT_SCRIPT_DIR"
    run cmd_update
    [ "$status" -eq 1 ]
    [[ "$output" == *"not running from a git checkout"* ]]
}

# --- e2e: real fast-forward path under set -e ---

@test "update: reports up to date when the checkout matches origin" {
    _require_yq
    stage_install
    run env WT_MULTIPLEXER=none "$WT" update
    [ "$status" -eq 0 ]
    [[ "$output" == *"up to date"* ]]
}

@test "update: fast-forwards when origin is ahead" {
    _require_yq
    stage_install
    echo "change" > "$ORIGIN/NEWFILE"
    git -C "$ORIGIN" add -A
    git -C "$ORIGIN" commit -q -m "advance"
    local origin_head
    origin_head="$(git -C "$ORIGIN" rev-parse HEAD)"

    run env WT_MULTIPLEXER=none "$WT" update
    [ "$status" -eq 0 ]
    [[ "$output" == *"Updated"* ]]
    [ "$(git -C "$CHECKOUT" rev-parse HEAD)" = "$origin_head" ]
}

@test "update --check: reports availability without applying" {
    _require_yq
    stage_install
    echo "change" > "$ORIGIN/NEWFILE"
    git -C "$ORIGIN" add -A
    git -C "$ORIGIN" commit -q -m "advance"
    local before
    before="$(git -C "$CHECKOUT" rev-parse HEAD)"

    run env WT_MULTIPLEXER=none "$WT" update --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"new commit"* ]]
    # HEAD must be unchanged — --check does not apply.
    [ "$(git -C "$CHECKOUT" rev-parse HEAD)" = "$before" ]
}

@test "update: refuses to run with uncommitted local changes" {
    _require_yq
    stage_install
    echo "local edit" >> "$CHECKOUT/wt.sh"

    run env WT_MULTIPLEXER=none "$WT" update
    [ "$status" -eq 1 ]
    [[ "$output" == *"Uncommitted changes"* ]]
}

@test "update: warns when completions change" {
    _require_yq
    stage_install
    echo "# updated completion" >> "$ORIGIN/completions/wt.bash"
    git -C "$ORIGIN" add -A
    git -C "$ORIGIN" commit -q -m "tweak completions"

    run env WT_MULTIPLEXER=none "$WT" update
    [ "$status" -eq 0 ]
    [[ "$output" == *"completions changed"* ]]
}
