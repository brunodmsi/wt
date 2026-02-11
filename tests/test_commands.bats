#!/usr/bin/env bats
# tests/test_commands.bats - Integration tests for wt commands

load test_helper

setup() {
    setup_test_dirs
    load_lib "utils"
    load_lib "config"
    load_lib "port"
    load_lib "state"
    load_lib "worktree"
    load_lib "setup"
    load_lib "tmux"
    load_lib "service"

    source "$WT_SCRIPT_DIR/commands/init.sh"
    source "$WT_SCRIPT_DIR/commands/config.sh"
    source "$WT_SCRIPT_DIR/commands/list.sh"
    source "$WT_SCRIPT_DIR/commands/status.sh"
    source "$WT_SCRIPT_DIR/commands/ports.sh"
    source "$WT_SCRIPT_DIR/commands/run.sh"
    source "$WT_SCRIPT_DIR/commands/exec.sh"
    source "$WT_SCRIPT_DIR/commands/create.sh"
    source "$WT_SCRIPT_DIR/commands/delete.sh"
    source "$WT_SCRIPT_DIR/commands/start.sh"
    source "$WT_SCRIPT_DIR/commands/stop.sh"

    # Create a test git repo
    TEST_REPO="$TEST_TMPDIR/test-repo"
    mkdir -p "$TEST_REPO"
    git -C "$TEST_REPO" init -b main >/dev/null 2>&1
    git -C "$TEST_REPO" config user.email "test@test.com"
    git -C "$TEST_REPO" config user.name "Test"
    touch "$TEST_REPO/README.md"
    git -C "$TEST_REPO" add README.md
    git -C "$TEST_REPO" commit -m "initial" >/dev/null 2>&1
}

teardown() {
    tmux kill-session -t "wt-test-cmd" 2>/dev/null || true
    teardown_test_dirs
}

# Helper: create a standard test project config
_create_test_config() {
    local project="${1:-testproj}"
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
  - name: touch-marker
    command: touch setup-marker.txt
    working_dir: .
tmux:
  session: wt-test-cmd
  layout: tiled
  windows:
    - name: dev
      panes:
        - service: web
        - command: echo shell
hooks:
  post_create: echo post-create-hook-ran"
}

# ===== init command =====

@test "init: shows help with --help" {
    run cmd_init --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Initialize"* ]] || [[ "$output" == *"init"* ]]
}

# ===== config command =====

@test "config: shows help with --help" {
    run cmd_config --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"config"* ]] || [[ "$output" == *"View"* ]]
}

@test "config: --path returns config file path" {
    _create_test_config "testproj"
    run cmd_config --path -p "testproj"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"testproj.yaml"* ]]
}

@test "config: displays config content" {
    _create_test_config "testproj"
    run cmd_config -p "testproj"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"testproj"* ]]
}

# ===== list command =====

@test "list: shows help with --help" {
    run cmd_list --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"list"* ]] || [[ "$output" == *"List"* ]]
}

@test "list: shows empty state for new project" {
    _create_test_config "testproj"
    run cmd_list -p "testproj" 2>&1
    [[ "$status" -eq 0 ]]
}

@test "list: shows worktrees after creating state" {
    _create_test_config "testproj"
    create_worktree_state "testproj" "feature/test" "$TEST_REPO/.worktrees/feature-test" 0
    run cmd_list -p "testproj" 2>&1
    [[ "$output" == *"feature"* ]]
}

@test "list: --json produces valid output" {
    _create_test_config "testproj"
    create_worktree_state "testproj" "main" "$TEST_REPO" 0
    run cmd_list -p "testproj" --json 2>&1
    [[ "$status" -eq 0 ]]
    # Should contain JSON array bracket
    [[ "$output" == *"["* ]]
}

# ===== ports command =====

@test "ports: shows help with --help" {
    run cmd_ports --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"port"* ]] || [[ "$output" == *"Port"* ]]
}

