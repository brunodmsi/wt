#!/usr/bin/env bats
# tests/test_utils.bats - Unit tests for lib/utils.sh

load test_helper

setup() {
    setup_test_dirs
    load_lib "utils"
}

teardown() {
    teardown_test_dirs
}

# --- sanitize_branch_name ---

@test "sanitize_branch_name replaces slashes with dashes" {
    result=$(sanitize_branch_name "feature/auth")
    [[ "$result" == "feature-auth" ]]
}

@test "sanitize_branch_name handles multiple slashes" {
    result=$(sanitize_branch_name "feat/scope/thing")
    [[ "$result" == "feat-scope-thing" ]]
}

@test "sanitize_branch_name removes dots" {
    result=$(sanitize_branch_name "v1.2.3")
    [[ "$result" == "v123" ]]
}

@test "sanitize_branch_name removes special characters" {
    result=$(sanitize_branch_name "feat@branch#1!")
    [[ "$result" == "featbranch1" ]]
}

@test "sanitize_branch_name preserves underscores" {
    result=$(sanitize_branch_name "my_branch")
    [[ "$result" == "my_branch" ]]
}

@test "sanitize_branch_name preserves dashes" {
    result=$(sanitize_branch_name "my-branch")
    [[ "$result" == "my-branch" ]]
}

@test "sanitize_branch_name handles empty string" {
    result=$(sanitize_branch_name "")
    [[ "$result" == "" ]]
}

@test "sanitize_branch_name handles leading slash" {
    result=$(sanitize_branch_name "/leading")
    [[ "$result" == "-leading" ]]
}

@test "sanitize_branch_name handles consecutive slashes" {
    result=$(sanitize_branch_name "a//b///c")
    [[ "$result" == "a--b---c" ]]
}

@test "sanitize_branch_name handles only special characters" {
    result=$(sanitize_branch_name "@#\$%^&")
    [[ "$result" == "" ]]
}

# --- expand_path ---

@test "expand_path expands tilde" {
    result=$(expand_path "~/projects")
    [[ "$result" == "$HOME/projects" ]]
}

@test "expand_path passes through absolute paths" {
    result=$(expand_path "/usr/local/bin")
    [[ "$result" == "/usr/local/bin" ]]
}

@test "expand_path only expands leading tilde" {
    result=$(expand_path "/some/path/~/other")
    [[ "$result" == "/some/path/~/other" ]]
}

@test "expand_path expands tilde alone" {
    result=$(expand_path "~")
    [[ "$result" == "$HOME" ]]
}

# --- truncate ---

@test "truncate returns string under limit unchanged" {
    result=$(truncate "hello" 10)
    [[ "$result" == "hello" ]]
}

@test "truncate adds ellipsis for string over limit" {
    result=$(truncate "hello world, this is long" 10)
    [[ "$result" == "hello w..." ]]
}

@test "truncate handles exact-length string" {
    result=$(truncate "abcde" 5)
    [[ "$result" == "abcde" ]]
}

@test "truncate handles very short max" {
    result=$(truncate "hello world" 4)
    [[ "$result" == "h..." ]]
}

# --- command_exists ---

@test "command_exists returns 0 for known command" {
    command_exists "bash"
}

@test "command_exists returns 1 for nonexistent command" {
    ! command_exists "this_command_does_not_exist_12345"
}

# --- require_command ---

@test "require_command succeeds for existing command" {
    require_command "bash"
}

@test "require_command dies for missing command" {
    run require_command "nonexistent_cmd_xyz_12345"
    [[ "$status" -ne 0 ]]
}

@test "require_command includes install hint in error" {
    run require_command "nonexistent_cmd_xyz" "Try: apt install foo"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Try: apt install foo"* ]]
}

# --- die ---

@test "die exits with code 1" {
    run die "something broke"
    [[ "$status" -eq 1 ]]
}

@test "die outputs error message" {
    run die "fatal error message"
    [[ "$output" == *"fatal error message"* ]]
}

# --- ensure_dir ---

@test "ensure_dir creates directory" {
    local dir="$TEST_TMPDIR/newdir/nested"
    ensure_dir "$dir"
    [[ -d "$dir" ]]
}

