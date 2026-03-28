#!/usr/bin/env bats
# tests/test_config.bats - Unit tests for lib/config.sh

load test_helper

setup() {
    setup_test_dirs
    load_lib "utils"
    load_lib "config"
}

teardown() {
    teardown_test_dirs
}

# --- yaml_get ---

@test "yaml_get returns existing key" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" "name: myproject"
    result=$(yaml_get "$TEST_TMPDIR/test.yaml" ".name")
    [[ "$result" == "myproject" ]]
}

@test "yaml_get returns default for missing key" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" "name: myproject"
    result=$(yaml_get "$TEST_TMPDIR/test.yaml" ".missing" "default_val")
    [[ "$result" == "default_val" ]]
}

@test "yaml_get returns default for missing file" {
    result=$(yaml_get "$TEST_TMPDIR/nonexistent.yaml" ".name" "fallback")
    [[ "$result" == "fallback" ]]
}

@test "yaml_get returns nested value" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" 'ports:
  reserved:
    range:
      min: 3000'
    result=$(yaml_get "$TEST_TMPDIR/test.yaml" ".ports.reserved.range.min")
    [[ "$result" == "3000" ]]
}

@test "yaml_get returns empty string as default when not specified" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" "name: x"
    result=$(yaml_get "$TEST_TMPDIR/test.yaml" ".missing")
    [[ "$result" == "" ]]
}

# --- yaml_set ---

@test "yaml_set creates key in existing file" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" "{}"
    yaml_set "$TEST_TMPDIR/test.yaml" ".name" "newproject"
    result=$(yaml_get "$TEST_TMPDIR/test.yaml" ".name")
    [[ "$result" == "newproject" ]]
}

@test "yaml_set creates file if it does not exist" {
    yaml_set "$TEST_TMPDIR/new.yaml" ".name" "created"
    result=$(yaml_get "$TEST_TMPDIR/new.yaml" ".name")
    [[ "$result" == "created" ]]
}

@test "yaml_set overwrites existing key" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" "name: old"
    yaml_set "$TEST_TMPDIR/test.yaml" ".name" "new"
    result=$(yaml_get "$TEST_TMPDIR/test.yaml" ".name")
    [[ "$result" == "new" ]]
}

# --- yaml_set_num ---

@test "yaml_set_num sets numeric value" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" "{}"
    yaml_set_num "$TEST_TMPDIR/test.yaml" ".port" "3000"
    result=$(yaml_get "$TEST_TMPDIR/test.yaml" ".port")
    [[ "$result" == "3000" ]]
}

@test "yaml_set_num creates file if missing" {
    yaml_set_num "$TEST_TMPDIR/num.yaml" ".count" "42"
    result=$(yaml_get "$TEST_TMPDIR/num.yaml" ".count")
    [[ "$result" == "42" ]]
}

# --- yaml_delete ---

@test "yaml_delete removes existing key" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" 'name: myproject
version: 1'
    yaml_delete "$TEST_TMPDIR/test.yaml" ".version"
    result=$(yaml_get "$TEST_TMPDIR/test.yaml" ".version" "gone")
    [[ "$result" == "gone" ]]
}

@test "yaml_delete is no-op for missing file" {
    # Should not error
    yaml_delete "$TEST_TMPDIR/nonexistent.yaml" ".name"
}

@test "yaml_delete preserves other keys" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" 'name: myproject
version: 1
author: bob'
    yaml_delete "$TEST_TMPDIR/test.yaml" ".version"
    [[ "$(yaml_get "$TEST_TMPDIR/test.yaml" ".name")" == "myproject" ]]
    [[ "$(yaml_get "$TEST_TMPDIR/test.yaml" ".author")" == "bob" ]]
}

# --- yaml_array ---

@test "yaml_array returns array elements" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" 'items:
  - one
  - two
  - three'
    run yaml_array "$TEST_TMPDIR/test.yaml" ".items"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"one"* ]]
    [[ "$output" == *"two"* ]]
    [[ "$output" == *"three"* ]]
}

@test "yaml_array returns empty for missing file" {
    run yaml_array "$TEST_TMPDIR/nonexistent.yaml" ".items"
    [[ "$output" == "" ]]
}

