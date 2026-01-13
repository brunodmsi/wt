#!/bin/bash
# commands/config.sh - View and edit configuration

cmd_config() {
    local edit=0
    local global=0
    local project=""
    local show_path=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -e|--edit)
                edit=1
                shift
                ;;
            -g|--global)
                global=1
                shift
                ;;
            -p|--project)
                project="$2"
                shift 2
                ;;
            --path)
                show_path=1
                shift
                ;;
            -h|--help)
                show_config_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_config_help
                return 1
                ;;
            *)
                if [[ -z "$project" ]]; then
                    project="$1"
                fi
                shift
                ;;
        esac
    done

    local config_file

    if [[ "$global" -eq 1 ]]; then
        config_file=$(global_config_path)

        # Create default global config if it doesn't exist
        if [[ ! -f "$config_file" ]]; then
            init_config_dirs
            cat > "$config_file" << 'EOF'
# Global wt configuration

# Default settings for all projects
defaults:
  worktree_dir: ".worktrees"
  port_range:
    min: 3000
    max: 5000
  tmux:
    prefix: "wt"
    default_layout: "even-horizontal"

# Editor to use for editing configs
editor:
  default: "${EDITOR:-vim}"

# Shell settings
shell:
  rc_file: "~/.zshrc"

# Logging
logging:
  enabled: true
  dir: "~/.local/share/wt/logs"
EOF
            log_info "Created default global config"
        fi
    else
        # Project config
        if [[ -z "$project" ]]; then
            project=$(detect_project)
            if [[ -z "$project" ]]; then
                die "Could not detect project. Specify a project name or use --global."
            fi
        fi

        config_file=$(project_config_path "$project")

        if [[ ! -f "$config_file" ]]; then
            die "No configuration found for project: $project\nRun 'wt init' in the project directory first."
        fi
    fi

    if [[ "$show_path" -eq 1 ]]; then
        echo "$config_file"
        return 0
    fi

    if [[ "$edit" -eq 1 ]]; then
        local editor="${EDITOR:-vim}"
        log_info "Opening: $config_file"
        $editor "$config_file"
    else
        # Display config
        echo ""
        if [[ "$global" -eq 1 ]]; then
            echo -e "${BOLD}Global Configuration${NC}"
        else
            echo -e "${BOLD}Project Configuration: ${CYAN}$project${NC}"
        fi
        echo "File: $config_file"
        echo "$(printf '%.0s-' {1..60})"
        echo ""

        if command_exists bat; then
            bat --style=plain --language=yaml "$config_file"
        elif command_exists pygmentize; then
            pygmentize -l yaml "$config_file"
        else
            cat "$config_file"
        fi
    fi
}

show_config_help() {
    cat << 'EOF'
Usage: wt config [options] [project]

View or edit wt configuration.

Arguments:
  [project]         Project name (auto-detected if not specified)

Options:
  -e, --edit        Open configuration in editor
  -g, --global      View/edit global configuration
  -p, --project     Specify project name
  --path            Just print the config file path
  -h, --help        Show this help message

Examples:
  wt config                   # Show current project config
  wt config --edit            # Edit current project config
  wt config --global          # Show global config
  wt config --global --edit   # Edit global config
  wt config myproject         # Show specific project config
  wt config --path            # Print config file path
EOF
}
