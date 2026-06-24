#!/usr/bin/env bats
# tests/test_claim.bats - Integration tests for `wt claim` / `wt release`

load test_helper

setup() {
    setup_test_dirs
    load_lib "utils"
    load_lib "config"
    load_lib "port"
    load_lib "state"
    load_lib "worktree"
    load_lib "setup"
    load_lib "multiplexer"
    load_lib "tmux"
    load_lib "service"

    source "$WT_SCRIPT_DIR/commands/claim.sh"
    source "$WT_SCRIPT_DIR/commands/release.sh"
    source "$WT_SCRIPT_DIR/commands/status.sh"
    source "$WT_SCRIPT_DIR/commands/exec.sh"
    source "$WT_SCRIPT_DIR/commands/run.sh"

    export WT_MULTIPLEXER=none

    # Use a realpath repo so the path git records matches what we compare
    # against (macOS /var -> /private/var symlink).
    TEST_REPO="$(cd "$TEST_TMPDIR" && pwd -P)/test-repo"
    mkdir -p "$TEST_REPO"
    git -C "$TEST_REPO" init -b main >/dev/null 2>&1
    git -C "$TEST_REPO" config user.email "test@test.com"
    git -C "$TEST_REPO" config user.name "Test"
    touch "$TEST_REPO/README.md"
    git -C "$TEST_REPO" add README.md
    git -C "$TEST_REPO" commit -m "initial" >/dev/null 2>&1

    # Base directory for "external" worktrees that live OUTSIDE <repo>/.worktrees
    EXT_BASE="$(cd "$TEST_TMPDIR" && pwd -P)/external"
    mkdir -p "$EXT_BASE"
}

teardown() {
    teardown_test_dirs
}

# Project config; name == basename(repo) so detection works both by repo_path
# and by basename. MAIN_REPO + PORT_WEB are written to files by setup steps.
_create_claim_config() {
    local project="${1:-test-repo}"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: $project
repo_path: $TEST_REPO
ports:
  reserved:
    range: { min: 3000, max: 3010 }
    slots: 3
    services:
      web: 0
  dynamic:
    range: { min: 4000, max: 5000 }
    services: {}
services:
  - name: web
    command: echo running
    working_dir: .
    port_key: web
setup:
  - name: write-mainrepo
    command: echo \"\$MAIN_REPO\" > claimed-mainrepo.txt
    working_dir: .
  - name: write-port
    command: echo \"\$PORT_WEB\" > claimed-port.txt
    working_dir: .
tmux:
  session: wt-test-claim
  layout: tiled
  windows:
    - name: dev
      panes:
        - service: web"
}

# Create an external worktree (outside <repo>/.worktrees) for the given branch.
# Echoes the realpath of the worktree.
_make_external_worktree() {
    local branch="$1"
    local name="${2:-$(sanitize_branch_name "$branch")}"
    local path="$EXT_BASE/$name"
    git -C "$TEST_REPO" worktree add "$path" -b "$branch" >/dev/null 2>&1
    (cd "$path" && pwd -P)
}

# ===== claim: help =====

@test "claim: shows help with --help" {
    run cmd_claim --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Adopt an existing git worktree"* ]]
}

# ===== claim: core behaviour =====

@test "claim: adopts an external worktree and records the real path" {
    _create_claim_config
    local ext
    ext=$(_make_external_worktree "feature/adopt")

    run cmd_claim "$ext" -p test-repo 2>&1
    [[ "$status" -eq 0 ]]

    # State records the real (external) path, not the convention path
    [[ "$(get_worktree_path "test-repo" "feature/adopt")" == "$ext" ]]
    [[ "$ext" != *"/.worktrees/"* ]]

    # Slot claimed
    [[ "$(get_slot_for_worktree "test-repo" "feature/adopt")" == "0" ]]
}

@test "claim: flags the worktree as claimed in state" {
    _create_claim_config
    local ext
    ext=$(_make_external_worktree "feature/flag")

    cmd_claim "$ext" -p test-repo >/dev/null 2>&1
    [[ "$(get_worktree_state "test-repo" "feature/flag" "source")" == "claimed" ]]
}