@test "yaml_array returns empty for missing key" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" "name: x"
    run yaml_array "$TEST_TMPDIR/test.yaml" ".items"
    [[ "$output" == "" ]]
}

# --- yaml_array_length ---

@test "yaml_array_length returns correct count" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" 'items:
  - one
  - two
  - three'
    result=$(yaml_array_length "$TEST_TMPDIR/test.yaml" ".items")
    [[ "$result" == "3" ]]
}

@test "yaml_array_length returns 0 for empty array" {
    create_yaml_fixture "$TEST_TMPDIR/test.yaml" "items: []"
    result=$(yaml_array_length "$TEST_TMPDIR/test.yaml" ".items")
    [[ "$result" == "0" ]]
}

@test "yaml_array_length returns 0 for missing file" {
    result=$(yaml_array_length "$TEST_TMPDIR/nonexistent.yaml" ".items")
    [[ "$result" == "0" ]]
}

# --- project_config_path ---

@test "project_config_path returns correct path" {
    result=$(project_config_path "myproject")
    [[ "$result" == "$WT_PROJECTS_DIR/myproject.yaml" ]]
}

# --- global_config_path ---

@test "global_config_path returns correct path" {
    result=$(global_config_path)
    [[ "$result" == "$WT_CONFIG_DIR/config.yaml" ]]
}

# --- has_project_config ---

@test "has_project_config returns true when config exists" {
    create_yaml_fixture "$WT_PROJECTS_DIR/testproj.yaml" "name: testproj"
    has_project_config "testproj"
}

@test "has_project_config returns false when config missing" {
    ! has_project_config "nonexistent"
}

# --- has_global_config ---

@test "has_global_config returns false when no global config" {
    ! has_global_config
}

@test "has_global_config returns true when global config exists" {
    create_yaml_fixture "$(global_config_path)" "version: 1"
    has_global_config
}

# --- load_project_config ---

@test "load_project_config sets PROJECT_NAME" {
    create_yaml_fixture "$WT_PROJECTS_DIR/testproj.yaml" 'name: testproj
repo_path: /tmp
ports:
  reserved:
    range: { min: 3000, max: 3010 }
  dynamic:
    range: { min: 4000, max: 5000 }'
    load_project_config "testproj"
    [[ "$PROJECT_NAME" == "testproj" ]]
}

@test "load_project_config sets PROJECT_REPO_PATH" {
    create_yaml_fixture "$WT_PROJECTS_DIR/testproj.yaml" 'name: testproj
repo_path: ~/code/myapp
ports:
  reserved:
    range: { min: 3000, max: 3010 }
  dynamic:
    range: { min: 4000, max: 5000 }'
    load_project_config "testproj"
    [[ "$PROJECT_REPO_PATH" == "$HOME/code/myapp" ]]
}

@test "load_project_config sets port ranges" {
    create_yaml_fixture "$WT_PROJECTS_DIR/testproj.yaml" 'name: testproj
repo_path: /tmp
ports:
  reserved:
    range: { min: 3000, max: 3010 }
    slots: 5
  dynamic:
    range: { min: 4000, max: 5000 }'
    load_project_config "testproj"
    [[ "$PROJECT_RESERVED_PORT_MIN" == "3000" ]]
    [[ "$PROJECT_RESERVED_PORT_MAX" == "3010" ]]
    [[ "$PROJECT_RESERVED_SLOTS" == "5" ]]
    [[ "$PROJECT_DYNAMIC_PORT_MIN" == "4000" ]]
    [[ "$PROJECT_DYNAMIC_PORT_MAX" == "5000" ]]
}

@test "load_project_config uses defaults for missing port config" {
    create_yaml_fixture "$WT_PROJECTS_DIR/testproj.yaml" 'name: testproj
repo_path: /tmp'
    load_project_config "testproj"
    [[ "$PROJECT_RESERVED_PORT_MIN" == "3000" ]]
    [[ "$PROJECT_RESERVED_PORT_MAX" == "3005" ]]
    [[ "$PROJECT_RESERVED_SLOTS" == "3" ]]
    [[ "$PROJECT_DYNAMIC_PORT_MIN" == "4000" ]]
    [[ "$PROJECT_DYNAMIC_PORT_MAX" == "5000" ]]
}

