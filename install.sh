#!/bin/bash
# install.sh - Install wt (Git Worktree Manager)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Detect the host OS family: macos | windows | linux
os_family() {
    case "$(uname -s 2>/dev/null)" in
        Darwin*) echo "macos" ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        *) echo "linux" ;;
    esac
}

# Suggest an OS-appropriate install command for a dependency.
dep_install_hint() {
    local tool="$1"
    case "$(os_family)" in
        macos) echo "brew install $tool" ;;
        windows)
            case "$tool" in
                yq) echo "winget install MikeFarah.yq (or: scoop install yq)" ;;
                tmux) echo "optional; winget install psmux for native sessions, or use WSL2 for Linux-native tmux" ;;
                *) echo "winget install $tool (or: scoop install $tool)" ;;
            esac
            ;;
        *) echo "install $tool via your package manager (apt/dnf/pacman)" ;;
    esac
}

# Check dependencies
check_dependencies() {
    local missing=()
    local optional_missing=()

    command -v git &>/dev/null || missing+=("git")
    command -v yq &>/dev/null || missing+=("yq")
    # tmux is optional: worktree management works without it. Service/session
    # commands need it, and it has no native Windows build.
    command -v tmux &>/dev/null || optional_missing+=("tmux")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing required dependencies:"
        for dep in "${missing[@]}"; do
            echo "  - $dep ($(dep_install_hint "$dep"))"
        done
        echo ""
        read -r -p "Continue anyway? [y/N] " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    if [[ ${#optional_missing[@]} -gt 0 ]]; then
        echo ""
        log_warn "Missing optional dependencies (service/session features only):"
        for dep in "${optional_missing[@]}"; do
            echo "  - $dep ($(dep_install_hint "$dep"))"
        done
    fi
}

# Make scripts executable
make_executable() {
    log_info "Making scripts executable..."
    chmod +x "$SCRIPT_DIR/wt.sh"
    chmod +x "$SCRIPT_DIR/install.sh"
    chmod +x "$SCRIPT_DIR/lib/"*.sh 2>/dev/null || true
    chmod +x "$SCRIPT_DIR/commands/"*.sh 2>/dev/null || true
}

# Resolve the Windows path to the Git Bash launcher (bin\bash.exe), which sets
# up the MSYS PATH so panes get coreutils + git. Falls back to usr\bin\bash.exe.
# Echoes the Windows path on success; returns non-zero when it can't resolve
# (e.g. cygpath absent, i.e. not running under a Windows POSIX layer).
git_bash_launcher_win() {
    command -v cygpath &>/dev/null || return 1
    local root_win
    root_win=$(cygpath -w / 2>/dev/null)
    root_win="${root_win%\\}"
    [[ -n "$root_win" ]] || return 1
    if [[ -f "/bin/bash.exe" ]]; then
        printf '%s\\bin\\bash.exe' "$root_win"
    else
        printf '%s\\usr\\bin\\bash.exe' "$root_win"
    fi
}

# True when <file> already has an active (non-commented) default-shell setting.
tmux_conf_has_default_shell() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    grep -Eq '^[[:space:]]*set[^#]*default-shell' "$file"
}

# Append a managed default-shell block to <file> so psmux panes run bash.
# Returns 0 when it appends, 2 when a default-shell is already present (left
# untouched). Pure (takes file + shell path) so it is unit-testable.
ensure_tmux_conf_default_shell() {
    local file="$1"
    local shell_win="$2"

    if tmux_conf_has_default_shell "$file"; then
        return 2
    fi

    {
        [[ -f "$file" ]] && echo ""
        echo "# >>> wt (psmux) >>>"
        echo "# psmux panes default to PowerShell, but wt types bash commands into"
        echo "# them. Point the pane shell at Git Bash. Delete this block to opt out."
        echo "set -g default-shell \"$shell_win\""
        echo "# <<< wt (psmux) <<<"
    } >> "$file"
    return 0
}

# Windows-only: ensure ~/.tmux.conf makes psmux spawn bash panes. Called from
# create_launcher when a tmux shim (psmux) is detected.
ensure_psmux_bash_shell() {
    local conf="$HOME/.tmux.conf"
    local shell_win
    if ! shell_win=$(git_bash_launcher_win); then
        log_warn "Could not resolve the Git Bash path. Add this to ~/.tmux.conf so"
        log_warn "psmux panes run bash: set -g default-shell \"C:\\Program Files\\Git\\bin\\bash.exe\""
        return 0
    fi
    if ensure_tmux_conf_default_shell "$conf" "$shell_win"; then
        log_success "Set psmux pane shell to Git Bash in ~/.tmux.conf"
        log_info "Run 'tmux kill-server' to restart psmux and apply (default-shell: $shell_win)"
    else
        log_info "Left ~/.tmux.conf untouched — it already sets default-shell."
    fi
    return 0
}

# Install the launcher into target_dir.
# On macOS/Linux this is a symlink named "wt". On Windows the command is
# installed as "gwt" instead, because "wt" is taken by Windows Terminal
# (wt.exe); symlinks also need elevated privileges, so we write small launcher
# scripts. The Windows launchers set WT_CMD=gwt (so help/error text shows the
# right command name) and leave WT_MULTIPLEXER unset, so wt auto-detects the
# active multiplexer at runtime (herdr / dmux / psmux's tmux shim / none).
# Pinning it would hide herdr when gwt runs from inside a herdr pane.
#   - "gwt"     : a bash wrapper (used from Git Bash / MSYS2)
#   - "gwt.cmd" : a shim so "gwt" also works from PowerShell / cmd.exe
create_launcher() {
    local target_dir="${1:-$HOME/bin}"

    # Create target directory if needed
    if [[ ! -d "$target_dir" ]]; then
        log_info "Creating directory: $target_dir"
        mkdir -p "$target_dir"
    fi

    if [[ "$(os_family)" == "windows" ]]; then
        log_info "Installing as 'gwt' ('wt' is reserved by Windows Terminal)"

        # Don't pin WT_MULTIPLEXER — wt auto-detects it at runtime (herdr via
        # HERDR_SOCKET_PATH, then dmux, then psmux's tmux shim, else none).
        # Pinning would hide herdr when gwt runs inside a herdr pane. If psmux
        # (a native Windows tmux clone) is present, make sure its panes spawn
        # bash, since wt types bash commands into them.
        if command -v tmux &>/dev/null; then
            log_info "Detected a tmux shim (psmux) — ensuring its panes run bash"
            ensure_psmux_bash_shell
        fi

        local wrapper="$target_dir/gwt"
        log_info "Creating launcher: $wrapper -> $SCRIPT_DIR/wt.sh"
        cat > "$wrapper" << EOF
#!/usr/bin/env bash
export WT_CMD=gwt
exec "$SCRIPT_DIR/wt.sh" "\$@"
EOF
        chmod +x "$wrapper" 2>/dev/null || true

        local shim="$target_dir/gwt.cmd"
        # Resolve Git Bash to an absolute Windows path and set up the MSYS
        # PATH. Two pitfalls this avoids:
        #   1. A bare `bash` often resolves to WSL's
        #      C:\Windows\System32\bash.exe, which can't see /c/... paths.
        #   2. Calling usr\bin\bash.exe directly leaves coreutils (dirname,
        #      sed, ...) off PATH. Git's bin\bash.exe launcher sets PATH up
        #      and preserves the working directory.
        local bash_win="bash"
        local path_prefix=""
        if command -v cygpath &>/dev/null; then
            local root_win
            root_win=$(cygpath -w / 2>/dev/null)
            root_win="${root_win%\\}"
            if [[ -n "$root_win" ]]; then
                path_prefix="${root_win}\\mingw64\\bin;${root_win}\\usr\\bin;"
                if [[ -f "/bin/bash.exe" ]]; then
                    bash_win="${root_win}\\bin\\bash.exe"
                else
                    bash_win="${root_win}\\usr\\bin\\bash.exe"
                fi
            fi
        fi
        log_info "Creating launcher: $shim (for PowerShell / cmd.exe)"
        cat > "$shim" << EOF
@echo off
set "PATH=${path_prefix}%PATH%"
set "WT_CMD=gwt"
"$bash_win" "$SCRIPT_DIR/wt.sh" %*
EOF
    else
        local symlink="$target_dir/wt"

        # Remove existing symlink
        if [[ -L "$symlink" ]]; then
            log_info "Removing existing symlink..."
            rm "$symlink"
        elif [[ -f "$symlink" ]]; then
            log_warn "File exists at $symlink (not a symlink)"
            read -r -p "Replace? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                rm "$symlink"
            else
                return 1
            fi
        fi

        # Create symlink
        log_info "Creating symlink: $symlink -> $SCRIPT_DIR/wt.sh"
        ln -s "$SCRIPT_DIR/wt.sh" "$symlink"
    fi

    # Check if target_dir is in PATH
    if [[ ":$PATH:" != *":$target_dir:"* ]]; then
        log_warn "$target_dir is not in your PATH"
        echo ""
        echo "Add to your shell profile:"
        echo "  export PATH=\"\$PATH:$target_dir\""
    fi
}

# Install shell completions
install_completions() {
    local shell="${1:-}"

    # Detect shell if not specified
    if [[ -z "$shell" ]]; then
        shell=$(basename "$SHELL")
    fi

    case "$shell" in
        bash)
            local bash_completion_dir="${BASH_COMPLETION_USER_DIR:-$HOME/.local/share/bash-completion/completions}"
            mkdir -p "$bash_completion_dir"
            cp "$SCRIPT_DIR/completions/wt.bash" "$bash_completion_dir/wt"
            log_success "Installed bash completions to $bash_completion_dir/wt"

            # Also add to .bashrc for immediate availability
            local bashrc="$HOME/.bashrc"
            local source_line="source \"$SCRIPT_DIR/completions/wt.bash\""

            if [[ -f "$bashrc" ]]; then
                if ! grep -q "wt.bash" "$bashrc" 2>/dev/null; then
                    echo "" >> "$bashrc"
                    echo "# wt (Git Worktree Manager) completions" >> "$bashrc"
                    echo "$source_line" >> "$bashrc"
                    log_info "Added completion source to $bashrc"
                fi
            fi
            ;;
        zsh)
            local zsh_completion_dir="${ZSH_COMPLETION_DIR:-$HOME/.zsh/completions}"
            mkdir -p "$zsh_completion_dir"
            cp "$SCRIPT_DIR/completions/wt.zsh" "$zsh_completion_dir/_wt"
            log_success "Installed zsh completions to $zsh_completion_dir/_wt"

            # Add to fpath in .zshrc
            local zshrc="$HOME/.zshrc"
            local fpath_line="fpath=($zsh_completion_dir \$fpath)"

            if [[ -f "$zshrc" ]]; then
                if ! grep -q "$zsh_completion_dir" "$zshrc" 2>/dev/null; then
                    echo "" >> "$zshrc"
                    echo "# wt (Git Worktree Manager) completions" >> "$zshrc"
                    echo "$fpath_line" >> "$zshrc"
                    echo "autoload -Uz compinit && compinit" >> "$zshrc"
                    log_info "Added completion fpath to $zshrc"
                fi
            fi
            ;;
        *)
            log_warn "Unknown shell: $shell. Manual completion setup required."
            ;;
    esac
}

