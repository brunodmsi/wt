#!/bin/bash
# wt - Git Worktree Manager
# A CLI tool for managing git worktrees with tmux integration

set -euo pipefail

VERSION="1.0.0"

# Determine script directory (resolve symlinks)
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    # If $SOURCE is relative, resolve it relative to the symlink's directory
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
WT_SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
export WT_SCRIPT_DIR

# Source library modules
source "${WT_SCRIPT_DIR}/lib/utils.sh"
source "${WT_SCRIPT_DIR}/lib/config.sh"
source "${WT_SCRIPT_DIR}/lib/port.sh"
source "${WT_SCRIPT_DIR}/lib/state.sh"
source "${WT_SCRIPT_DIR}/lib/worktree.sh"
source "${WT_SCRIPT_DIR}/lib/setup.sh"
source "${WT_SCRIPT_DIR}/lib/tmux.sh"
source "${WT_SCRIPT_DIR}/lib/service.sh"

# Source command modules
source "${WT_SCRIPT_DIR}/commands/create.sh"
source "${WT_SCRIPT_DIR}/commands/delete.sh"
source "${WT_SCRIPT_DIR}/commands/list.sh"
source "${WT_SCRIPT_DIR}/commands/start.sh"
source "${WT_SCRIPT_DIR}/commands/stop.sh"
source "${WT_SCRIPT_DIR}/commands/status.sh"
source "${WT_SCRIPT_DIR}/commands/attach.sh"
source "${WT_SCRIPT_DIR}/commands/run.sh"
source "${WT_SCRIPT_DIR}/commands/exec.sh"
source "${WT_SCRIPT_DIR}/commands/init.sh"
source "${WT_SCRIPT_DIR}/commands/config.sh"
source "${WT_SCRIPT_DIR}/commands/ports.sh"

# Show help
show_help() {
    echo -e "${BOLD}wt${NC} - Git Worktree Manager v${VERSION}

${BOLD}USAGE${NC}
    wt <command> [arguments] [options]

${BOLD}COMMANDS${NC}
    ${CYAN}Worktree Management${NC}
    create, new     Create a new worktree
    delete, rm      Delete a worktree
    list, ls        List all worktrees

    ${CYAN}Service Management${NC}
    start, up       Start services in a worktree
    stop, down      Stop services in a worktree
    status, st      Show worktree status

    ${CYAN}Session Management${NC}
    attach, a       Attach to tmux session

    ${CYAN}Utilities${NC}
    run             Run a setup step
    exec            Execute command in worktree
    ports           Show port assignments

    ${CYAN}Configuration${NC}
    init            Initialize project configuration
    config          View/edit configuration

${BOLD}OPTIONS${NC}
    -p, --project   Specify project name
    -v, --verbose   Enable verbose output
    -h, --help      Show help for command
    --version       Show version

${BOLD}EXAMPLES${NC}
    # Initialize a new project
    cd ~/my-project
    wt init

    # Create a worktree for a feature branch
    wt create feature/auth --from develop

    # Start all services
    wt start feature/auth --all

    # Attach to the tmux session
    wt attach feature/auth

    # Stop services and delete worktree
    wt stop feature/auth --all
    wt delete feature/auth

${BOLD}CONFIGURATION${NC}
    Global config:  ~/.config/wt/config.yaml
    Project configs: ~/.config/wt/projects/<name>.yaml

For more information on a command, run:
    wt <command> --help
"
}

# Show version
show_version() {
    echo "wt version $VERSION"
}

# Check dependencies
check_dependencies() {
    local missing=()

    if ! command_exists git; then
        missing+=("git")
    fi

    if ! command_exists yq; then
        missing+=("yq (install: brew install yq)")
    fi

    if ! command_exists tmux; then
        missing+=("tmux (install: brew install tmux)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies:"
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        exit 1
    fi
}

# Main command dispatcher
main() {
    # Handle no arguments
    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi

    local command="$1"
    shift

    # Handle global flags
    case "$command" in
        -h|--help|help)
            show_help
            exit 0
            ;;
        -v|--version|version)
            show_version
            exit 0
            ;;
    esac

    # Check dependencies before running commands
    check_dependencies

    # Initialize config directories
    init_config_dirs

    # Dispatch to command handlers
    case "$command" in
        create|new)
            cmd_create "$@"
            ;;
        delete|rm)
            cmd_delete "$@"
            ;;
        list|ls)
            cmd_list "$@"
            ;;
        start|up)
            cmd_start "$@"
            ;;
        stop|down)
            cmd_stop "$@"
            ;;
        status|st)
            cmd_status "$@"
            ;;
        attach|a)
            cmd_attach "$@"
            ;;
        run)
            cmd_run "$@"
            ;;
        exec)
            cmd_exec "$@"
            ;;
        init)
            cmd_init "$@"
            ;;
        config)
            cmd_config "$@"
            ;;
        ports)
            cmd_ports "$@"
            ;;
        *)
            log_error "Unknown command: $command"
            echo ""
            echo "Run 'wt --help' for usage information."
            exit 1
            ;;
    esac
}

# Run main
main "$@"