@test "claim: exports MAIN_REPO and ports to setup steps" {
    _create_claim_config
    local ext
    ext=$(_make_external_worktree "feature/setup-env")

    cmd_claim "$ext" -p test-repo >/dev/null 2>&1

    # The setup step resolved MAIN_REPO to the main repo (not the worktree)
    [[ -f "$ext/claimed-mainrepo.txt" ]]
    [[ "$(cat "$ext/claimed-mainrepo.txt")" == "$TEST_REPO" ]]
    # PORT_WEB was exported (slot 0 -> 3000)
    [[ "$(cat "$ext/claimed-port.txt")" == "3000" ]]
}

@test "claim: --no-setup registers state but skips setup steps" {
    _create_claim_config
    local ext
    ext=$(_make_external_worktree "feature/nosetup")

    run cmd_claim "$ext" -p test-repo --no-setup 2>&1
    [[ "$status" -eq 0 ]]
    [[ "$(get_worktree_path "test-repo" "feature/nosetup")" == "$ext" ]]
    # Setup did not run
    [[ ! -f "$ext/claimed-mainrepo.txt" ]]
}

@test "claim: auto-detects project from the main repo path" {
    _create_claim_config
    local ext
    ext=$(_make_external_worktree "feature/autodetect")

    # No -p flag: project resolved from repo_path / basename
    run cmd_claim "$ext" --no-setup 2>&1
    [[ "$status" -eq 0 ]]
    [[ "$(get_worktree_path "test-repo" "feature/autodetect")" == "$ext" ]]
}

@test "claim: --branch overrides branch detection" {
    _create_claim_config
    local ext
    ext=$(_make_external_worktree "feature/realbranch")

    run cmd_claim "$ext" -p test-repo --branch custom-name --no-setup 2>&1
    [[ "$status" -eq 0 ]]
    [[ "$(get_worktree_path "test-repo" "custom-name")" == "$ext" ]]
}

@test "claim: is idempotent at the same path" {
    _create_claim_config
    local ext
    ext=$(_make_external_worktree "feature/idem")

    cmd_claim "$ext" -p test-repo --no-setup >/dev/null 2>&1
    run cmd_claim "$ext" -p test-repo --no-setup 2>&1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"already claimed at this path"* ]]
    # Still exactly one slot used
    [[ "$(slots_in_use "test-repo")" == "1" ]]
}

@test "claim: dies when branch is claimed at a different path without --force" {
    _create_claim_config
    local ext
    ext=$(_make_external_worktree "feature/conflict")

    # Pre-seed state pointing at a different (stale) path
    create_worktree_state "test-repo" "feature/conflict" "/some/other/path" 0

    run cmd_claim "$ext" -p test-repo --no-setup 2>&1
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"already claimed at a different path"* ]]
}

@test "claim: --force re-claims a branch at a new path" {
    _create_claim_config
    local ext
    ext=$(_make_external_worktree "feature/forced")

    create_worktree_state "test-repo" "feature/forced" "/some/other/path" 0

    run cmd_claim "$ext" -p test-repo --no-setup --force 2>&1
    [[ "$status" -eq 0 ]]
    [[ "$(get_worktree_path "test-repo" "feature/forced")" == "$ext" ]]
}

@test "claim: dies when path is not a git worktree" {
    _create_claim_config
    local notrepo="$EXT_BASE/plain-dir"
    mkdir -p "$notrepo"

    run cmd_claim "$notrepo" -p test-repo 2>&1
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Not a git worktree"* ]]
}

@test "claim: dies for a missing path" {
    _create_claim_config
    run cmd_claim "$EXT_BASE/does-not-exist" -p test-repo 2>&1
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"does not exist"* ]]
}

# ===== claim: downstream commands work on a claimed worktree =====
# Regression for the worktree_exists() computed-path gate that previously made
# status/exec/run/start/restart die on claimed worktrees.

@test "claim: status works on a claimed worktree" {
    _create_claim_config
    local ext
    ext=$(_make_external_worktree "feature/status")
    cmd_claim "$ext" -p test-repo --no-setup >/dev/null 2>&1

    run cmd_status -p test-repo "feature/status" 2>&1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"feature/status"* ]]
    [[ "$output" == *"$ext"* ]]
    # Claimed worktrees are flagged in status
    [[ "$output" == *"claimed"* ]]
}

