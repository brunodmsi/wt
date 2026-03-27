# Contributing to wt

Thank you for your interest in contributing to `wt`! This document covers everything you need to get started.

## Table of Contents

- [Setup](#setup)
- [Reporting Issues](#reporting-issues)
- [Pull Requests](#pull-requests)
- [Code Style](#code-style)
- [Testing](#testing)

---

## Setup

### Prerequisites

- **git** — for version control and worktree operations
- **yq** (mikefarah v4) — YAML processing
- **tmux** — terminal multiplexer integration
- **bats-core** — test framework (for running tests)

Install on macOS with Homebrew:

```bash
brew install git yq tmux bats-core
```

### Getting the code

```bash
git clone https://github.com/your-org/wt.git
cd wt
```

### Installing for development

Use `--prefix` to install to a local directory so your development copy does not conflict with any system installation:

```bash
./install.sh --prefix ~/.local/bin
```

Verify the install:

```bash
wt --version
```

### Project layout

```
wt.sh              # Entry point — sources all modules, dispatches commands
lib/               # Core library modules
  utils.sh         # Logging, YAML helpers, sanitization, file locking
  config.sh        # Project config loading, hooks, env export
  port.sh          # Port allocation (reserved slots + dynamic hash-based)
  state.sh         # YAML state files at ~/.local/share/wt/state/
  worktree.sh      # Git worktree operations
  setup.sh         # Setup step execution with dependency resolution
  tmux.sh          # tmux session/window/pane management
  service.sh       # Service start/stop/status, health checks
commands/          # One file per CLI command (cmd_<name> functions)
tests/             # bats test files
docs/              # Configuration reference
```

---

## Reporting Issues

Before filing an issue, please:

1. **Search existing issues** to avoid duplicates.
2. **Run `wt doctor`** and include its output — it surfaces common configuration and runtime problems.
3. **Reproduce with a minimal config** when possible.

When opening an issue, include:

- **`wt` version** (`wt --version`)
- **OS and shell** (e.g., macOS 14, zsh 5.9)
- **`yq` version** (`yq --version`) — must be mikefarah v4
- **Reproduction steps** — the exact commands you ran
- **Expected vs actual behaviour**
- **`wt doctor` output** (redact any sensitive paths if needed)

---

## Pull Requests

### Before you start

- For non-trivial changes, open an issue first to discuss the approach.
- Check that there is not already an open PR addressing the same thing.

### Workflow

1. **Fork** the repository and create a branch from `main`:

   ```bash
   git checkout -b fix/my-bug-fix
   # or
   git checkout -b feat/my-new-feature
   ```

2. **Make your changes** following the [Code Style](#code-style) guidelines below.

3. **Add tests** — every change requires tests (see [Testing](#testing)).

4. **Run the full test suite** and ensure it passes:

   ```bash
   bats tests/
   ```

5. **Commit** with a clear, concise message:

   ```
   fix: handle missing yq gracefully in config load
   feat: add --dry-run flag to wt delete
   ```

6. **Open a pull request** against `main`. Include:
   - What the change does and why
   - How to test it manually (if applicable)
   - Any related issues (`Closes #123`)

### PR checklist

- [ ] Tests added or updated (unit + integration as appropriate)
- [ ] All tests pass (`bats tests/`)
- [ ] Code matches the project style (see below)
- [ ] Commit messages are clear and descriptive
- [ ] No secrets, credentials, or `.env` files included

---

## Code Style

`wt` is a Bash CLI tool targeting **macOS bash 3.2** compatibility. All code must work on the system shell shipped with macOS.

### Compatibility rules

- **No bash 4+ features**: no associative arrays (`declare -A`), no namerefs (`declare -n`), no `${var//[^pattern]/}` extended substitution.
- Use `sed`, `awk`, `tr`, `cksum` for text processing — avoid GNU-only flags.
- `yq` is mikefarah v4 — use `strenv()` for safe YAML string injection.
- File locking uses `mkdir`-based atomic locks (not `flock`, which is Linux-only).

### Naming and structure

- Functions use `snake_case` with a domain prefix: `log_`, `yaml_`, `get_`, `set_`, `cmd_`, etc.
- CLI commands live in `commands/<name>.sh` as `cmd_<name>()`.
- Library functions live in `lib/<module>.sh`.

### Variables and quoting

- Quote all variable expansions: `"${var}"`.
- Use `"${var:-}"` for variables that may be unset.
- Prefer `[[ ]]` over `[ ]` for conditionals.

### Output

- Use the logging helpers for all user-visible output (all go to stderr):
  - `log_info "message"` — general information
  - `log_warn "message"` — non-fatal warnings
  - `log_error "message"` — errors
  - `log_success "message"` — success confirmations
- Use `die "message"` for fatal errors (calls `exit 1`).

### Error handling

- Entry point and library modules use `set -euo pipefail`.
- `die()` exits with code 1; it works correctly in direct calls. In `$()` subshells `set -e` propagates the failure.
- `run_hook()` warns on failure but never aborts — hooks must not be load-bearing for correctness.

---

## Testing

Tests use [bats-core](https://github.com/bats-core/bats-core).

### Running tests

```bash
# Full suite
bats tests/

# Single file
bats tests/test_utils.bats

# Filter by test name
bats tests/test_commands.bats -f "hooks"

# Verbose output
bats tests/ --verbose-run
```

### Test organisation

| File | Covers |
|------|--------|
| `tests/test_utils.bats` | `lib/utils.sh` |
| `tests/test_port.bats` | `lib/port.sh` |
| `tests/test_config.bats` | `lib/config.sh` |
| `tests/test_state.bats` | `lib/state.sh` |
| `tests/test_worktree.bats` | `lib/worktree.sh` |
| `tests/test_commands.bats` | Integration — CLI commands |
| `tests/test_e2e.bats` | End-to-end — full lifecycle with tmux |

### Rules for new tests

- **Every new feature** requires both unit tests in the relevant `tests/test_<module>.bats` and integration tests in `tests/test_commands.bats`.
- **Every bug fix** requires a regression test — add a test that would have caught the bug before the fix.
- **Avoid tmux in unit/integration tests** — test library functions directly. Reserve tmux-dependent tests for `test_e2e.bats`.
- Tests use `TEST_TMPDIR` for isolation; set up real git repos in `setup()` and clean up in `teardown()`.
- Use `create_yaml_fixture` from `tests/test_helper.bash` to create config files.

### Example test structure

```bash
# tests/test_mymodule.bats
load 'test_helper'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    # create fixtures...
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "my_function handles empty input" {
    run my_function ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"expected"* ]]
}
```