@test "ensure_dir is idempotent" {
    local dir="$TEST_TMPDIR/existing"
    mkdir -p "$dir"
    ensure_dir "$dir"
    [[ -d "$dir" ]]
}

# --- get_project_name ---

@test "get_project_name extracts basename from path" {
    result=$(get_project_name "/home/user/code/myproject")
    [[ "$result" == "myproject" ]]
}

@test "get_project_name handles trailing slash" {
    result=$(get_project_name "/home/user/code/myproject/")
    # basename strips trailing slash
    [[ "$result" == "myproject" ]]
}

# --- timestamp ---

@test "timestamp returns ISO 8601 format" {
    result=$(timestamp)
    # Should match YYYY-MM-DDTHH:MM:SSZ pattern
    [[ "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "timestamp is deterministic within a second" {
    ts1=$(timestamp)
    ts2=$(timestamp)
    [[ "$ts1" == "$ts2" ]]
}

# --- with_file_lock ---

@test "with_file_lock executes command" {
    local lockfile="$TEST_TMPDIR/testlock"
    touch "$lockfile"
    result=""
    _test_lock_cmd() { echo "locked"; }
    result=$(with_file_lock "$lockfile" _test_lock_cmd)
    [[ "$result" == "locked" ]]
}

@test "with_file_lock cleans up lock directory" {
    local lockfile="$TEST_TMPDIR/testlock2"
    touch "$lockfile"
    _noop() { true; }
    with_file_lock "$lockfile" _noop
    [[ ! -d "$lockfile.lockdir" ]]
}

@test "with_file_lock propagates exit code" {
    local lockfile="$TEST_TMPDIR/testlock3"
    touch "$lockfile"
    _fail_cmd() { return 42; }
    run with_file_lock "$lockfile" _fail_cmd
    [[ "$status" -eq 42 ]]
}

@test "with_file_lock removes stale lock after timeout" {
    local lockfile="$TEST_TMPDIR/testlock4"
    touch "$lockfile"
    # Create a stale lock
    mkdir "$lockfile.lockdir"
    _echo_cmd() { echo "recovered"; }
    # This should eventually recover from the stale lock
    result=$(with_file_lock "$lockfile" _echo_cmd)
    [[ "$result" == "recovered" ]]
}

# --- logging functions ---

@test "log_info outputs to stderr" {
    run log_info "test message"
    [[ "$output" == *"INFO"* ]]
    [[ "$output" == *"test message"* ]]
}

@test "log_success outputs to stderr" {
    run log_success "success message"
    [[ "$output" == *"SUCCESS"* ]]
    [[ "$output" == *"success message"* ]]
}

@test "log_warn outputs to stderr" {
    run log_warn "warning message"
    [[ "$output" == *"WARN"* ]]
    [[ "$output" == *"warning message"* ]]
}

@test "log_error outputs to stderr" {
    run log_error "error message"
    [[ "$output" == *"ERROR"* ]]
    [[ "$output" == *"error message"* ]]
}

@test "log_debug is silent without WT_DEBUG" {
    unset WT_DEBUG
    run log_debug "debug message"
    [[ "$output" == "" ]]
}

@test "log_debug outputs with WT_DEBUG=1" {
    export WT_DEBUG=1
    run log_debug "debug message"
    [[ "$output" == *"DEBUG"* ]]
    [[ "$output" == *"debug message"* ]]
    unset WT_DEBUG
}

@test "log_step shows progress" {
    run log_step 2 5 "Installing deps"
    [[ "$output" == *"2/5"* ]]
    [[ "$output" == *"Installing deps"* ]]
}

# --- print_kv ---

@test "print_kv formats key-value pair" {
    run print_kv "Name" "my-project"
    [[ "$output" == *"Name:"* ]]
    [[ "$output" == *"my-project"* ]]
}

# --- print_header ---

@test "print_header outputs header with underline" {
    run print_header "TEST HEADER"
    # Should contain the header text and a line of dashes
    [[ "$output" == *"TEST HEADER"* ]]
    [[ "$output" == *"---"* ]]
}
