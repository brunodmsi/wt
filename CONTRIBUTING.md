# Contributing to wt

Thank you for your interest in contributing to **wt** — the Git Worktree Manager. This document covers everything you need to get started.

## Table of Contents

- [Setup](#setup)
- [Reporting Issues](#reporting-issues)
- [Pull Requests](#pull-requests)
- [Code Style](#code-style)
- [Testing](#testing)

---

## Setup

### Prerequisites

- **bash** (macOS bash 3.2+ or any modern bash)
- **git** 2.5+
- **yq** (mikefarah v4) — `brew install yq`
- **tmux** — `brew install tmux`
- **bats-core** (for running tests) — `brew install bats-core`

### Development Installation

```bash
# Clone the repository
git clone https://github.com/yourorg/wt.git
cd wt

# Install dependencies
brew install yq tmux bats-core

# Make scripts executable and install
./install.sh

# Verify your installation
wt --version
```

### Repository Layout

```
wt.sh              # Entry point — sources all modules, dispatches commands
lib/               # Core library modules
  utils.sh         # Logging, YAML helpers, sanitization, file locking
  config.sh        # Project config loading, hooks, env export
  port.sh          # Port allocation (reserved slot-based + dynamic hash-based)
  state.sh         # YAML state files at ~/.local/share/wt/state/
  worktree.sh      # Git worktree operations (create, remove, list, exec)
  setup.sh         # Setup step execution with dependency resolution
  tmux.sh          # tmux session/window/pane management
  service.sh       # Service start/stop/status, health checks
commands/          # One file per CLI command (cmd_<name> functions)
tests/             # bats test files
docs/              # Configuration reference
```

---

## Reporting Issues

Before opening an issue, please:

1. **Search existing issues** to avoid duplicates.
2. **Run `wt doctor`** and include the output — it surfaces config, state, and runtime problems that are often the root cause.
3. **Include your environment** in the report:
   - macOS/Linux version
   - `bash --version`
   - `yq --version`
   - `tmux -V`
   - `wt --version`

### Bug Reports

A good bug report includes:

- A clear, descriptive title
- Steps to reproduce the issue
- Expected vs. actual behaviour
- Relevant config snippets (redact secrets)
- Output of `wt doctor` and any error messages

### Feature Requests

Open an issue with the `enhancement` label and describe:

- The problem you are trying to solve
- Your proposed solution or behaviour
- Any alternatives you have considered

---

## Pull Requests

### Workflow

1. **Fork** the repository and create a branch from `main`:
   ```bash
   git checkout -b fix/my-bug-fix
   # or
   git checkout -b feat/my-new-feature
   ```

2. **Make your changes** following the [Code Style](#code-style) guidelines below.

3. **Add tests** — every new feature and every bug fix must include tests (see [Testing](#testing)).

4. **Run the full test suite** and ensure it passes:
   ```bash
   bats tests/
   ```

5. **Open a pull request** against `main` with:
   - A clear title summarising the change
   - A description explaining *why* the change is needed
   - Reference to any related issue (e.g. `Closes #42`)

### What Gets Reviewed

- Correctness and edge-case handling
- Compatibility with macOS bash 3.2 (no namerefs, no GNU-only constructs)
- Test coverage (unit tests + integration/regression tests)
- Adherence to the code style conventions below
- Clarity and simplicity — prefer straightforward solutions

---

## Code Style

`wt` is a Bash project and targets **macOS bash 3.2** compatibility. Please keep the following conventions throughout.

### Naming

| Thing | Convention | Example |
|---|---|---|
| Library functions | `snake_case` with domain prefix | `log_info`, `yaml_get`, `get_port` |
| Command entry points | `cmd_<name>()` in `commands/<name>.sh` | `cmd_create`, `cmd_delete` |
| Local variables | `snake_case` | `local branch_name` |
| Environment variables | `UPPER_SNAKE_CASE` | `WORKTREE_PATH`, `PORT_FRONTEND` |

### Bash Conventions

- Always use `set -euo pipefail` (already set by the entry point).
- Use `[[ ]]` instead of `[ ]` for conditionals.
- Quote all variable expansions: `"${var}"`. Use `"${var:-}"` for variables that may be unset.
- Use `die "message"` for fatal errors; it calls `exit 1`.
- Use the logging helpers for all output — never write directly to stdout for status messages:
  ```bash
  log_info  "informational message"   # → stderr
  log_warn  "warning message"         # → stderr
  log_error "error message"           # → stderr
  log_success "success message"       # → stderr
  ```
- Use `yq` (mikefarah v4) for all YAML reads/writes; use `strenv()` for safe string injection.
- Use `mkdir`-based atomic locks for file locking (not `flock`, which is Linux-only).

### Compatibility

- **No** `declare -n` (namerefs — bash 4.3+)
- **No** `${var//[^pattern]/}` character-class negation
- **No** GNU-only flags (`sed -i ''` is macOS, `sed -i` is GNU — use a temp-file approach or `sed -i ''`)
- Prefer `sed`, `awk`, `tr`, `cksum` over GNU-specific utilities

### Adding a New Command

1. Create `commands/<name>.sh` with a `cmd_<name>()` function.
2. Register the command in the dispatcher in `wt.sh`.
3. Add tab-completion support in `completions/wt.bash` and `completions/wt.zsh`.
4. Add unit tests in `tests/test_commands.bats` and, if needed, e2e tests in `tests/test_e2e.bats`.

---

## Testing

Tests use [bats-core](https://github.com/bats-core/bats-core). The suite is organised as one file per library module plus integration and end-to-end files.

### Running Tests

```bash
# Run the full suite
bats tests/

# Run a single test file
bats tests/test_utils.bats

# Filter by test name
bats tests/test_commands.bats -f "hooks"

# Run with verbose output
bats tests/ --verbose-run
```

### Test Requirements

- **Every new feature** must include unit tests in the relevant `tests/test_<module>.bats` **and** integration tests in `tests/test_commands.bats` or `tests/test_e2e.bats`.
- **Every bug fix** must include a regression test — write a test that would have caught the bug *before* your fix, then verify it passes *after*.
- **Prefer tests without tmux** — most logic can be exercised by calling library functions directly. Reserve tmux-dependent tests for `test_e2e.bats`.

### Writing Tests

Tests use a shared helper at `tests/test_helper.bash` which provides:

- `TEST_TMPDIR` — a per-test temporary directory
- Real git repos created in `setup()`
- `create_yaml_fixture` — helper for writing YAML config files

A minimal test looks like:

```bash
#!/usr/bin/env bats

load test_helper

setup() {
    # Create a temp git repo used by the test
    TEST_REPO="$TEST_TMPDIR/myrepo"
    git init "$TEST_REPO"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "sanitize_branch_name converts slashes to dashes" {
    source "$PROJECT_ROOT/lib/utils.sh"
    result=$(sanitize_branch_name "feature/my-branch")
    [[ "$result" == "feature-my-branch" ]]
}
```

Key conventions:

- Always clean up in `teardown()` — remove everything under `TEST_TMPDIR`.
- Use `create_yaml_fixture` to create config files rather than inline heredocs.
- Test one behaviour per `@test` block with a descriptive name.