@test "claim: exec runs in the claimed worktree directory" {
    _create_claim_config
    local ext
    ext=$(_make_external_worktree "feature/execwt")
    cmd_claim "$ext" -p test-repo --no-setup >/dev/null 2>&1

    run cmd_exec -p test-repo "feature/execwt" pwd 2>&1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"$ext"* ]]
}

@test "claim: run executes a named setup step on the claimed worktree" {
    _create_claim_config
    local ext
    ext=$(_make_external_worktree "feature/runstep")
    cmd_claim "$ext" -p test-repo --no-setup >/dev/null 2>&1

    run cmd_run -p test-repo "feature/runstep" write-port 2>&1
    [[ "$status" -eq 0 ]]
    [[ -f "$ext/claimed-port.txt" ]]
}

# ===== release =====

@test "release: shows help with --help" {
    run cmd_release --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Release a claimed worktree"* ]]
}

@test "release: drops state and slot but keeps the directory" {
    _create_claim_config
    local ext
    ext=$(_make_external_worktree "feature/release")
    cmd_claim "$ext" -p test-repo --no-setup >/dev/null 2>&1

    run cmd_release "$ext" -p test-repo 2>&1
    [[ "$status" -eq 0 ]]

    # State + slot gone
    run worktree_state_exists "test-repo" "feature/release"
    [[ "$status" -ne 0 ]]
    [[ "$(get_slot_for_worktree "test-repo" "feature/release")" == "" ]]

    # Directory + git worktree intact (Orca owns it)
    [[ -d "$ext" ]]
    git -C "$TEST_REPO" worktree list --porcelain | grep -q "$ext"
}

@test "release: is idempotent when nothing is claimed" {
    _create_claim_config
    local ext
    ext=$(_make_external_worktree "feature/noclaim")

    run cmd_release "$ext" -p test-repo 2>&1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"nothing to release"* ]]
}

@test "release: works via --branch/-p after the directory is gone" {
    _create_claim_config
    local ext
    ext=$(_make_external_worktree "feature/gonedir")
    cmd_claim "$ext" -p test-repo --no-setup >/dev/null 2>&1

    # Simulate the directory being removed before release runs
    rm -rf "$ext"
    git -C "$TEST_REPO" worktree prune

    run cmd_release --branch "feature/gonedir" -p test-repo 2>&1
    [[ "$status" -eq 0 ]]
    run worktree_state_exists "test-repo" "feature/gonedir"
    [[ "$status" -ne 0 ]]
}

@test "release: never removes a claimed worktree's slot for another branch" {
    _create_claim_config
    local a b
    a=$(_make_external_worktree "feature/keep-a")
    b=$(_make_external_worktree "feature/keep-b")
    cmd_claim "$a" -p test-repo --no-setup >/dev/null 2>&1
    cmd_claim "$b" -p test-repo --no-setup >/dev/null 2>&1

    cmd_release "$a" -p test-repo >/dev/null 2>&1

    # b's state + slot survive
    worktree_state_exists "test-repo" "feature/keep-b"
    [[ -n "$(get_slot_for_worktree "test-repo" "feature/keep-b")" ]]
}

# ===== worktree_dir_exists (state-authoritative existence) =====

@test "worktree_dir_exists: true via recorded state path outside .worktrees" {
    _create_claim_config
    local ext
    ext=$(_make_external_worktree "feature/exists-state")
    create_worktree_state "test-repo" "feature/exists-state" "$ext" 0

    worktree_dir_exists "test-repo" "feature/exists-state" "$TEST_REPO"
    # And worktree_exists (convention path) does NOT see it
    ! worktree_exists "feature/exists-state" "$TEST_REPO"
}

@test "worktree_dir_exists: falls back to convention path when no state" {
    _create_claim_config
    create_worktree "feature/conv" "" "$TEST_REPO" >/dev/null 2>&1
    # No state recorded
    worktree_dir_exists "test-repo" "feature/conv" "$TEST_REPO"
}

@test "worktree_dir_exists: false when neither path exists" {
    _create_claim_config
    ! worktree_dir_exists "test-repo" "feature/nope" "$TEST_REPO"
}
