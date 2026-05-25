# wt — Git Worktree Manager

## Architecture

Bash CLI tool (`wt.sh`) for managing git worktrees with tmux integration. Entry point sets `set -euo pipefail`.

### Directory Structure

```
wt.sh              # Entry point, sources all modules, dispatches commands
lib/               # Core library modules (sourced by wt.sh)
  utils.sh         # Logging, YAML helpers (yq), sanitization, file locking
  config.sh        # Project config loading, hooks, env export, require_project()
  port.sh          # Reserved (slot-based) and dynamic (hash-based) port allocation
  state.sh         # YAML state files at ~/.local/share/wt/state/
  worktree.sh      # Git worktree operations (create, remove, list, exec)
  setup.sh         # Setup step execution with dependency resolution
  tmux.sh          # tmux session/window/pane management
  service.sh       # Service start/stop/status, health checks
commands/          # One file per CLI command (cmd_<name> functions)
tests/             # bats test files — one per lib module + integration tests
  test_helper.bash # Shared test setup (temp dirs, fixtures, PATH)
docs/              # configuration.md reference
```

### Key Patterns

- `require_project()` resolves project from arg or auto-detect, calls `die()` on failure
- `run_hook()` reads a YAML hook by name, null-checks, evals, warns on failure (never aborts)
- `export_env_string()` exports KEY=VALUE lines with envsubst expansion
- `sanitize_branch_name()` single sed call: `/` to `-`, strips special chars
- `die()` calls `exit 1` — works in direct calls; in `$()` subshells, `set -e` propagates
- State managed via YAML files using `yq` (mikefarah v4) with `strenv()` for safe injection
- File locking via `mkdir`-based atomic locks (not `flock`, which is Linux-only)

### Lifecycle Hooks

7 hooks called via `run_hook`: `pre_create`, `post_create`, `pre_start`, `post_start`, `post_stop`, `pre_delete`, `post_delete`. Each exports `BRANCH_NAME`; most also export `WORKTREE_PATH` and `PORT_*` where available.

## Compatibility

- **macOS bash 3.2**: No namerefs (`declare -n`), no `${var//[^pattern]/}`. Stick to POSIX-compatible constructs.
- Use `sed`, `awk`, `tr`, `cksum` — no GNU-only flags.
- `yq` is mikefarah v4 — use `strenv()` for safe YAML string injection.
- **Windows (Git Bash / MSYS2)**: worktree management runs natively. tmux isn't
  bundled with Git for Windows, so when it's absent `start`/`stop`/`attach`/
  `send`/`logs`/`panes` degrade to the `none` multiplexer. Keep tmux strictly
  optional and never `exit` on a missing tmux. Native Windows tmux ports like
  `psmux` (it ships a `tmux` shim) DO work for orchestration: psmux panes
  default to PowerShell, but `set -g default-shell "C:\Program Files\Git\bin\bash.exe"`
  in `~/.tmux.conf` makes panes spawn Git Bash — which is what wt's pane commands
  (`cd '/c/...'`, service commands) expect. `install.sh` detects the shim and
  writes that default-shell block (`ensure_psmux_bash_shell`). Using
  `usr\bin\bash.exe` directly is wrong — it skips MSYS PATH setup (no `ls`/`git`);
  use the `bin\bash.exe` launcher. WSL2 remains an alternative for Linux-native
  tmux. NEVER pin `WT_MULTIPLEXER` in the launchers — leave it unset so
  `detect_multiplexer` can pick herdr (via `HERDR_SOCKET_PATH`) / dmux / psmux /
  none at runtime; pinning it hides herdr when gwt runs inside a herdr pane.
- **Command name (`$WT_CMD`)**: user-facing text must reference `$WT_CMD` (set in
  lib/utils.sh, default `wt`), never a hard-coded `wt`. On Windows `wt` is taken
  by Windows Terminal, so the launcher installs as `gwt` and exports `WT_CMD=gwt`.
  `log_*`/`die` output and `cat << 'EOF' | _wt_sub` help blocks are filtered
  automatically; plain `echo` lines that mention the command must use `${WT_CMD}`. Use `wt_os`/`is_windows`/`dep_hint` (lib/utils.sh) for OS-aware
  behavior. Don't assume Unix-only tools — `lsof` is absent (port_in_use falls
  back to `ss`/`netstat`); symlinks need privileges (install.sh writes wrapper
  scripts on Windows).
- **`set -e` gotchas** (wt.sh runs `set -euo pipefail`, but tests don't):
  - `((x++))` returns status 1 when `x` is 0 → trips `set -e`. Use
    `x=$((x + 1))`.
  - `var=$(cmd | grep ...)` where `grep` may not match exits non-zero → trips
    `set -e`. Append `|| true`.
  - Because the bats suites source modules without `set -e`, exit-code
    regressions must be tested by driving `wt.sh` as a subprocess (see
    `tests/test_windows.bats`).

## Testing

Tests use [bats-core](https://github.com/bats-core/bats-core). Run the full suite with:

```bash
bats tests/
```

### Rules

- **Every new feature must include tests** — both unit tests in the relevant `tests/test_<module>.bats` and integration tests in `tests/test_commands.bats` or `tests/test_e2e.bats`.
- **Every bug fix must include a regression test** — add a test that would have caught the bug before the fix, then verify it passes after.
- **Test without tmux when possible** — most logic can be tested by calling library functions directly. Reserve tmux-dependent tests for `test_e2e.bats`.
- Tests use a temp directory (`TEST_TMPDIR`) and real git repos created in `setup()`. Always clean up in `teardown()`.
- Use `create_yaml_fixture` from `test_helper.bash` to create config files in tests.

### Running specific tests

```bash
bats tests/test_commands.bats              # One file
bats tests/test_commands.bats -f "hooks"   # Filter by name pattern
```

## Code Style

- Functions are `snake_case`, prefixed by domain (`log_`, `yaml_`, `get_`, `set_`, etc.)
- Commands are `cmd_<name>()` in `commands/<name>.sh`
- Use `log_info`, `log_warn`, `log_error`, `log_success` for output (all to stderr)
- Use `die "message"` for fatal errors
- Quote all variable expansions; use `"${var:-}"` for potentially unset variables
- Prefer `[[ ]]` over `[ ]` for conditionals
