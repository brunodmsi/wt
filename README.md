# wt - Git Worktree Manager

A CLI tool for managing git worktrees with tmux integration, automatic port allocation, and per-project setup automation.

## Why?

When working on multiple features/branches simultaneously, constantly switching branches is painful. Git worktrees let you have multiple branches checked out at once, but setting them up (especially for projects with submodules, multiple services, and specific port requirements) is tedious.

`wt` automates all of that.

## Features

- **Worktree lifecycle**: `create`, `delete`, `list`, `status`
- **Service management**: Start/stop services in tmux panes
- **Port allocation**: Reserved ports for OAuth/Privy, hash-based dynamic ports
- **Setup automation**: Run install scripts, copy envs, init submodules
- **tmux integration**: Auto-create sessions with configured layouts
- **Tmux integration**: Send commands, capture logs, list panes
- **Diagnostics**: `wt doctor` validates config, state, and tmux health
- **Shell completions**: Tab-complete commands, branches, and service names

## Installation

```bash
# Install dependencies
brew install yq tmux

# Run installer
./install.sh

# Restart shell or source completions
source ~/.zshrc  # or ~/.bashrc
```

## Quick Start

```bash
# 1. Initialize in your project
cd ~/your-project
wt init

# 2. Edit the config
$EDITOR ~/.config/wt/projects/your-project.yaml

# 3. Create a worktree
wt create feature/my-feature --from main

# 4. Start services
wt start feature/my-feature --all

# 5. Attach to tmux
wt attach feature/my-feature

# 6. When done
wt stop feature/my-feature --all
wt delete feature/my-feature
```

## Commands

| Command | Alias | Description |
|---------|-------|-------------|
| `wt create <branch>` | `new` | Create worktree + run setup |
| `wt delete <branch>` | `rm` | Stop services, kill tmux, remove worktree |
| `wt list` | `ls` | List all worktrees |
| `wt start <branch> --all` | `up` | Start services |
| `wt stop <branch> --all` | `down` | Stop services |
| `wt status <branch>` | `st` | Show worktree & service status |
| `wt attach <branch>` | `a` | Attach to tmux session |
| `wt send <branch> <svc> <cmd>` | `s` | Send command to a tmux pane |
| `wt logs <branch> [svc]` | `log` | Capture tmux pane output |
| `wt panes <branch>` | | List panes for a worktree |
| `wt ports <branch>` | | Show port assignments |
| `wt doctor` | `doc` | Run diagnostic checks |
| `wt config --edit` | | Edit project config |

## Configuration

Configs live in `~/.config/wt/projects/<name>.yaml`

For complete configuration reference, see **[docs/configuration.md](docs/configuration.md)**.

### Quick Example

```yaml
name: my-project
repo_path: ~/code/my-project

ports:
  reserved:
    range: { min: 3000, max: 3005 }
    slots: 3  # max concurrent worktrees
    services:
      frontend: 0  # slot_base + 0
      backend: 1   # slot_base + 1
  dynamic:
    range: { min: 4000, max: 5000 }
    services:
      worker: true  # hash-based port

setup:
  - name: install-deps
    command: npm install
    working_dir: "."
    on_failure: abort

services:
  - name: frontend
    command: npm run dev
    working_dir: frontend
    port_key: frontend
    health_check:
      type: tcp
      port: "${PORT}"
      timeout: 60

tmux:
  layout: services-top  # services on top row, main panes on bottom
  windows:
    - name: dev
      panes:
        - service: frontend
        - service: backend
        - command: claude
        - command: ""  # orchestrator pane

hooks:
  post_start: |
    echo "App running at http://localhost:${PORT_FRONTEND}"
```

## Port Allocation

For services requiring specific ports (OAuth callbacks, Privy):

| Slot | Service 0 | Service 1 |
|------|-----------|-----------|
| 0 | 3000 | 3001 |
| 1 | 3002 | 3003 |
| 2 | 3004 | 3005 |

Max 3 concurrent worktrees can use reserved ports. Dynamic services get deterministic hash-based ports.

## Tmux Integration

Once services are running in tmux, you can interact with panes directly:

```bash
# Send a command to a service pane
wt send feature/auth api-server "npm restart"

# View output from a specific pane
wt logs feature/auth api-server --lines 100

# View all pane output at once
wt logs feature/auth --all

# List pane layout and service mapping
wt panes feature/auth
```

Inside a worktree directory, the branch is auto-detected:

```bash
cd ~/project/.worktrees/feature-auth
wt send api-server "echo hello"    # branch auto-detected
wt logs --all                       # branch auto-detected
```

## Diagnostics

```bash
# Run health checks on your setup
wt doctor

# Check a specific project
wt doctor -p myproject
```

Doctor checks: dependencies (with versions), YAML config validity, port range overlaps, orphaned state entries, stale PIDs, tmux session health, and port conflicts.

## Tips

- **Copy envs from main repo**: In setup steps, use `cp ../../../service/.env .env` to copy from the main repo's service directory
- **Check ports**: `wt ports <branch> --check` shows if ports are in use
- **Custom tmux layout**: Use `layout: services-top` for services on top, main pane on bottom
- **Skip setup**: `wt create <branch> --no-setup` to skip setup steps
- **Run single step**: `wt run <branch> <step-name>` to re-run a setup step
- **Debug panes**: `wt logs <branch> --all` to see all pane output at once
- **Diagnose issues**: `wt doctor` to verify your config and runtime state

## File Structure

```
~/.config/wt/
├── config.yaml              # Global defaults
└── projects/
    └── <project>.yaml       # Per-project config

~/.local/share/wt/
└── state/
    ├── slots.yaml           # Port slot assignments
    └── <project>.state.yaml # Worktree & service state
```

## Testing

```bash
# Install test framework
brew install bats-core

# Run all tests
bats tests/

# Run a specific test file
bats tests/test_utils.bats

# Run with verbose output
bats tests/ --verbose-run
```

Test coverage includes:
- **Unit tests**: `utils.sh`, `port.sh`, `config.sh`, `state.sh`, `worktree.sh`
- **Integration tests**: `doctor`, `send`, `logs`, `panes` commands
- **End-to-end**: Full lifecycle with tmux session management

## License

MIT
