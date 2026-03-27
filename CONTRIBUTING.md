# Contributing to wt

## Prerequisites

- macOS (bash 3.2 compatible)
- `yq` (mikefarah v4): `brew install yq`
- `tmux`: `brew install tmux`
- `bats-core` (for tests): `brew install bats-core`

## Getting Started

```bash
git clone <repo>
cd wt
./install.sh
```

## Making Changes

### Directory Layout

```
wt.sh              # Entry point — dispatches to commands/
lib/               # Sourced modules: utils, config, port, state, worktree, setup, tmux, service
commands/          # One file per CLI command (cmd_<name> functions)
tests/             # bats test files
docs/              # configuration.md reference
```

### Code Style

- Functions use `snake_case`, prefixed by domain: `log_`, `yaml_`, `get_`, `set_`, etc.
- New commands go in `commands/<name>.sh` as `cmd_<name>()`.
- Use `log_info`, `log_warn`, `log_error`, `log_success` for output (all to stderr).
- Use `die "message"` for fatal errors.
- Quote all variable expansions; use `"${var:-}"` for potentially unset variables.
- Prefer `[[ ]]` over `[ ]` for conditionals.

### Compatibility

All code must run under **macOS bash 3.2**:

- No namerefs (`declare -n`).
- No `${var//[^pattern]/}` — use `sed`/`tr` instead.
- Use only portable flags for `sed`, `awk`, `tr`, `cksum` — no GNU-only options.
- `yq` is mikefarah v4 — use `strenv()` for safe YAML string injection.

## Testing

Every change requires tests:

- **New feature**: add unit tests in `tests/test_<module>.bats` and integration tests in `tests/test_commands.bats` or `tests/test_e2e.bats`.
- **Bug fix**: add a regression test that would have caught the bug before the fix.
- **Prefer non-tmux tests** — call library functions directly. Reserve tmux-dependent tests for `test_e2e.bats`.

### Running Tests

```bash
# Full suite
bats tests/

# Single file
bats tests/test_utils.bats

# Filter by name
bats tests/test_commands.bats -f "hooks"

# Verbose output
bats tests/ --verbose-run
```

### Writing Tests

Tests use a temp directory (`TEST_TMPDIR`) and real git repos created in `setup()`. Always clean up in `teardown()`. Use `create_yaml_fixture` from `tests/test_helper.bash` to create config files.

## Submitting a Pull Request

1. Fork the repo and create a branch from `main`.
2. Make your changes following the code style above.
3. Add or update tests — the suite must pass cleanly with `bats tests/`.
4. Keep commits focused; one logical change per commit.
5. Open a pull request with a clear description of what changed and why.
