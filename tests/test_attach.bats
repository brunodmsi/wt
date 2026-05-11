#!/usr/bin/env bats
# tests/test_attach.bats - Integration tests for cmd_attach (esp. --here and herdr branch)

load test_helper

setup() {
    setup_test_dirs
    load_lib utils
    load_lib config
    load_lib port
    load_lib state
    load_lib worktree
    load_lib setup
    load_lib multiplexer
    load_lib tmux
    load_lib service
    source "$WT_SCRIPT_DIR/commands/attach.sh"

    # Known-clean multiplexer env.
    unset WT_MULTIPLEXER HERDR_SOCKET_PATH HERDR_ACTIVE_PANE_ID \
          HERDR_ACTIVE_WORKSPACE_ID DMUX_SESSION DMUX_PANE_ID TMUX TMUX_PANE
}

teardown() {
    teardown_test_dirs
}

stub_herdr() {
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/herdr" <<EOF
#!/bin/bash
echo "HERDR_CALL: \$*" >> "$TEST_TMPDIR/herdr.log"
case "\$1 \$2" in
    "tab list")
        echo '{"id":"req","result":{"type":"tab_list","tabs":[]}}'
        ;;
    "tab create")
        echo '{"id":"req","result":{"type":"tab_info","tab":{"tab_id":"w1:5","label":"x"}}}'
        ;;
    "tab focus") echo '{}' ;;
    "pane list")
        echo '{"id":"req","result":{"type":"pane_list","panes":[{"pane_id":"w1-9","tab_id":"w1:5"}]}}'
        ;;
    "pane run") echo '{}' ;;
esac
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/herdr"
    : > "$TEST_TMPDIR/herdr.log"
    export PATH="$TEST_TMPDIR/bin:$PATH"
}

# Bare-minimum project + worktree on disk so cmd_attach gets past validation.
seed_project() {
    local project="$1"
    local branch="$2"
    local extra="${3:-}"
    local repo="$TEST_TMPDIR/repo-$project"
    git init "$repo" --initial-branch=main > /dev/null 2>&1 || git init "$repo" > /dev/null 2>&1
    git -C "$repo" commit --allow-empty -m init > /dev/null 2>&1
    create_yaml_fixture "$WT_PROJECTS_DIR/${project}.yaml" "name: $project
repo_path: $repo
$extra"
    local wt_path="$repo/.worktrees/${branch}"
    mkdir -p "$wt_path"
    create_worktree_state "$project" "$branch" "$wt_path" 0
}

# --- --here under herdr ---

@test "attach --here runs cd + post_attach in current herdr pane" {
    export WT_MULTIPLEXER="herdr"
    export HERDR_ACTIVE_PANE_ID="w1-7"
    stub_herdr
    seed_project "herdrhere" "main" "herdr:
  post_attach:
    - 'git status'
    - 'echo hi'"

    run cmd_attach main -p herdrhere --here
    [ "$status" -eq 0 ]
    log=$(cat "$TEST_TMPDIR/herdr.log")
    [[ "$log" == *"pane run w1-7 cd "* ]]
    [[ "$log" == *"pane run w1-7 git status"* ]]
    [[ "$log" == *"pane run w1-7 echo hi"* ]]
    # No new tab created
    [[ "$log" != *"tab create"* ]]
    [[ "$log" != *"tab focus"* ]]
}

@test "attach --here falls back to socket lookup when HERDR_ACTIVE_PANE_ID is unset" {
    export WT_MULTIPLEXER="herdr"

    mkdir -p "$TEST_TMPDIR/bin"
    # Stub returns a focused pane via pane.list so the fallback resolves it.
    cat > "$TEST_TMPDIR/bin/herdr" <<'EOF'
#!/bin/bash
log="${HERDR_STUB_LOG:-/dev/null}"
echo "HERDR_CALL: $*" >> "$log"
case "$1 $2" in
    "pane list")
        echo '{"id":"req","result":{"type":"pane_list","panes":[{"pane_id":"w2-4","focused":true},{"pane_id":"w2-5","focused":false}]}}'
        ;;
    "pane run") echo '{}' ;;
esac
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/herdr"
    export HERDR_STUB_LOG="$TEST_TMPDIR/herdr.log"
    : > "$HERDR_STUB_LOG"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    seed_project "herdrhere2" "main"

    run cmd_attach main -p herdrhere2 --here
    [ "$status" -eq 0 ]
    log=$(cat "$HERDR_STUB_LOG")
    [[ "$log" == *"pane list"* ]]
    [[ "$log" == *"pane run w2-4 cd "* ]]
}