@test "ports: shows port assignments" {
    _create_test_config "testproj"
    load_project_config "testproj"
    create_worktree_state "testproj" "main" "$TEST_REPO" 0
    claim_slot "testproj" "main" 3
    run cmd_ports -p "testproj" "main" 2>&1
    [[ "$output" == *"web"* ]] || [[ "$output" == *"3000"* ]]
}

@test "ports: set subcommand creates override" {
    _create_test_config "testproj"
    load_project_config "testproj"
    create_worktree_state "testproj" "main" "$TEST_REPO" 0
    claim_slot "testproj" "main" 3
    # Subcommand must come before -p flag (cmd_ports checks $1 for subcommand)
    run cmd_ports set -p "testproj" web 9999 main 2>&1
    [[ "$status" -eq 0 ]]
    result=$(get_port_override "testproj" "main" "web")
    [[ "$result" == "9999" ]]
}

@test "ports: clear subcommand removes override" {
    _create_test_config "testproj"
    load_project_config "testproj"
    create_worktree_state "testproj" "main" "$TEST_REPO" 0
    claim_slot "testproj" "main" 3
    set_port_override "testproj" "main" "web" 9999
    # Subcommand must come before -p flag
    run cmd_ports clear -p "testproj" web main 2>&1
    [[ "$status" -eq 0 ]]
    result=$(get_port_override "testproj" "main" "web")
    [[ "$result" == "" ]]
}

# ===== status command =====

@test "status: shows help with --help" {
    run cmd_status --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"status"* ]] || [[ "$output" == *"Status"* ]]
}

@test "status: shows worktree info" {
    _create_test_config "testproj"
    load_project_config "testproj"

    # Create actual worktree (cmd_status checks worktree_exists)
    cd "$TEST_REPO"
    local wt_path
    wt_path=$(create_worktree "feature/status-test" "" "$TEST_REPO" 2>/dev/null)
    create_worktree_state "testproj" "feature/status-test" "$wt_path" 0
    claim_slot "testproj" "feature/status-test" 3

    run cmd_status -p "testproj" "feature/status-test" 2>&1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"feature/status-test"* ]]
}

# ===== start command =====

@test "start: shows help with --help" {
    run cmd_start --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"start"* ]] || [[ "$output" == *"Start"* ]]
}

# ===== stop command =====

@test "stop: shows help with --help" {
    run cmd_stop --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"stop"* ]] || [[ "$output" == *"Stop"* ]]
}

# ===== run command =====

@test "run: shows help with --help" {
    run cmd_run --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"run"* ]] || [[ "$output" == *"Run"* ]]
}

# ===== exec command =====

@test "exec: shows help with --help" {
    run cmd_exec --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"exec"* ]] || [[ "$output" == *"Execute"* ]]
}

@test "exec: runs command in worktree dir" {
    _create_test_config "testproj"
    load_project_config "testproj"

    # Create actual worktree
    local wt_path
    wt_path=$(create_worktree "feature/exec-cmd" "" "$TEST_REPO" 2>/dev/null)
    create_worktree_state "testproj" "feature/exec-cmd" "$wt_path" 0
    claim_slot "testproj" "feature/exec-cmd" 3

    run cmd_exec -p "testproj" "feature/exec-cmd" pwd 2>&1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *".worktrees/feature-exec-cmd"* ]]
}

# ===== create + delete lifecycle =====

