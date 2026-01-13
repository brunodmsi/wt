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

# Check dependencies
check_dependencies() {
    local missing=()

    if ! command -v git &>/dev/null; then
        missing+=("git")
    fi

    if ! command -v yq &>/dev/null; then
        missing+=("yq")
    fi

    if ! command -v tmux &>/dev/null; then
        missing+=("tmux")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing dependencies:"
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        echo ""
        echo "Install with:"
        echo "  brew install ${missing[*]}"
        echo ""
        read -r -p "Continue anyway? [y/N] " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            exit 1
        fi
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

# Create symlink
create_symlink() {
    local target_dir="${1:-$HOME/bin}"
    local symlink="$target_dir/wt"

    # Create target directory if needed
    if [[ ! -d "$target_dir" ]]; then
        log_info "Creating directory: $target_dir"
        mkdir -p "$target_dir"
    fi

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
    create_symlink "$install_dir"

    if [[ "$skip_completions" -eq 0 ]]; then
        echo ""
        install_completions
    fi

    create_config_dirs

    echo ""
    echo -e "${GREEN}${BOLD}Installation complete!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Restart your shell or run: source ~/.bashrc (or ~/.zshrc)"
    echo "  2. Verify installation: wt --version"
    echo "  3. Initialize a project: cd <your-repo> && wt init"
    echo ""
    echo "For help: wt --help"
    echo ""
}

main "$@"
