# wt - Git Worktree Manager

[![CI](https://github.com/brunodmsi/wt/actions/workflows/ci.yml/badge.svg)](https://github.com/brunodmsi/wt/actions/workflows/ci.yml)

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

### macOS / Linux

**One-liner** (clones to `~/.local/share/wt/src` and installs the `wt` launcher):

```bash
# Dependency: yq (tmux optional, for service/session commands)
brew install yq tmux

curl -fsSL https://raw.githubusercontent.com/brunodmsi/wt/main/install.sh | bash

# Restart shell or source completions
source ~/.zshrc  # or ~/.bashrc
```

**From a clone** (for development or if you'd rather manage the checkout yourself):

```bash
git clone https://github.com/brunodmsi/wt.git && cd wt
./install.sh
```

Either way the launcher points at a live git checkout, so updating is one command:

```bash
wt update            # fast-forward to the latest version
wt update --check    # see if an update is available without applying it
```

### Windows (Git Bash / PowerShell) — the command is `gwt`

The tool runs natively in **Git Bash** (the MSYS2 environment bundled with
[Git for Windows](https://gitforwindows.org/)) and from **PowerShell**.
Worktree management — `init`, `create`, `delete`, `list`, `status`, `ports`,
`exec`, `run`, `config`, `doctor` — works without any extra setup.

> **On Windows the command is `gwt`, not `wt`.** `wt` is already taken by
> **Windows Terminal** (`wt.exe`), so typing `wt create …` would launch
> Windows Terminal, not this tool. The installer therefore installs the
> command as **`gwt`** and sets `WT_CMD=gwt` so all help and error text refers
> to `gwt`. (You can choose any name — set `WT_CMD` to match.)

> **tmux is not bundled with Git for Windows.** The service/session commands
> (`start`, `stop`, `restart`, `attach`, `send`, `logs`, `panes`) require a
> terminal multiplexer. Install **[psmux](https://github.com/psmux/psmux)** — a
> native Windows tmux clone — for the full workflow without WSL:
>
> ```powershell
> winget install psmux
> ```
>
> psmux ships a `tmux` shim, so when the installer sees it, it adds
> `set -g default-shell "C:\Program Files\Git\bin\bash.exe"` to your
> `~/.tmux.conf`. That matters: psmux panes default to **PowerShell**, but `wt`
> types **bash** commands into them, so pointing the pane shell at Git Bash is
> what makes sessions/panes work. (Restart any running psmux server with
> `tmux kill-server` after install to pick up the config.)
>
> `wt` auto-detects the active multiplexer at runtime — `herdr`, `dmux`, psmux's
> `tmux` shim, or `none` — so [herdr](https://herdr.dev) works too when you run
> `gwt` from inside a herdr pane (it also needs `jq`:
> `winget install jqlang.jq`). With none installed, worktree management still
> works and the session commands no-op.
> [WSL2](https://learn.microsoft.com/windows/wsl/) remains an alternative, where
> real tmux + bash run exactly as on Linux.

```bash
# 1. Install the one required dependency (yq). Pick one:
winget install MikeFarah.yq
#   scoop install yq
#   choco install yq

# 2. From a Git Bash shell — the one-liner works here too:
curl -fsSL https://raw.githubusercontent.com/brunodmsi/wt/main/install.sh | bash
#   or, from a cloned repo: ./install.sh
```

Update later with `gwt update` (or `gwt update --check`).

The installer detects Windows and, instead of a symlink (which needs elevated
privileges), writes two launchers into your install dir (`~/bin` by default),
both setting `WT_CMD=gwt` and leaving `WT_MULTIPLEXER` unset so `wt` auto-detects
the active multiplexer at runtime (herdr / dmux / psmux / none):

- `gwt`      — a Bash wrapper, used from **Git Bash**
- `gwt.cmd`  — a shim so `gwt` also works from **PowerShell / cmd.exe**

Make sure the install dir is on your `PATH`. Then, from PowerShell or Git Bash:

```powershell
cd C:\path\to\your-repo
gwt init
gwt create feature/my-feature --from main
gwt list
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
| `wt claim [path]` | | Adopt an externally-created worktree (e.g. Orca) + run setup |
| `wt release [path]` | `unclaim` | Drop a claimed worktree's state/slot (keeps the directory) |
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
| `wt update` | `upgrade` | Update wt to the latest version |

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

## Multiplexer Support

`wt create` and `wt attach` detect the active terminal multiplexer:

- **tmux** — full window/pane/layout/service orchestration (default).
- **dmux** ([dmux.ai](https://dmux.ai)) — driven through tmux underneath.
- **herdr** ([herdr.dev](https://herdr.dev)) — first-class: opens a tab at the worktree
  path via `herdr tab create`, mounts the configured `tmux.layout` inside it using
  `pane.split`, and queues `cd <dir>` + per-pane commands in each resulting pane.
  `wt attach` focuses the matching tab via `herdr tab focus` or creates one if missing.
  `wt delete` closes the tab via `herdr tab close`. `wt start` tails service logs into
  the corresponding herdr pane (pane_id is persisted per service at create time).
  Pane sizes follow herdr's 50/50 default since herdr's `pane.split` does not yet
  support percentage sizing.
- **`herdr.post_create` / `herdr.post_attach`** YAML blocks queue commands into the
  worktree's tab after it mounts (e.g. start a dev server, run `git status`).
  `post_create` runs on `wt create`; `post_attach` runs on `wt attach` when a new tab
  is created — focusing an existing tab is left untouched on purpose. Both land in
  the orchestrator-style last pane when a layout is mounted, otherwise in the single
  initial pane.
- **`wt attach --here`** skips tab creation/focus and operates on the caller's
  current pane: under herdr it `pane.run`s `cd <path>` + `post_attach`; under tmux it
  `send-keys` the `cd` to `$TMUX_PANE`.
- **none** — worktree is created, but no multiplexer integration runs.
- Set `WT_MULTIPLEXER=tmux|dmux|herdr|none` to override detection. Run `wt doctor` to see what's detected.
- `jq` is required when running under herdr (response parsing for tab/pane lookups).

## Adopting External Worktrees (`claim` / `release`)

When another tool (e.g. [Orca](https://orca.computer)) creates the git worktree itself —
often in its own directory outside `<repo>/.worktrees` — use `wt claim` to **adopt** it
instead of `wt create`. Claiming registers state, allocates a port slot, and runs the
project's setup steps so that `wt start`, `wt attach`, `wt status`, `wt ports`, `wt logs`,
etc. all work on it exactly as if `wt create` had made it.

```bash
# Adopt an existing worktree (default path: current directory)
wt claim ~/orca/workspaces/myapp/feature-x
wt claim "$ORCA_WORKTREE_PATH"        # from an Orca setup hook

# Drop the adoption when done — keeps the directory (the external tool owns it)
wt release ~/orca/workspaces/myapp/feature-x
wt release "$ORCA_WORKTREE_PATH"      # from an Orca archive hook
```

Path resolution is **state-authoritative**: `wt` records the worktree's real path and the
main repo is resolved from the git common dir, so a claimed worktree can live anywhere.
Project detection matches the config whose `repo_path` is the worktree's main repo (or
falls back to its basename); override with `--project`. The branch defaults to the
worktree's `HEAD` (override with `--branch`).

`wt release` stops services, drops state and the port slot, but **never** runs
`git worktree remove` — the tool that created the directory owns it.

> **Orca hooks**: set the repo's setup hook to `wt claim "$ORCA_WORKTREE_PATH"` and its
> archive hook to `wt release "$ORCA_WORKTREE_PATH"`. Ensure `wt` and its deps (`yq`,
> `git`, `tmux`, …) are on `PATH` in Orca's spawned shell.

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

- **Copy envs from main repo**: In setup steps, prefer `$MAIN_REPO` over `../..` so steps work whether the worktree lives in `<repo>/.worktrees` or was adopted via `wt claim` from elsewhere — e.g. `cp "${MAIN_REPO:-../..}/service/.env" .env`. `MAIN_REPO` is exported by both `wt create` and `wt claim` before setup runs.
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