@test "create+delete: full lifecycle without tmux" {
    _create_test_config "testproj"
    load_project_config "testproj"

    # We can't fully test create/delete commands as they require tmux,
    # but we can verify the underlying operations work together

    # Simulate create: worktree + state + slot
    local wt_path
    wt_path=$(create_worktree "feature/lifecycle" "" "$TEST_REPO" 2>/dev/null)
    [[ -d "$wt_path" ]]

    local slot
    slot=$(claim_slot "testproj" "feature/lifecycle" 3)
    [[ "$slot" == "0" ]]

    create_worktree_state "testproj" "feature/lifecycle" "$wt_path" "$slot"

    # Verify state
    [[ "$(get_worktree_state "testproj" "feature/lifecycle" "path")" == "$wt_path" ]]
    [[ "$(get_worktree_state "testproj" "feature/lifecycle" "slot")" == "0" ]]

    # Simulate delete: remove worktree + release slot + delete state
    remove_worktree "feature/lifecycle" 0 0 "$TEST_REPO" >/dev/null 2>&1
    release_slot "testproj" "feature/lifecycle"
    delete_worktree_state "testproj" "feature/lifecycle"

    # Verify cleanup
    ! worktree_exists "feature/lifecycle" "$TEST_REPO"
    [[ "$(get_slot_for_worktree "testproj" "feature/lifecycle")" == "" ]]
    [[ "$(get_worktree_state "testproj" "feature/lifecycle" "path")" == "" ]]
}

# ===== exec with port env vars =====

@test "exec: exports port variables" {
    _create_test_config "testproj"
    load_project_config "testproj"

    local wt_path
    wt_path=$(create_worktree "feature/env-test" "" "$TEST_REPO" 2>/dev/null)
    create_worktree_state "testproj" "feature/env-test" "$wt_path" 0
    claim_slot "testproj" "feature/env-test" 3

    run cmd_exec -p "testproj" "feature/env-test" env 2>&1
    [[ "$output" == *"PORT_WEB="* ]]
}

# ===== setup execution =====

@test "run: executes named setup step" {
    _create_test_config "testproj"
    load_project_config "testproj"

    local wt_path
    wt_path=$(create_worktree "feature/run-test" "" "$TEST_REPO" 2>/dev/null)
    create_worktree_state "testproj" "feature/run-test" "$wt_path" 0
    claim_slot "testproj" "feature/run-test" 3

    run cmd_run -p "testproj" "feature/run-test" "touch-marker" 2>&1
    [[ "$status" -eq 0 ]]
    [[ -f "$wt_path/setup-marker.txt" ]]
}

@test "run: fails for nonexistent step" {
    _create_test_config "testproj"
    load_project_config "testproj"

    local wt_path
    wt_path=$(create_worktree "feature/run-fail" "" "$TEST_REPO" 2>/dev/null)
    create_worktree_state "testproj" "feature/run-fail" "$wt_path" 0
    claim_slot "testproj" "feature/run-fail" 3

    run cmd_run -p "testproj" "feature/run-fail" "nonexistent-step" 2>&1
    [[ "$status" -ne 0 ]]
}

# ===== multiple worktrees =====

@test "lifecycle: multiple worktrees with different slots" {
    _create_test_config "testproj"
    load_project_config "testproj"

    local wt1 wt2
    wt1=$(create_worktree "feature/multi-a" "" "$TEST_REPO" 2>/dev/null)
    wt2=$(create_worktree "feature/multi-b" "" "$TEST_REPO" 2>/dev/null)

    local slot1 slot2
    slot1=$(claim_slot "testproj" "feature/multi-a" 3)
    slot2=$(claim_slot "testproj" "feature/multi-b" 3)

    [[ "$slot1" == "0" ]]
    [[ "$slot2" == "1" ]]

    create_worktree_state "testproj" "feature/multi-a" "$wt1" "$slot1"
    create_worktree_state "testproj" "feature/multi-b" "$wt2" "$slot2"

    # Different slots = different ports
    local port1 port2
    port1=$(get_service_port "web" "feature/multi-a" "$WT_PROJECTS_DIR/testproj.yaml" "$slot1")
    port2=$(get_service_port "web" "feature/multi-b" "$WT_PROJECTS_DIR/testproj.yaml" "$slot2")

    # services_per_slot defaults to 2, so slot 0 -> 3000, slot 1 -> 3002
    [[ "$port1" == "3000" ]]
    [[ "$port2" == "3002" ]]
    [[ "$port1" != "$port2" ]]
}

# ===== lifecycle hooks =====

