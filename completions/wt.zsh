#compdef wt
# Zsh completion for wt (Git Worktree Manager)

_wt() {
    local -a commands
    local -a worktrees
    local -a branches
    local -a projects

    commands=(
        'create:Create a new worktree'
        'new:Create a new worktree (alias)'
        'delete:Delete a worktree'
        'rm:Delete a worktree (alias)'
        'list:List all worktrees'
        'ls:List all worktrees (alias)'
        'start:Start services in worktree'
        'up:Start services (alias)'
        'stop:Stop services in worktree'
        'down:Stop services (alias)'
        'status:Show worktree status'
        'st:Show worktree status (alias)'
        'attach:Attach to tmux session'
        'a:Attach to tmux session (alias)'
        'run:Run a setup step'
        'exec:Execute command in worktree'
        'ports:Show port assignments'
        'send:Send command to a tmux pane'
        's:Send command (alias)'
        'logs:Capture pane output'
        'log:Capture pane output (alias)'
        'panes:List panes for a worktree'
        'doctor:Run diagnostic checks'
        'doc:Run diagnostic checks (alias)'
        'init:Initialize project configuration'
        'config:View/edit configuration'
        'help:Show help'
        'version:Show version'
    )

    # Function to get worktree branches
    _wt_worktrees() {
        worktrees=(${(f)"$(git worktree list --porcelain 2>/dev/null | grep '^branch' | sed 's|branch refs/heads/||')"})
        _describe 'worktree' worktrees
    }

    # Function to get all branches
    _wt_branches() {
        branches=(${(f)"$(git branch -a 2>/dev/null | sed 's/^[* ]*//' | sed 's|remotes/origin/||' | sort -u)"})
        _describe 'branch' branches
    }

    # Function to get projects
    _wt_projects() {
        if [[ -d "$HOME/.config/wt/projects" ]]; then
            projects=(${(f)"$(ls $HOME/.config/wt/projects 2>/dev/null | sed 's/\.yaml$//')"})
            _describe 'project' projects
        fi
    }

    # Function to get service names
    _wt_services() {
        local project_dir="$HOME/.config/wt/projects"
        local repo_root
        repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return
        local project_name
        project_name=$(basename "$repo_root")
        local config="$project_dir/${project_name}.yaml"
        if [[ -f "$config" ]] && (( $+commands[yq] )); then
            local -a services
            services=(${(f)"$(yq -r '.services[].name // empty' "$config" 2>/dev/null)"})
            _describe 'service' services
        fi
    }

    # Main completion logic
    _arguments -C \
        '1: :->command' \
        '*:: :->args'

    case "$state" in
        command)
            _describe -t commands 'wt command' commands
            ;;
        args)
            case "$words[1]" in
                create|new)
                    _arguments \
                        '--from[Base branch to create from]:branch:_wt_branches' \
                        '--no-setup[Skip running setup steps]' \
                        '(-p --project)'{-p,--project}'[Project name]:project:_wt_projects' \
                        '(-h --help)'{-h,--help}'[Show help]' \
                        '1:branch:_wt_branches'
                    ;;
                start|up)
                    _arguments \
                        '(-s --service)'{-s,--service}'[Start specific service]:service:_wt_services' \
                        '(-a --all)'{-a,--all}'[Start all services]' \
                        '--attach[Attach to tmux after starting]' \
                        '(-p --project)'{-p,--project}'[Project name]:project:_wt_projects' \
                        '(-h --help)'{-h,--help}'[Show help]' \
                        '*:worktree or service:_wt_worktrees'
                    ;;
                stop|down)
                    _arguments \
                        '(-s --service)'{-s,--service}'[Stop specific service]:service:_wt_services' \
                        '(-a --all)'{-a,--all}'[Stop all services]' \
                        '(-p --project)'{-p,--project}'[Project name]:project:_wt_projects' \
                        '(-h --help)'{-h,--help}'[Show help]' \
                        '*:worktree or service:_wt_worktrees'
                    ;;
                delete|rm)
                    _arguments \
                        '(-f --force)'{-f,--force}'[Force deletion]' \
                        '--keep-branch[Do not delete the git branch]' \
                        '(-p --project)'{-p,--project}'[Project name]:project:_wt_projects' \
                        '(-h --help)'{-h,--help}'[Show help]' \
                        '1:worktree:_wt_worktrees'
                    ;;
                status|st)
                    _arguments \
                        '--services[Show detailed service status]' \
                        '(-p --project)'{-p,--project}'[Project name]:project:_wt_projects' \
                        '(-h --help)'{-h,--help}'[Show help]' \
                        '1:worktree:_wt_worktrees'
                    ;;
                attach|a)
                    _arguments \
                        '(-w --window)'{-w,--window}'[Select specific window]:window:' \
                        '(-p --project)'{-p,--project}'[Project name]:project:_wt_projects' \
                        '(-h --help)'{-h,--help}'[Show help]' \
                        '1:worktree:_wt_worktrees'
                    ;;
                run)
                    _arguments \
                        '(-p --project)'{-p,--project}'[Project name]:project:_wt_projects' \
                        '(-h --help)'{-h,--help}'[Show help]' \
                        '1:worktree:_wt_worktrees' \
                        '2:step:'
                    ;;
                exec)
                    _arguments \
                        '(-p --project)'{-p,--project}'[Project name]:project:_wt_projects' \
                        '(-h --help)'{-h,--help}'[Show help]' \
                        '1:worktree:_wt_worktrees' \
                        '*:command:_command_names'
                    ;;
                ports)
                    _arguments \
                        '(-c --check)'{-c,--check}'[Check port availability]' \
                        '(-p --project)'{-p,--project}'[Project name]:project:_wt_projects' \
                        '(-h --help)'{-h,--help}'[Show help]' \
                        '1:subcommand or worktree:(set clear)'
                    ;;
                send|s)
                    _arguments \
                        '(-p --project)'{-p,--project}'[Project name]:project:_wt_projects' \
                        '(-h --help)'{-h,--help}'[Show help]' \
                        '1:worktree or service:_wt_worktrees' \
                        '2:service:_wt_services' \
                        '*:command:'
                    ;;
                logs|log)
                    _arguments \
                        '(-n --lines)'{-n,--lines}'[Number of lines]:lines:' \
                        '(-a --all)'{-a,--all}'[Show all panes]' \
                        '(-p --project)'{-p,--project}'[Project name]:project:_wt_projects' \
                        '(-h --help)'{-h,--help}'[Show help]' \
                        '1:worktree or service:_wt_worktrees' \
                        '2:service:_wt_services'
                    ;;
                panes)
                    _arguments \
                        '(-p --project)'{-p,--project}'[Project name]:project:_wt_projects' \
                        '(-h --help)'{-h,--help}'[Show help]' \
                        '1:worktree:_wt_worktrees'
                    ;;
                doctor|doc)
                    _arguments \
                        '(-p --project)'{-p,--project}'[Project name]:project:_wt_projects' \
                        '(-h --help)'{-h,--help}'[Show help]'
                    ;;
                list|ls)
                    _arguments \
                        '(-p --project)'{-p,--project}'[Project name]:project:_wt_projects' \
                        '(-s --status)'{-s,--status}'[Show status information]' \
                        '--json[Output as JSON]' \
                        '(-h --help)'{-h,--help}'[Show help]'
                    ;;
                init)
                    _arguments \
                        '(-t --template)'{-t,--template}'[Template to use]:template:(default monorepo)' \
                        '(-n --name)'{-n,--name}'[Project name]:name:' \
                        '(-f --force)'{-f,--force}'[Overwrite existing config]' \
                        '(-h --help)'{-h,--help}'[Show help]'
                    ;;
                config)
                    _arguments \
                        '(-e --edit)'{-e,--edit}'[Open in editor]' \
                        '(-g --global)'{-g,--global}'[Global configuration]' \
                        '(-p --project)'{-p,--project}'[Project name]:project:_wt_projects' \
                        '--path[Print config file path]' \
                        '(-h --help)'{-h,--help}'[Show help]'
                    ;;
            esac
            ;;
    esac
}

compdef _wt wt
