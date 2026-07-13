#!/usr/bin/env bats
# tests/test_repair.bats - Integration tests for `wt repair` (safe re-provision)

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
    source "$WT_SCRIPT_DIR/commands/repair.sh"

    export WT_MULTIPLEXER=none

    TEST_REPO="$(cd "$TEST_TMPDIR" && pwd -P)/test-repo"
    mkdir -p "$TEST_REPO"
    git -C "$TEST_REPO" init -b main >/dev/null 2>&1
    git -C "$TEST_REPO" config user.email "test@test.com"
    git -C "$TEST_REPO" config user.name "Test"
    touch "$TEST_REPO/README.md"
    git -C "$TEST_REPO" add README.md
    git -C "$TEST_REPO" commit -m "initial" >/dev/null 2>&1

    # The main repo holds the canonical env file that provisioning copies in —
    # mirrors super-gap's setup-env copying .env from the main checkout.
    printf 'PORT=3000\n' > "$TEST_REPO/web.env.src"

    EXT_BASE="$(cd "$TEST_TMPDIR" && pwd -P)/external"
    mkdir -p "$EXT_BASE"
}

teardown() {
    teardown_test_dirs
}

# Config with two setup steps:
#   * destructive-build  — untagged; stands in for checkout/dep-install. Repair
#                          must NEVER run it.
#   * provision-env      — phase: provision; safe idempotent copy. Repair runs
#                          only this. Declares .env as a required artifact.
_create_repair_config() {
    create_yaml_fixture "$WT_PROJECTS_DIR/test-repo.yaml" "name: test-repo
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
setup:
  - name: destructive-build
    command: touch DESTRUCTIVE_RAN
    working_dir: .
  - name: provision-env
    command: cp \"\$MAIN_REPO/web.env.src\" .env
    working_dir: .
    phase: provision
setup_requires:
  - .env"
}

_make_external_worktree() {
    local branch="$1"
    local name="${2:-$(sanitize_branch_name "$branch")}"
    local path="$EXT_BASE/$name"
    git -C "$TEST_REPO" worktree add "$path" -b "$branch" >/dev/null 2>&1
    (cd "$path" && pwd -P)
}

# Claim a worktree with full setup so it starts life provisioned=ok.
_claim_ok() {
    local branch="$1"
    local ext
    ext=$(_make_external_worktree "$branch")
    cmd_claim "$ext" -p test-repo >/dev/null 2>&1
    echo "$ext"
}

@test "repair: shows help with --help" {
    run cmd_repair --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Re-provision a registered worktree"* ]]
}

@test "repair: dies on an unregistered worktree" {
    _create_repair_config
    run cmd_repair -p test-repo feature/unregistered 2>&1
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"No registered worktree"* ]]
}

@test "repair: recreates a missing artifact and flips provisioned back to ok" {
    _create_repair_config
    local ext
    ext=$(_claim_ok "feature/fix")
    [[ -f "$ext/.env" ]]

    # Simulate the incident: the env file is gone and state is flagged incomplete
    rm -f "$ext/.env"
    set_worktree_state "test-repo" "feature/fix" "provisioned" "incomplete"

    run cmd_repair -p test-repo feature/fix 2>&1
    [[ "$status" -eq 0 ]]
    [[ -f "$ext/.env" ]]
    [[ "$(cat "$ext/.env")" == "PORT=3000" ]]
    [[ "$(get_worktree_state "test-repo" "feature/fix" "provisioned")" == "ok" ]]
}

@test "repair: runs only provision-phase steps (destructive step never runs)" {
    _create_repair_config
    local ext
    ext=$(_claim_ok "feature/safe")

    # Remove both artifacts, then repair. Only the provision step must re-run.
    rm -f "$ext/.env" "$ext/DESTRUCTIVE_RAN"

    run cmd_repair -p test-repo feature/safe 2>&1
    [[ "$status" -eq 0 ]]
    [[ -f "$ext/.env" ]]
    # The destructive (untagged) step did NOT run
    [[ ! -f "$ext/DESTRUCTIVE_RAN" ]]
}

@test "repair: leaves local/uncommitted work untouched" {
    _create_repair_config
    local ext
    ext=$(_claim_ok "feature/dirty")

    # Represent the user's in-progress work + a submodule left on a feature branch
    echo "my work" > "$ext/mywork.txt"
    git -C "$ext" checkout -b bruno/feature-work >/dev/null 2>&1
    rm -f "$ext/.env"

    run cmd_repair -p test-repo feature/dirty 2>&1
    [[ "$status" -eq 0 ]]
    # Dirty file survives, branch is unchanged, .env is back
    [[ -f "$ext/mywork.txt" ]]
    [[ "$(cat "$ext/mywork.txt")" == "my work" ]]
    [[ "$(git -C "$ext" rev-parse --abbrev-ref HEAD)" == "bruno/feature-work" ]]
    [[ -f "$ext/.env" ]]
}

@test "repair: is idempotent (a second run keeps the worktree ok)" {
    _create_repair_config
    local ext
    ext=$(_claim_ok "feature/idem")
    rm -f "$ext/.env"

    cmd_repair -p test-repo feature/idem >/dev/null 2>&1
    run cmd_repair -p test-repo feature/idem 2>&1
    [[ "$status" -eq 0 ]]
    [[ "$(cat "$ext/.env")" == "PORT=3000" ]]
    [[ "$(get_worktree_state "test-repo" "feature/idem" "provisioned")" == "ok" ]]
}

@test "repair: auto-detects the branch when run inside the worktree" {
    _create_repair_config
    local ext
    ext=$(_claim_ok "feature/autodetect")
    rm -f "$ext/.env"

    cd "$ext"
    run cmd_repair -p test-repo 2>&1
    [[ "$status" -eq 0 ]]
    [[ -f "$ext/.env" ]]
}

@test "repair: reports failure when no provision step can produce a required artifact" {
    # A config that declares a required artifact but has NO provision step to
    # create it: repair can't fix it and must say so with a non-zero exit.
    create_yaml_fixture "$WT_PROJECTS_DIR/test-repo.yaml" "name: test-repo
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
setup:
  - name: provision-env
    command: cp \"\$MAIN_REPO/web.env.src\" .env
    working_dir: .
    phase: provision
setup_requires:
  - never-made.env"
    local ext
    ext=$(_make_external_worktree "feature/nofix")
    # Register without failing the claim: claim runs the provision step (creates
    # .env) but never-made.env is absent, so claim already exits non-zero — we
    # only care that state exists so repair has something to operate on.
    cmd_claim "$ext" -p test-repo >/dev/null 2>&1 || true

    run cmd_repair -p test-repo feature/nofix 2>&1
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"never-made.env"* ]]
    [[ "$(get_worktree_state "test-repo" "feature/nofix" "provisioned")" == "incomplete" ]]
}