@test "attach --here dies when no focused pane can be resolved" {
    export WT_MULTIPLEXER="herdr"

    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/herdr" <<'EOF'
#!/bin/bash
case "$1 $2" in
    "pane list") echo '{"id":"req","result":{"type":"pane_list","panes":[]}}' ;;
esac
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/herdr"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    seed_project "herdrhere3" "main"

    run cmd_attach main -p herdrhere3 --here 2>&1
    [ "$status" -ne 0 ]
    [[ "$output" == *"focused herdr pane"* ]]
}

@test "attach --here errors when worktree path is missing" {
    export WT_MULTIPLEXER="herdr"
    export HERDR_ACTIVE_PANE_ID="w1-1"
    stub_herdr

    local repo="$TEST_TMPDIR/repo-missing"
    git init "$repo" --initial-branch=main > /dev/null 2>&1 || git init "$repo" > /dev/null 2>&1
    git -C "$repo" commit --allow-empty -m init > /dev/null 2>&1
    create_yaml_fixture "$WT_PROJECTS_DIR/missing.yaml" "name: missing
repo_path: $repo"
    create_worktree_state "missing" "main" "$repo/.worktrees/main" 0
    # Note: no mkdir for the worktree path

    run cmd_attach main -p missing --here 2>&1
    [ "$status" -ne 0 ]
    [[ "$output" == *"Worktree not found"* ]]
}

# --- default herdr behavior (no --here) ---

@test "attach falls back to tab create when label not found; runs post_attach" {
    export WT_MULTIPLEXER="herdr"
    stub_herdr
    seed_project "herdrcreate" "main" "herdr:
  post_attach:
    - 'echo attached'"

    run cmd_attach main -p herdrcreate
    [ "$status" -eq 0 ]
    log=$(cat "$TEST_TMPDIR/herdr.log")
    [[ "$log" == *"tab list"* ]]
    [[ "$log" == *"tab create --cwd"* ]]
    [[ "$log" == *"--label"* ]]
    [[ "$log" == *"pane list"* ]]
    [[ "$log" == *"pane run w1-9 echo attached"* ]]
}

@test "attach focuses existing tab and skips post_attach" {
    export WT_MULTIPLEXER="herdr"

    mkdir -p "$TEST_TMPDIR/bin"
    # Stub returns a matching tab in tab list so attach picks the focus path.
    cat > "$TEST_TMPDIR/bin/herdr" <<EOF
#!/bin/bash
echo "HERDR_CALL: \$*" >> "$TEST_TMPDIR/herdr.log"
case "\$1 \$2" in
    "tab list")
        echo '{"id":"req","result":{"type":"tab_list","tabs":[{"tab_id":"w1:5","label":"main"}]}}'
        ;;
    "tab focus") echo '{}' ;;
esac
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/herdr"
    : > "$TEST_TMPDIR/herdr.log"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    seed_project "herdrfocus" "main" "herdr:
  post_attach:
    - 'should-not-run'"

    run cmd_attach main -p herdrfocus
    [ "$status" -eq 0 ]
    log=$(cat "$TEST_TMPDIR/herdr.log")
    [[ "$log" == *"tab focus w1:5"* ]]
    [[ "$log" != *"pane run"* ]]
}

# --- --here under tmux ---

@test "attach --here under tmux send-keys cd to current pane" {
    export WT_MULTIPLEXER="tmux"
    export TMUX_PANE="%9"
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/tmux" <<EOF
#!/bin/bash
echo "TMUX_CALL: \$*" >> "$TEST_TMPDIR/tmux.log"
exit 0
EOF
    chmod +x "$TEST_TMPDIR/bin/tmux"
    : > "$TEST_TMPDIR/tmux.log"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    seed_project "tmuxhere" "main"

    run cmd_attach main -p tmuxhere --here
    [ "$status" -eq 0 ]
    log=$(cat "$TEST_TMPDIR/tmux.log")
    [[ "$log" == *"send-keys -t %9 cd "* ]]
    [[ "$log" == *"Enter"* ]]
}

# --- help ---

@test "attach --help mentions --here" {
    run cmd_attach --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--here"* ]]
}
