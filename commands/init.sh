#!/bin/bash
# commands/init.sh - Initialize project configuration

cmd_init() {
    local project_name=""
    local force=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                project_name="$2"
                shift 2
                ;;
            -f|--force)
                force=1
                shift
                ;;
            -h|--help)
                show_init_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_init_help
                return 1
                ;;
            *)
                shift
                ;;
        esac
    done

    # Check we're in a git repo
    if ! is_git_repo; then
        die "Not in a git repository. Navigate to a git repo first."
    fi

    local repo_root
    repo_root=$(git_root)

    # Determine project name
    if [[ -z "$project_name" ]]; then
        project_name=$(basename "$repo_root")
    fi

    # Sanitize project name: replace unsafe chars with hyphens, strip leading/trailing hyphens
    project_name=$(echo "$project_name" | sed 's/[^a-zA-Z0-9._-]/-/g' | sed 's/^-*//;s/-*$//')

    if [[ -z "$project_name" ]]; then
        die "Could not derive a valid project name. Use --name to specify one."
    fi

    if ! [[ "$project_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        die "Invalid project name: '$project_name'. Must start with alphanumeric and contain only [a-zA-Z0-9._-]"
    fi

    local config_file
    config_file=$(project_config_path "$project_name")

    # Check if config already exists
    if [[ -f "$config_file" ]] && [[ "$force" -eq 0 ]]; then
        die "Configuration already exists: $config_file\nUse --force to overwrite."
    fi

    # Ensure config directories exist
    init_config_dirs

    # Create configuration
    log_info "Creating configuration for project: $project_name"

    cat > "$config_file" << EOF
# Configuration for project: $project_name
name: $project_name
repo_path: $repo_root

# Port configuration
ports:
  # Reserved ports for services requiring specific ports
  reserved:
    range: { min: 3000, max: 3005 }
    slots: 3
    services: {}
      # service-name: 0  # offset from slot base

  # Dynamic ports for flexible services
  dynamic:
    range: { min: 4000, max: 5000 }
    services: {}
      # service-name: true

# Global environment variables
env:
  NODE_ENV: development

# Setup steps (run on worktree create)
setup: []
  # - name: install-deps
  #   description: "Install dependencies"
  #   command: npm install
  #   working_dir: "."
  #   on_failure: abort  # abort | continue | retry
  #   depends_on: []

# Services (can be started/stopped)
services: []
  # - name: app
  #   description: "Main application"
  #   working_dir: "."
  #   command: npm run dev
  #   port_key: app
  #   env:
  #     PORT: "\${PORT}"

# tmux session configuration
tmux:
  layout: tiled
  windows:
    - name: shell
      panes:
        - ""

# Hooks (lifecycle events)
hooks: {}
  # pre_create: |
  #   echo "About to create worktree for \${BRANCH_NAME}"
  # post_create: |
  #   echo "Worktree created at \${WORKTREE_PATH}"
  # pre_start: |
  #   echo "About to start services for \${BRANCH_NAME}"
  # post_start: |
  #   echo "Services started for \${BRANCH_NAME}"
  # post_stop: |
  #   echo "Services stopped for \${BRANCH_NAME}"
  # pre_delete: |
  #   echo "About to delete \${WORKTREE_PATH}"
  # post_delete: |
  #   echo "Worktree deleted for \${BRANCH_NAME}"
EOF

    # Add .worktrees to .gitignore
    local gitignore="$repo_root/.gitignore"
    if [[ -f "$gitignore" ]]; then
        if ! grep -q "^\.worktrees/?$" "$gitignore" 2>/dev/null; then
            echo ".worktrees/" >> "$gitignore"
            log_info "Added .worktrees/ to .gitignore"
        fi
    else
        echo ".worktrees/" > "$gitignore"
        log_info "Created .gitignore with .worktrees/"
    fi

    log_success "Configuration created: $config_file"
    echo ""
    echo "Next steps:"
    echo "  1. Edit the configuration to match your project:"
    echo "     \$EDITOR $config_file"
    echo ""
    echo "  2. Create your first worktree:"
    echo "     wt create <branch-name>"
}

show_init_help() {
    cat << 'EOF'
Usage: wt init [options]

Initialize wt configuration for the current git repository.

Options:
  -n, --name        Project name (default: directory name)
  -f, --force       Overwrite existing configuration
  -h, --help        Show this help message

Examples:
  wt init
  wt init --name my-project
  wt init --force
EOF
}
