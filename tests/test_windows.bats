#!/usr/bin/env bats
# tests/test_windows.bats - Cross-platform / Windows (Git Bash) portability
#
# Two kinds of checks:
#   1. Unit tests for the OS-detection helpers and the portable port_in_use.
#   2. End-to-end regressions that drive wt.sh as a subprocess so that
#      `set -euo pipefail` (which only wt.sh enables) is active. The unit-style
#      tests in test_commands.bats source modules WITHOUT `set -e`, so they
#      cannot catch the exit-code bugs these guard against.

load test_helper

setup() {
    setup_test_dirs
    load_lib "utils"

    WT="$WT_SCRIPT_DIR/wt.sh"

    # Force the "none" multiplexer so e2e tests are deterministic and never
    # depend on tmux (the whole point of Windows support).
    export WT_MULTIPLEXER=none

    TEST_REPO="$TEST_TMPDIR/test-repo"
    mkdir -p "$TEST_REPO"
    git -C "$TEST_REPO" init -b main >/dev/null 2>&1
    git -C "$TEST_REPO" config user.email "test@test.com"
    git -C "$TEST_REPO" config user.name "Test"
    touch "$TEST_REPO/README.md"
    git -C "$TEST_REPO" add README.md
    git -C "$TEST_REPO" commit -m "initial" >/dev/null 2>&1

    create_yaml_fixture "$WT_PROJECTS_DIR/testproj.yaml" "name: testproj
repo_path: $TEST_REPO
ports:
  reserved:
    range: { min: 3000, max: 3010 }
    slots: 3
    services: {}
  dynamic:
    range: { min: 4000, max: 5000 }
    services: {}
services: []
setup: []
tmux:
  layout: tiled"
}

teardown() {
    teardown_test_dirs
}

_require_yq() {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
}

# --- wt_os / is_windows ---

@test "wt_os returns a known family" {
    result=$(wt_os)
    [[ "$result" == "macos" || "$result" == "windows" || "$result" == "linux" ]]
}

@test "is_windows agrees with wt_os" {
    if [[ "$(wt_os)" == "windows" ]]; then
        is_windows
    else
        ! is_windows
    fi
}

# --- dep_hint ---

@test "dep_hint yq returns a non-empty hint" {
    result=$(dep_hint yq)
    [[ -n "$result" ]]
}

@test "dep_hint is OS-appropriate for yq" {
    result=$(dep_hint yq)
    case "$(wt_os)" in
        macos) [[ "$result" == *"brew"* ]] ;;
        windows) [[ "$result" == *"winget"* || "$result" == *"scoop"* ]] ;;
        *) [[ -n "$result" ]] ;;
    esac
}

# --- port_in_use (portable: lsof | ss | netstat) ---

@test "port_in_use reports a free high port as not in use" {
    # 65533 is almost certainly free; must return non-zero without erroring.
    run port_in_use 65533
    [[ "$status" -ne 0 ]]
}

@test "port_in_use returns cleanly even without lsof" {
    # On Windows Git Bash lsof is absent; the fallback (ss/netstat) must not
    # error out. Either outcome (in use / free) is a clean return.
    run port_in_use 65533
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
}

# --- e2e regressions: worktree lifecycle without tmux, with set -e active ---

@test "e2e: wt --version exits 0" {
    run bash "$WT" --version
    [[ "$status" -eq 0 ]]
}

@test "e2e: wt list exits 0 with a populated list (regression: ((count++)) + set -e)" {
    _require_yq
    cd "$TEST_REPO"
    run bash "$WT" create feature/login -p testproj --no-attach --no-setup
    [[ "$status" -eq 0 ]]
    run bash "$WT" list -p testproj
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"feature/login"* ]]
}

@test "e2e: wt status exits 0 for a branch without upstream (regression: grep + set -e)" {
    _require_yq
    cd "$TEST_REPO"
    run bash "$WT" create feature/login -p testproj --no-attach --no-setup
    [[ "$status" -eq 0 ]]
    run bash "$WT" status feature/login -p testproj
    [[ "$status" -eq 0 ]]
}

@test "e2e: wt create/delete lifecycle exits 0 without tmux" {
    _require_yq
    cd "$TEST_REPO"
    run bash "$WT" create feature/x -p testproj --no-attach --no-setup
    [[ "$status" -eq 0 ]]
    run bash "$WT" delete feature/x -p testproj --force
    [[ "$status" -eq 0 ]]
}

@test "e2e: WT_CMD customizes the command name in output (gwt on Windows)" {
    run env WT_CMD=gwt bash "$WT" --version
    [[ "$status" -eq 0 ]]
    [[ "$output" == "gwt version"* ]]
}

@test "e2e: default command name stays 'wt' when WT_CMD is unset" {
    run bash "$WT" --version
    [[ "$output" == "wt version"* ]]
}

@test "e2e: WT_CMD rewrites the command in help text" {
    run env WT_CMD=gwt bash "$WT" --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"gwt <command>"* ]]
    [[ "$output" == *"gwt create"* ]]
}

@test "e2e: WT_CMD rewrites the command in error hints" {
    _require_yq
    # A git repo with no wt config -> 'could not detect project' error,
    # which must reference the active command name.
    local norepo="$TEST_TMPDIR/norepo"
    mkdir -p "$norepo"
    git -C "$norepo" init -b main >/dev/null 2>&1
    git -C "$norepo" config user.email t@t.co
    git -C "$norepo" config user.name t
    ( cd "$norepo" && env WT_CMD=gwt bash "$WT" create foo ) 2>"$TEST_TMPDIR/err" 1>&2 || true
    run cat "$TEST_TMPDIR/err"
    [[ "$output" == *"gwt init"* ]]
}

@test "e2e: wt doctor does not hard-fail when tmux is absent" {
    _require_yq
    cd "$TEST_REPO"
    run bash "$WT" doctor -p testproj
    # doctor returns non-zero only on FAILs. Missing tmux is now a WARN, so a
    # well-formed project should not fail solely because tmux is unavailable.
    [[ "$status" -eq 0 ]]
}
