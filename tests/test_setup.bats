#!/usr/bin/env bats
# tests/test_setup.bats - Unit tests for lib/setup.sh

load test_helper

setup() {
    setup_test_dirs
    load_lib "utils"
    load_lib "config"
    load_lib "state"
    load_lib "setup"

    # Create a fake worktree directory
    WORKTREE_PATH="$TEST_TMPDIR/worktree"
    mkdir -p "$WORKTREE_PATH"
    mkdir -p "$WORKTREE_PATH/frontend"
    mkdir -p "$WORKTREE_PATH/backend"
}

teardown() {
    teardown_test_dirs
}

# --- execute_setup ---

@test "execute_setup runs all steps" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: step1
    command: touch step1.done
    working_dir: .
  - name: step2
    command: touch step2.done
    working_dir: .'

    execute_setup "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml" 2>/dev/null
    [[ -f "$WORKTREE_PATH/step1.done" ]]
    [[ -f "$WORKTREE_PATH/step2.done" ]]
}

@test "execute_setup returns 0 with no steps" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup: []'
    run execute_setup "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml"
    [[ "$status" -eq 0 ]]
}

@test "execute_setup returns 0 with no setup section" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'name: test'
    run execute_setup "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml"
    [[ "$status" -eq 0 ]]
}

@test "execute_setup aborts on failure with on_failure=abort" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: fail-step
    command: exit 1
    working_dir: .
    on_failure: abort
  - name: should-not-run
    command: touch should-not-run.done
    working_dir: .'

    run execute_setup "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml"
    [[ "$status" -ne 0 ]]
    [[ ! -f "$WORKTREE_PATH/should-not-run.done" ]]
}

@test "execute_setup continues on failure with on_failure=continue" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: fail-step
    command: "false"
    working_dir: .
    on_failure: continue
  - name: should-run
    command: touch should-run.done
    working_dir: .'

    # execute_setup returns 1 when any step failed, even with continue
    execute_setup "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml" 2>/dev/null || true
    [[ -f "$WORKTREE_PATH/should-run.done" ]]
}

@test "execute_setup respects working_dir" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: in-frontend
    command: touch marker.done
    working_dir: frontend'

    execute_setup "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml" 2>/dev/null
    [[ -f "$WORKTREE_PATH/frontend/marker.done" ]]
}

@test "execute_setup skips step with unmet condition" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: conditional-step
    command: touch conditional.done
    working_dir: .
    condition: "[ -f nonexistent-file ]"'

    execute_setup "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml" 2>/dev/null
    [[ ! -f "$WORKTREE_PATH/conditional.done" ]]
}

@test "execute_setup runs step with met condition" {
    touch "$WORKTREE_PATH/trigger-file"
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: conditional-step
    command: touch conditional.done
    working_dir: .
    condition: "[ -f trigger-file ]"'

    execute_setup "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml" 2>/dev/null
    [[ -f "$WORKTREE_PATH/conditional.done" ]]
}

@test "execute_setup rejects unsafe conditions" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: unsafe-step
    command: touch unsafe.done
    working_dir: .
    condition: "rm -rf /"'

    execute_setup "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml" 2>/dev/null
    [[ ! -f "$WORKTREE_PATH/unsafe.done" ]]
}

@test "execute_setup handles dependency resolution" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: base
    command: touch base.done
    working_dir: .
  - name: dependent
    command: touch dependent.done
    working_dir: .
    depends_on:
      - base'

    execute_setup "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml" 2>/dev/null
    [[ -f "$WORKTREE_PATH/base.done" ]]
    [[ -f "$WORKTREE_PATH/dependent.done" ]]
}

@test "execute_setup skips step with unmet dependency" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: fail-dep
    command: "false"
    working_dir: .
    on_failure: continue
  - name: dependent
    command: touch dependent.done
    working_dir: .
    depends_on:
      - fail-dep'

    # execute_setup returns 1 when any step failed
    execute_setup "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml" 2>/dev/null || true
    [[ ! -f "$WORKTREE_PATH/dependent.done" ]]
}

@test "execute_setup with step_filter runs only matching step" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: step1
    command: touch step1.done
    working_dir: .
  - name: step2
    command: touch step2.done
    working_dir: .'

    execute_setup "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml" "step2" 2>/dev/null
    [[ ! -f "$WORKTREE_PATH/step1.done" ]]
    [[ -f "$WORKTREE_PATH/step2.done" ]]
}

# --- execute_setup: phase filter (used by `wt repair`) ---

@test "execute_setup phase filter runs only steps in that phase" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: build-step
    command: touch build.done
    working_dir: .
  - name: provision-step
    command: touch provision.done
    working_dir: .
    phase: provision'

    execute_setup "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml" "" "provision" 2>/dev/null
    [[ ! -f "$WORKTREE_PATH/build.done" ]]
    [[ -f "$WORKTREE_PATH/provision.done" ]]
}

@test "execute_setup phase filter ignores depends_on across phases" {
    # provision-step depends on a build-phase step that the phase filter skips;
    # it must still run (deps are not enforced under a phase filter).
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: heavy-build
    command: touch build.done
    working_dir: .
  - name: provision-step
    command: touch provision.done
    working_dir: .
    phase: provision
    depends_on:
      - heavy-build'

    execute_setup "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml" "" "provision" 2>/dev/null
    [[ ! -f "$WORKTREE_PATH/build.done" ]]
    [[ -f "$WORKTREE_PATH/provision.done" ]]
}

# --- get_setup_requires / setup_requires_missing ---