# Helper: create config with all hooks that write marker files
_create_hooks_config() {
    local project="${1:-hookproj}"
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
setup: []
tmux:
  session: wt-test-cmd
  layout: tiled
  windows:
    - name: dev
      panes:
        - service: web
        - command: echo shell
hooks:
  pre_create: touch $TEST_TMPDIR/pre-create-marker
  post_create: touch $TEST_TMPDIR/post-create-marker
  pre_start: touch $TEST_TMPDIR/pre-start-marker
  post_start: touch $TEST_TMPDIR/post-start-marker
  post_stop: touch $TEST_TMPDIR/post-stop-marker
  pre_delete: touch $TEST_TMPDIR/pre-delete-marker
  post_delete: touch $TEST_TMPDIR/post-delete-marker"
}

@test "hooks: pre_create runs before worktree creation" {
    _create_hooks_config "hookproj"
    load_project_config "hookproj"

    export BRANCH_NAME="feature/hook-test"
    run_hook "$PROJECT_CONFIG_FILE" "pre_create"

    [[ -f "$TEST_TMPDIR/pre-create-marker" ]]
}

@test "hooks: post_create runs after worktree creation" {
    _create_hooks_config "hookproj"
    load_project_config "hookproj"

    export BRANCH_NAME="feature/hook-test"
    export WORKTREE_PATH="$TEST_REPO"
    run_hook "$PROJECT_CONFIG_FILE" "post_create"

    [[ -f "$TEST_TMPDIR/post-create-marker" ]]
}

@test "hooks: pre_start runs before services start" {
    _create_hooks_config "hookproj"
    load_project_config "hookproj"

    export BRANCH_NAME="feature/hook-test"
    export WORKTREE_PATH="$TEST_REPO"
    run_hook "$PROJECT_CONFIG_FILE" "pre_start"

    [[ -f "$TEST_TMPDIR/pre-start-marker" ]]
}

@test "hooks: post_start runs after services start" {
    _create_hooks_config "hookproj"
    load_project_config "hookproj"

    export BRANCH_NAME="feature/hook-test"
    export WORKTREE_PATH="$TEST_REPO"
    run_hook "$PROJECT_CONFIG_FILE" "post_start"

    [[ -f "$TEST_TMPDIR/post-start-marker" ]]
}

@test "hooks: post_stop runs after services stop" {
    _create_hooks_config "hookproj"
    load_project_config "hookproj"

    export BRANCH_NAME="feature/hook-test"
    run_hook "$PROJECT_CONFIG_FILE" "post_stop"

    [[ -f "$TEST_TMPDIR/post-stop-marker" ]]
}

@test "hooks: pre_delete runs before worktree deletion" {
    _create_hooks_config "hookproj"
    load_project_config "hookproj"

    export BRANCH_NAME="feature/hook-test"
    export WORKTREE_PATH="$TEST_REPO"
    run_hook "$PROJECT_CONFIG_FILE" "pre_delete"

    [[ -f "$TEST_TMPDIR/pre-delete-marker" ]]
}

@test "hooks: post_delete runs after worktree deletion" {
    _create_hooks_config "hookproj"
    load_project_config "hookproj"

    export BRANCH_NAME="feature/hook-test"
    export WORKTREE_PATH="$TEST_REPO"
    run_hook "$PROJECT_CONFIG_FILE" "post_delete"

    [[ -f "$TEST_TMPDIR/post-delete-marker" ]]
}

@test "hooks: pre_create has BRANCH_NAME in environment" {
    local marker="$TEST_TMPDIR/branch-env-marker"
    local project="hookenvproj"
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: $project
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
  session: wt-test-cmd
  layout: tiled
  windows:
    - name: dev
      panes:
        - command: ''
hooks:
  pre_create: echo \$BRANCH_NAME > $marker"

    load_project_config "$project"
    export BRANCH_NAME="feature/env-check"
    run_hook "$PROJECT_CONFIG_FILE" "pre_create"

    [[ -f "$marker" ]]
    [[ "$(cat "$marker")" == "feature/env-check" ]]
}