@test "load_project_config dies for missing project" {
    run load_project_config "nonexistent"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"No configuration found"* ]]
}

@test "load_project_config dies for invalid reserved port range" {
    create_yaml_fixture "$WT_PROJECTS_DIR/badproj.yaml" 'name: badproj
repo_path: /tmp
ports:
  reserved:
    range: { min: 5000, max: 3000 }
  dynamic:
    range: { min: 4000, max: 5000 }'
    run load_project_config "badproj"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Invalid reserved port range"* ]]
}

@test "load_project_config dies for invalid dynamic port range" {
    create_yaml_fixture "$WT_PROJECTS_DIR/badproj.yaml" 'name: badproj
repo_path: /tmp
ports:
  reserved:
    range: { min: 3000, max: 3010 }
  dynamic:
    range: { min: 9000, max: 5000 }'
    run load_project_config "badproj"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Invalid dynamic port range"* ]]
}

@test "load_project_config dies for out-of-bounds reserved ports" {
    create_yaml_fixture "$WT_PROJECTS_DIR/badproj.yaml" 'name: badproj
repo_path: /tmp
ports:
  reserved:
    range: { min: 0, max: 3010 }
  dynamic:
    range: { min: 4000, max: 5000 }'
    run load_project_config "badproj"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"out of bounds"* ]]
}

# --- get_setup_steps / get_setup_step ---

@test "get_setup_steps returns count" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: install
    command: npm install
  - name: build
    command: npm run build'
    result=$(get_setup_steps "$TEST_TMPDIR/config.yaml")
    [[ "$result" == "2" ]]
}

@test "get_setup_steps returns 0 for no setup" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'name: test'
    result=$(get_setup_steps "$TEST_TMPDIR/config.yaml")
    [[ "$result" == "0" ]]
}

@test "get_setup_step returns step field" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'setup:
  - name: install
    command: npm install
    description: Install dependencies'
    result=$(get_setup_step "$TEST_TMPDIR/config.yaml" 0 "name")
    [[ "$result" == "install" ]]
    result=$(get_setup_step "$TEST_TMPDIR/config.yaml" 0 "command")
    [[ "$result" == "npm install" ]]
}

# --- get_services / get_service_config / get_service_by_index ---

@test "get_services returns count" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'services:
  - name: api
    command: npm start
  - name: web
    command: npm run dev'
    result=$(get_services "$TEST_TMPDIR/config.yaml")
    [[ "$result" == "2" ]]
}

@test "get_services returns 0 for no services" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'services: []'
    result=$(get_services "$TEST_TMPDIR/config.yaml")
    [[ "$result" == "0" ]]
}

@test "get_service_config returns field by name" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'services:
  - name: api
    command: npm start
    working_dir: backend'
    result=$(get_service_config "$TEST_TMPDIR/config.yaml" "api" "command")
    [[ "$result" == "npm start" ]]
    result=$(get_service_config "$TEST_TMPDIR/config.yaml" "api" "working_dir")
    [[ "$result" == "backend" ]]
}

@test "get_service_by_index returns field" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'services:
  - name: api
    command: npm start
  - name: web
    command: npm run dev'
    result=$(get_service_by_index "$TEST_TMPDIR/config.yaml" 1 "name")
    [[ "$result" == "web" ]]
}

# --- get_env_vars / export_env_string / export_env_vars ---

@test "get_env_vars returns KEY=VALUE pairs" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'env:
  NODE_ENV: development
  PORT: "3000"'
    run get_env_vars "$TEST_TMPDIR/config.yaml"
    [[ "$output" == *"NODE_ENV=development"* ]]
    [[ "$output" == *"PORT=3000"* ]]
}

@test "get_env_vars returns empty for missing file" {
    run get_env_vars "$TEST_TMPDIR/nonexistent.yaml"
    [[ "$output" == "" ]]
}

