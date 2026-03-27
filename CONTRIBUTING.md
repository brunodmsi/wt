# Contributing to wt

Thanks for your interest in contributing! This document covers everything you need to get started.

## Prerequisites

- **bash** — macOS ships with bash 3.2; all code must be compatible with it
- **git** — for worktree operations
- **yq** (mikefarah v4) — YAML processing: `brew install yq`
- **tmux** — session management: `brew install tmux`
- **bats-core** — test runner: `brew install bats-core`

## Getting Started

```bash
git clone <repo-url>
cd wt
./install.sh
```

Run the test suite to verify everything works:

```bash
bats tests/
```

## Project Structure

```
wt.sh              # Entry point — sources all modules, dispatches commands
lib/               # Core library modules (sourced by wt.sh)
commands/          # One file per CLI command (cmd_<name> functions)
tests/             # bats test files — one per lib module + integration tests
docs/              # Configuration reference
completions/       # Shell completions (bash, zsh)
```

See [CLAUDE.md](CLAUDE.md) for a detailed architecture overview and the full list of key patterns.

## Code Style

- **Function names**: `snake_case`, prefixed by domain — `log_`, `yaml_`, `get_`, `set_`, etc.
- **Command functions**: `cmd_<name>()` defined in `commands/<name>.sh`
- **Logging**: use `log_info`, `log_warn`, `log_error`, `log_success` (all write to stderr)
- **Fatal errors**: use `die "message"` — never call `exit 1` directly
- **Variables**: quote all expansions; use `"${var:-}"` for potentially unset variables
- **Conditionals**: prefer `[[ ]]` over `[ ]`
- **Compatibility**: no bash 4+ features — no `declare -n` namerefs, no `${var//[^pattern]/}`, no GNU-only flags
- **YAML injection**: always use `strenv()` with yq for safe string injection

## Making Changes

### Adding a new command

1. Create `commands/<name>.sh` with a `cmd_<name>()` function.
2. Register the command in `wt.sh` (the dispatch table).
3. Add tab-completion entries in `completions/wt.bash` and `completions/wt.zsh`.
4. Add unit tests in `tests/test_commands.bats` and, if applicable, `tests/test_e2e.bats`.

### Adding a new library function

1. Add the function to the appropriate module in `lib/`.
2. Add unit tests to the matching `tests/test_<module>.bats`.

### Fixing a bug

1. Write a failing regression test that reproduces the bug first.
2. Fix the bug.
3. Confirm the test now passes.

## Testing

Tests use [bats-core](https://github.com/bats-core/bats-core).

```bash
# Run the full suite
bats tests/

# Run a single file
bats tests/test_commands.bats

# Filter by test name
bats tests/test_commands.bats -f "hooks"
```

**Rules:**
- Every new feature must have both unit tests (in the relevant `tests/test_<module>.bats`) and integration tests (in `tests/test_commands.bats` or `tests/test_e2e.bats`).
- Every bug fix must include a regression test.
- Avoid tmux-dependent tests where possible — test library functions directly. Reserve full tmux tests for `test_e2e.bats`.
- Tests use a temp directory (`TEST_TMPDIR`) and a real git repo created in `setup()`. Clean up in `teardown()`.
- Use `create_yaml_fixture` from `tests/test_helper.bash` to build config files in tests.

## Submitting Changes

1. Fork the repository and create a branch from `main`.
2. Make your changes following the code style above.
3. Run `bats tests/` — all tests must pass.
4. Open a pull request with a clear description of what changed and why.

For large changes, consider opening an issue first to discuss the approach.

## Reporting Issues

Please include:
- Output of `wt doctor` (redact any sensitive paths/values)
- The command you ran and the full error output
- OS and shell version (`bash --version`, `yq --version`, `tmux -V`)
