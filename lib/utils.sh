#!/bin/bash
# lib/utils.sh - Logging, colors, and common utilities

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Logging functions - all output to stderr to not interfere with function return values
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_debug() {
    if [[ "${WT_DEBUG:-}" == "1" ]]; then
        echo -e "${DIM}[DEBUG]${NC} $*" >&2
    fi
}

log_step() {
    local current="$1"
    local total="$2"
    local message="$3"
    echo -e "${CYAN}[$current/$total]${NC} $message" >&2
}

# Spinner for long-running operations
spinner() {
    local pid=$1
    local message="${2:-Working...}"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % ${#spin} ))
        printf "\r${CYAN}%s${NC} %s" "${spin:$i:1}" "$message"
        sleep 0.1
    done
    printf "\r"
}

# Die with error message
die() {
    log_error "$@"
    exit 1
}

# Check if command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Require a command or die
require_command() {
    local cmd="$1"
    local install_hint="${2:-}"

    if ! command_exists "$cmd"; then
        if [[ -n "$install_hint" ]]; then
            die "'$cmd' is required but not installed. $install_hint"
        else
            die "'$cmd' is required but not installed."
        fi
    fi
}

# Sanitize branch name for filesystem/tmux use
sanitize_branch_name() {
    local branch="$1"
    # Replace / with - and remove other problematic chars
    echo "$branch" | sed 's|/|-|g' | sed 's|[^a-zA-Z0-9_-]||g'
}

# Check if we're in a git repository
is_git_repo() {
    git rev-parse --is-inside-work-tree &>/dev/null
}

# Get the root of the git repository
git_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

# Get current branch name
current_branch() {
    git rev-parse --abbrev-ref HEAD 2>/dev/null
}

# Check if a branch exists locally
branch_exists() {
    local branch="$1"
    git show-ref --verify --quiet "refs/heads/$branch"
}

# Check if a branch exists on remote
remote_branch_exists() {
    local branch="$1"
    local remote="${2:-origin}"
    git ls-remote --exit-code --heads "$remote" "$branch" &>/dev/null
}

# Confirm action with user
confirm() {
    local message="${1:-Are you sure?}"
    local default="${2:-n}"

    local prompt
    if [[ "$default" == "y" ]]; then
        prompt="[Y/n]"
    else
        prompt="[y/N]"
    fi

    read -r -p "$message $prompt " response
    response="${response:-$default}"

    [[ "$response" =~ ^[Yy]$ ]]
}

# Create directory if it doesn't exist
ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
    fi
}

# Get project name from repo path
get_project_name() {
    local repo_path="${1:-$(git_root)}"
    basename "$repo_path"
}

# Expand ~ in paths
expand_path() {
    local path="$1"
    echo "${path/#\~/$HOME}"
}

# Execute a command while holding an exclusive file lock
# Uses mkdir for portable atomic locking (works on macOS and Linux)
# Usage: with_file_lock "/path/to/file" command args...
with_file_lock() {
    local lock_dir="$1.lockdir"
    shift

    local max_wait=10
    local waited=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
        if (( waited >= max_wait )); then
            # Stale lock — force remove and retry
            rm -rf "$lock_dir"
            mkdir "$lock_dir" 2>/dev/null || true
            break
        fi
        sleep 0.1
        waited=$((waited + 1))
    done

    # Run the command, capture exit code, then release lock
    local rc=0
    "$@" || rc=$?
    rm -rf "$lock_dir"
    return $rc
}

# Check if port is in use
port_in_use() {
    local port="$1"
    lsof -i ":$port" &>/dev/null
}

# Wait for port to be available
wait_for_port() {
    local port="$1"
    local timeout="${2:-30}"
    local elapsed=0

    while ! nc -z localhost "$port" 2>/dev/null; do
        if (( elapsed >= timeout )); then
            return 1
        fi
        sleep 1
        ((elapsed++))
    done
    return 0
}

# Pretty print a key-value pair
print_kv() {
    local key="$1"
    local value="$2"
    local width="${3:-20}"
    printf "${BOLD}%-${width}s${NC} %s\n" "$key:" "$value"
}

# Print a table header
print_header() {
    echo -e "${BOLD}$*${NC}"
    echo "$(echo "$*" | sed 's/./-/g')"
}

# Truncate string to max length
truncate() {
    local str="$1"
    local max="${2:-30}"

    if (( ${#str} > max )); then
        echo "${str:0:$((max-3))}..."
    else
        echo "$str"
    fi
}

# Get timestamp
timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Parse flags from arguments
# Usage: parse_flags "$@"
# Sets global variables for common flags
parse_flags() {
    VERBOSE=0
    QUIET=0
    DRY_RUN=0
    FORCE=0
    POSITIONAL=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -q|--quiet)
                QUIET=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            -f|--force)
                FORCE=1
                shift
                ;;
            -h|--help)
                SHOW_HELP=1
                shift
                ;;
            --)
                shift
                POSITIONAL+=("$@")
                break
                ;;
            -*)
                # Unknown flag, let command handle it
                POSITIONAL+=("$1")
                shift
                ;;
            *)
                POSITIONAL+=("$1")
                shift
                ;;
        esac
    done
}