@test "get_setup_requires reads declared artifact paths" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup_requires:
  - app/.env
  - indexer/.env'

    run get_setup_requires "$TEST_TMPDIR/config.yaml"
    [[ "$output" == *"app/.env"* ]]
    [[ "$output" == *"indexer/.env"* ]]
}

@test "get_setup_requires is empty when none declared" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'name: test'
    result=$(get_setup_requires "$TEST_TMPDIR/config.yaml" | tr -d '[:space:]')
    [[ -z "$result" ]]
}

@test "setup_requires_missing returns 0 when all artifacts present" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup_requires:
  - present.env'
    touch "$WORKTREE_PATH/present.env"

    run setup_requires_missing "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml"
    [[ "$status" -eq 0 ]]
}

@test "setup_requires_missing returns 0 when none declared" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'name: test'
    run setup_requires_missing "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml"
    [[ "$status" -eq 0 ]]
}

@test "setup_requires_missing lists missing artifacts and fails" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup_requires:
  - here.env
  - gone.env'
    touch "$WORKTREE_PATH/here.env"

    run setup_requires_missing "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"gone.env"* ]]
    [[ "$output" != *"here.env"* ]]
}

# --- finalize_provisioning ---

@test "finalize_provisioning records ok when setup passed and artifacts present" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup_requires:
  - app.env'
    touch "$WORKTREE_PATH/app.env"

    run finalize_provisioning "proj" "br" "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml" 0
    [[ "$status" -eq 0 ]]
    [[ "$(get_worktree_state "proj" "br" "provisioned")" == "ok" ]]
}

@test "finalize_provisioning records incomplete when a step failed" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'name: test'
    # setup_rc=1 (a step failed) even though no artifacts are declared
    run finalize_provisioning "proj" "br" "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml" 1
    [[ "$status" -ne 0 ]]
    [[ "$(get_worktree_state "proj" "br" "provisioned")" == "incomplete" ]]
}

@test "finalize_provisioning records incomplete when a required artifact is absent" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup_requires:
  - app.env'
    # steps "passed" (rc=0) but the artifact isn't there
    run finalize_provisioning "proj" "br" "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml" 0
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"app.env"* ]]
    [[ "$(get_worktree_state "proj" "br" "provisioned")" == "incomplete" ]]
}

# --- assert_provisioned (wt start preflight guard) ---

@test "assert_provisioned passes when required artifacts present" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup_requires:
  - app.env'
    touch "$WORKTREE_PATH/app.env"
    run assert_provisioned "proj" "br" "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml"
    [[ "$status" -eq 0 ]]
}

@test "assert_provisioned fails and names the missing artifact" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup_requires:
  - app.env'
    run assert_provisioned "proj" "br" "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"app.env"* ]]
}

# Artifacts are authoritative: a file deleted after a clean provision is caught
# even though the state key still says ok.
@test "assert_provisioned catches a deleted artifact despite provisioned=ok state" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup_requires:
  - app.env'
    set_worktree_state "proj" "br" "provisioned" "ok"
    run assert_provisioned "proj" "br" "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml"
    [[ "$status" -ne 0 ]]
}

@test "assert_provisioned falls back to provisioned state key when nothing declared" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'name: test'
    set_worktree_state "proj" "br" "provisioned" "incomplete"
    run assert_provisioned "proj" "br" "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml"
    [[ "$status" -ne 0 ]]
}

@test "assert_provisioned is OK for a legacy worktree (nothing declared, state unset)" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'name: test'
    run assert_provisioned "proj" "br" "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml"
    [[ "$status" -eq 0 ]]
}

@test "execute_setup shows summary" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: step1
    command: echo done
    working_dir: .'

    run execute_setup "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml"
    [[ "$output" == *"summary"* ]] || [[ "$output" == *"Completed"* ]]
}

# --- run_setup_step ---

@test "run_setup_step runs named step" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: my-step
    command: touch my-step.done
    description: Test step
    working_dir: .'

    run_setup_step "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml" "my-step" 2>/dev/null
    [[ -f "$WORKTREE_PATH/my-step.done" ]]
}

@test "run_setup_step returns error for missing step" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: existing
    command: echo ok
    working_dir: .'

    run run_setup_step "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml" "nonexistent"
    [[ "$status" -ne 0 ]]
}

@test "run_setup_step returns error for missing directory" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: bad-dir
    command: echo ok
    working_dir: nonexistent-dir'

    run run_setup_step "$WORKTREE_PATH" "$TEST_TMPDIR/config.yaml" "bad-dir"
    [[ "$status" -ne 0 ]]
}

# --- list_setup_steps ---

@test "list_setup_steps shows all steps" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: install
    command: npm install
    description: Install deps
  - name: build
    command: npm run build
    description: Build project'

    run list_setup_steps "$TEST_TMPDIR/config.yaml"
    [[ "$output" == *"install"* ]]
    [[ "$output" == *"build"* ]]
}

# --- validate_setup_config ---

@test "validate_setup_config returns 0 for valid config" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: install
    command: npm install'

    run validate_setup_config "$TEST_TMPDIR/config.yaml"
    [[ "$status" -eq 0 ]]
}

@test "validate_setup_config catches missing name" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - command: npm install'

    run validate_setup_config "$TEST_TMPDIR/config.yaml"
    [[ "$status" -ne 0 ]]
}

@test "validate_setup_config catches missing command" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: no-command'

    run validate_setup_config "$TEST_TMPDIR/config.yaml"
    [[ "$status" -ne 0 ]]
}

@test "validate_setup_config catches invalid dependency" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: step1
    command: echo ok
    depends_on:
      - nonexistent'

    run validate_setup_config "$TEST_TMPDIR/config.yaml"
    [[ "$status" -ne 0 ]]
}
