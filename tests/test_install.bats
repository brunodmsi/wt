#!/usr/bin/env bats
# tests/test_install.bats - install.sh source resolution (bootstrap)
#
# install.sh guards main behind a BASH_SOURCE check, so sourcing it only
# exposes functions. It enables `set -euo pipefail` at source time, so each
# check runs ensure_source inside its own `bash -c` subshell to isolate that.

load test_helper

setup() {
    setup_test_dirs
}

teardown() {
    teardown_test_dirs
}

# Build a local "origin" repo that holds the tool, for bootstrap clones.
_make_origin() {
    local origin="$1"
    mkdir -p "$origin"
    cp -R "$WT_SCRIPT_DIR/wt.sh" "$WT_SCRIPT_DIR/lib" "$WT_SCRIPT_DIR/commands" \
          "$WT_SCRIPT_DIR/completions" "$origin/"
    git -C "$origin" init -q -b main
    git -C "$origin" config user.email "t@t.co"
    git -C "$origin" config user.name "t"
    git -C "$origin" add -A
    git -C "$origin" commit -q -m "v0"
}

@test "ensure_source: uses the checkout in place when wt.sh is alongside" {
    run bash -c "
        source '$WT_SCRIPT_DIR/install.sh'
        SCRIPT_DIR='$WT_SCRIPT_DIR'
        ensure_source
        echo \"RESOLVED=\$SCRIPT_DIR\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESOLVED=$WT_SCRIPT_DIR"* ]]
}

@test "ensure_source: bootstrap clones when there is no wt.sh alongside" {
    command -v git >/dev/null || skip "git required"
    local origin="$TEST_TMPDIR/origin"
    _make_origin "$origin"

    local empty="$TEST_TMPDIR/empty"   # no wt.sh here -> bootstrap path
    mkdir -p "$empty"
    local src="$TEST_TMPDIR/managed"

    run bash -c "
        export WT_SRC_DIR='$src'
        export WT_REPO_URL='$origin'
        export WT_REPO_BRANCH=main
        source '$WT_SCRIPT_DIR/install.sh'
        SCRIPT_DIR='$empty'
        ensure_source
        echo \"RESOLVED=\$SCRIPT_DIR\"
        [[ -f \"\$SCRIPT_DIR/wt.sh\" ]] && echo HAS_WT
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESOLVED=$src"* ]]
    [[ "$output" == *"HAS_WT"* ]]
}

@test "ensure_source: refreshes an existing managed checkout" {
    command -v git >/dev/null || skip "git required"
    local origin="$TEST_TMPDIR/origin"
    _make_origin "$origin"

    local empty="$TEST_TMPDIR/empty"
    mkdir -p "$empty"
    local src="$TEST_TMPDIR/managed"
    git clone -q "$origin" "$src"

    # Advance origin; ensure_source should fast-forward the managed checkout.
    echo "change" > "$origin/NEWFILE"
    git -C "$origin" add -A
    git -C "$origin" commit -q -m "advance"
    local origin_head
    origin_head="$(git -C "$origin" rev-parse HEAD)"

    run bash -c "
        export WT_SRC_DIR='$src'
        export WT_REPO_URL='$origin'
        export WT_REPO_BRANCH=main
        source '$WT_SCRIPT_DIR/install.sh'
        SCRIPT_DIR='$empty'
        ensure_source
    "
    [ "$status" -eq 0 ]
    [ "$(git -C "$src" rev-parse HEAD)" = "$origin_head" ]
}

# make_executable chmods wt.sh, install.sh, lib/*.sh and commands/*.sh. If any
# of those is committed 100644, the chmod +x dirties every checkout, which then
# makes `wt update` refuse. Guard against reintroducing a non-executable script.
@test "all shell scripts install.sh marks executable are committed 100755" {
    command -v git >/dev/null || skip "git required"
    local offenders
    offenders="$(git -C "$WT_SCRIPT_DIR" ls-files -s wt.sh install.sh lib/ commands/ \
        | awk '$4 ~ /\.sh$/ && $1 != "100755" {print $1, $4}')"
    if [[ -n "$offenders" ]]; then
        echo "Non-executable tracked scripts (should be 100755):" >&2
        echo "$offenders" >&2
        false
    fi
}