@test "get_env_vars returns no KEY=VALUE for no env section" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'name: test'
    # yq may produce artifact output like bare '='; verify no actual KEY=VALUE pairs
    result=$(get_env_vars "$TEST_TMPDIR/config.yaml" | grep -cE '^[A-Za-z_].*=' || true)
    [[ "$result" == "0" ]]
}

@test "export_env_string exports variables" {
    export_env_string "FOO=bar
BAZ=qux"
    [[ "$FOO" == "bar" ]]
    [[ "$BAZ" == "qux" ]]
    unset FOO BAZ
}

@test "export_env_string handles empty lines" {
    export_env_string "

FOO=bar

"
    [[ "$FOO" == "bar" ]]
    unset FOO
}

@test "export_env_vars exports from config file" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'env:
  MY_TEST_VAR: hello_world'
    export_env_vars "$TEST_TMPDIR/config.yaml"
    [[ "$MY_TEST_VAR" == "hello_world" ]]
    unset MY_TEST_VAR
}

# --- run_hook ---

@test "run_hook executes hook command" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'hooks:
  post_create: echo hook_executed'
    run run_hook "$TEST_TMPDIR/config.yaml" "post_create"
    [[ "$output" == *"hook_executed"* ]]
}

@test "run_hook is no-op for missing hook" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'name: test'
    run run_hook "$TEST_TMPDIR/config.yaml" "post_create"
    [[ "$status" -eq 0 ]]
}

@test "run_hook warns on failing hook" {
    create_yaml_fixture "$TEST_TMPDIR/config.yaml" 'hooks:
  post_create: "false"'
    run run_hook "$TEST_TMPDIR/config.yaml" "post_create" 2>&1
    [[ "$output" == *"hook exited with errors"* ]]
}

# --- list_projects ---

@test "list_projects returns configured projects" {
    create_yaml_fixture "$WT_PROJECTS_DIR/proj-a.yaml" "name: proj-a"
    create_yaml_fixture "$WT_PROJECTS_DIR/proj-b.yaml" "name: proj-b"
    run list_projects
    [[ "$output" == *"proj-a"* ]]
    [[ "$output" == *"proj-b"* ]]
}