# Create config directories
create_config_dirs() {
    log_info "Creating configuration directories..."
    mkdir -p "$HOME/.config/wt/projects"
    mkdir -p "$HOME/.local/share/wt/state"
    mkdir -p "$HOME/.local/share/wt/logs"
}

# Main installation
main() {
    echo ""
    echo -e "${BOLD}wt - Git Worktree Manager${NC}"
    echo -e "${BOLD}=========================${NC}"
    echo ""

    # Parse arguments
    local install_dir="$HOME/bin"
    local skip_completions=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prefix)
                install_dir="$2"
                shift 2
                ;;
            --no-completions)
                skip_completions=1
                shift
                ;;
            -h|--help)
                echo "Usage: ./install.sh [options]"
                echo ""
                echo "Options:"
                echo "  --prefix DIR        Install directory (default: ~/bin)"
                echo "  --no-completions    Skip shell completion installation"
                echo "  -h, --help          Show this help"
                exit 0
                ;;
            *)
                shift
                ;;
        esac
    done

    # Run installation steps
    check_dependencies
    make_executable
    create_launcher "$install_dir"

    if [[ "$skip_completions" -eq 0 ]]; then
        echo ""
        install_completions
    fi

    create_config_dirs

    # Command name: "gwt" on Windows (wt = Windows Terminal), else "wt".
    local cmd="wt"
    [[ "$(os_family)" == "windows" ]] && cmd="gwt"

    echo ""
    echo -e "${GREEN}${BOLD}Installation complete!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Restart your shell or run: source ~/.bashrc (or ~/.zshrc)"
    echo "  2. Verify installation: $cmd --version"
    echo "  3. Initialize a project: cd <your-repo> && $cmd init"
    echo ""
    echo "For help: $cmd --help"
    echo ""
}

# Only run the installer when executed directly; sourcing (e.g. from tests)
# exposes the helper functions without performing an install.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