@test "list_projects returns empty when no projects" {
    # Clean projects dir
    rm -f "$WT_PROJECTS_DIR"/*.yaml
    run list_projects
    [[ "$output" == "" ]]
}

# --- init_config_dirs ---

@test "init_config_dirs creates all directories" {
    # Remove dirs to test creation
    rm -rf "$WT_CONFIG_DIR" "$WT_DATA_DIR"
    init_config_dirs
    [[ -d "$WT_CONFIG_DIR" ]]
    [[ -d "$WT_PROJECTS_DIR" ]]
    [[ -d "$WT_DATA_DIR" ]]
    [[ -d "$WT_STATE_DIR" ]]
    [[ -d "$WT_LOG_DIR" ]]
}

# --- generate_default_config ---

@test "generate_default_config creates valid YAML file" {
    local config_file="$WT_PROJECTS_DIR/gentest.yaml"
    generate_default_config "gentest" "/tmp/fake-repo" "$config_file"
    [[ -f "$config_file" ]]

    # Verify it's valid YAML that yq can parse
    local name
    name=$(yaml_get "$config_file" ".name")
    [[ "$name" == "gentest" ]]
}

@test "generate_default_config sets correct repo_path" {
    local config_file="$WT_PROJECTS_DIR/gentest.yaml"
    generate_default_config "gentest" "/home/user/my-project" "$config_file"

    local repo_path
    repo_path=$(yaml_get "$config_file" ".repo_path")
    [[ "$repo_path" == "/home/user/my-project" ]]
}

@test "generate_default_config includes setup steps" {
    local config_file="$WT_PROJECTS_DIR/gentest.yaml"
    generate_default_config "gentest" "/tmp/fake-repo" "$config_file"

    local step_count
    step_count=$(get_setup_steps "$config_file")
    [[ "$step_count" -ge 1 ]]

    local step_name
    step_name=$(get_setup_step "$config_file" 0 "name")
    [[ "$step_name" == "install-deps" ]]
}

@test "generate_default_config includes services" {
    local config_file="$WT_PROJECTS_DIR/gentest.yaml"
    generate_default_config "gentest" "/tmp/fake-repo" "$config_file"

    local svc_count
    svc_count=$(get_services "$config_file")
    [[ "$svc_count" -ge 1 ]]

    local svc_name
    svc_name=$(get_service_by_index "$config_file" 0 "name")
    [[ "$svc_name" == "app" ]]
}

@test "generate_default_config includes slots configuration" {
    local config_file="$WT_PROJECTS_DIR/gentest.yaml"
    generate_default_config "gentest" "/tmp/fake-repo" "$config_file"

    local slots
    slots=$(yaml_get "$config_file" ".ports.reserved.slots")
    [[ "$slots" == "3" ]]

    local svc_offset
    svc_offset=$(yaml_get "$config_file" ".ports.reserved.services.app")
    [[ "$svc_offset" == "0" ]]
}

@test "generate_default_config includes tmux layout" {
    local config_file="$WT_PROJECTS_DIR/gentest.yaml"
    generate_default_config "gentest" "/tmp/fake-repo" "$config_file"

    local layout
    layout=$(yaml_get "$config_file" ".tmux.layout")
    [[ "$layout" == "tiled" ]]
}

@test "generate_default_config can be loaded by load_project_config" {
    local config_file="$WT_PROJECTS_DIR/loadtest.yaml"
    generate_default_config "loadtest" "/tmp/fake-repo" "$config_file"

    load_project_config "loadtest"
    [[ "$PROJECT_NAME" == "loadtest" ]]
    [[ "$PROJECT_RESERVED_SLOTS" == "3" ]]
    [[ "$PROJECT_RESERVED_PORT_MIN" == "3000" ]]
}

# --- auto_init_project ---

@test "auto_init_project creates config in a git repo" {
    local repo="$TEST_TMPDIR/auto-init-repo"
    mkdir -p "$repo"
    git -C "$repo" init -b main >/dev/null 2>&1
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    touch "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -m "initial" >/dev/null 2>&1

    cd "$repo"
    run auto_init_project
    [[ "$status" -eq 0 ]]
    [[ "$output" == "auto-init-repo" ]]
    [[ -f "$WT_PROJECTS_DIR/auto-init-repo.yaml" ]]
}

@test "auto_init_project adds .worktrees to gitignore" {
    local repo="$TEST_TMPDIR/auto-gitignore"
    mkdir -p "$repo"
    git -C "$repo" init -b main >/dev/null 2>&1
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    touch "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -m "initial" >/dev/null 2>&1

    cd "$repo"
    auto_init_project >/dev/null 2>&1
    grep -q "^\.worktrees/$" "$repo/.gitignore"
}

@test "auto_init_project returns empty outside git repo" {
    local tmpdir="$TEST_TMPDIR/not-a-repo"
    mkdir -p "$tmpdir"
    cd "$tmpdir"
    run auto_init_project
    [[ "$status" -eq 0 ]]
    [[ "$output" == "" ]]
}

@test "auto_init_project does not overwrite existing config" {
    local repo="$TEST_TMPDIR/existing-config"
    mkdir -p "$repo"
    git -C "$repo" init -b main >/dev/null 2>&1
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    touch "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -m "initial" >/dev/null 2>&1

    # Pre-create config
    create_yaml_fixture "$WT_PROJECTS_DIR/existing-config.yaml" "name: existing-config
repo_path: $repo"

    cd "$repo"
    run auto_init_project
    [[ "$status" -eq 0 ]]
    [[ "$output" == "" ]]
}

@test "require_project auto-inits when no config exists" {
    local repo="$TEST_TMPDIR/require-auto"
    mkdir -p "$repo"
    git -C "$repo" init -b main >/dev/null 2>&1
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    touch "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -m "initial" >/dev/null 2>&1

    cd "$repo"
    run require_project ""
    [[ "$status" -eq 0 ]]
    [[ "$output" == "require-auto" ]]
    [[ -f "$WT_PROJECTS_DIR/require-auto.yaml" ]]
}
