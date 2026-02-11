#!/bin/bash
# Bash completion for wt (Git Worktree Manager)

_wt_completions() {
    local cur prev words cword
    _init_completion || return

    local commands="create new delete rm list ls start up stop down status st attach a run exec init config ports send s logs log panes doctor doc help version"

    # Get current word and previous word
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Determine the command (first non-option argument)
    local cmd=""
    for ((i=1; i < COMP_CWORD; i++)); do
        if [[ "${COMP_WORDS[i]}" != -* ]]; then
            cmd="${COMP_WORDS[i]}"
            break
        fi
    done

    # Helper: get service names from project config
    _wt_service_names() {
        local project_dir="$HOME/.config/wt/projects"
        local repo_root
        repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return
        local project_name
        project_name=$(basename "$repo_root")
        local config="$project_dir/${project_name}.yaml"
        if [[ -f "$config" ]] && command -v yq &>/dev/null; then
            yq -r '.services[].name // empty' "$config" 2>/dev/null
        fi
    }

    # Complete options for specific flags
    case "$prev" in
        -p|--project)
            # Complete with project names
            local projects=""
            if [[ -d "$HOME/.config/wt/projects" ]]; then
                projects=$(ls "$HOME/.config/wt/projects" 2>/dev/null | sed 's/\.yaml$//')
            fi
            COMPREPLY=($(compgen -W "$projects" -- "$cur"))
            return
            ;;
        --from)
            # Complete with branch names
            local branches=$(git branch -a 2>/dev/null | sed 's/^[* ]*//' | sed 's|remotes/origin/||' | sort -u)
            COMPREPLY=($(compgen -W "$branches" -- "$cur"))
            return
            ;;
        -s|--service)
            # Complete with service names from config
            local services=$(_wt_service_names)
            COMPREPLY=($(compgen -W "$services" -- "$cur"))
            return
            ;;
        -w|--window)
            # Complete with window names
            COMPREPLY=()
            return
            ;;
        --lines|-n)
            # Numeric argument, no completion
            COMPREPLY=()
            return
            ;;
    esac

    # Complete based on command
    case "$cmd" in
        "")
            # No command yet, complete with commands
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-h --help -v --version" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "$commands" -- "$cur"))
            fi
            ;;
        create|new)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "--from --no-setup -p --project -h --help" -- "$cur"))
            else
                # Complete with remote branches not yet checked out locally
                local branches=$(git branch -r 2>/dev/null | sed 's|origin/||' | grep -v HEAD | sort -u)
                COMPREPLY=($(compgen -W "$branches" -- "$cur"))
            fi
            ;;
        start|up)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-s --service -a --all --attach -p --project -h --help" -- "$cur"))
            else
                # Complete with worktrees and service names
                local worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                local services=$(_wt_service_names)
                COMPREPLY=($(compgen -W "$worktrees $services" -- "$cur"))
            fi
            ;;
        stop|down)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-s --service -a --all -p --project -h --help" -- "$cur"))
            else
                local worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                local services=$(_wt_service_names)
                COMPREPLY=($(compgen -W "$worktrees $services" -- "$cur"))
            fi
            ;;
        delete|rm)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-f --force --keep-branch -p --project -h --help" -- "$cur"))
            else
                local worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                COMPREPLY=($(compgen -W "$worktrees" -- "$cur"))
            fi
            ;;
        status|st)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "--services -p --project -h --help" -- "$cur"))
            else
                local worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                COMPREPLY=($(compgen -W "$worktrees" -- "$cur"))
            fi
            ;;
        attach|a)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-w --window -p --project -h --help" -- "$cur"))
            else
                local worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                COMPREPLY=($(compgen -W "$worktrees" -- "$cur"))
            fi
            ;;
        run)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-p --project -h --help" -- "$cur"))
            else
                local worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                COMPREPLY=($(compgen -W "$worktrees" -- "$cur"))
            fi
            ;;
        exec)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-p --project -h --help" -- "$cur"))
            else
                local worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                COMPREPLY=($(compgen -W "$worktrees" -- "$cur"))
            fi
            ;;
        ports)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-c --check -p --project -h --help" -- "$cur"))
            else
                # First positional could be set/clear subcommand or branch
                local worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                COMPREPLY=($(compgen -W "set clear $worktrees" -- "$cur"))
            fi
            ;;
        send|s)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-p --project -h --help" -- "$cur"))
            else
                local worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                local services=$(_wt_service_names)
                COMPREPLY=($(compgen -W "$worktrees $services" -- "$cur"))
            fi
            ;;
        logs|log)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "--lines -n --all -a -p --project -h --help" -- "$cur"))
            else
                local worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                local services=$(_wt_service_names)
                COMPREPLY=($(compgen -W "$worktrees $services" -- "$cur"))
            fi
            ;;
        panes)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-p --project -h --help" -- "$cur"))
            else
                local worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                COMPREPLY=($(compgen -W "$worktrees" -- "$cur"))
            fi
            ;;
        doctor|doc)
            COMPREPLY=($(compgen -W "-p --project -h --help" -- "$cur"))
            ;;
        list|ls)
            COMPREPLY=($(compgen -W "-p --project -s --status --json -h --help" -- "$cur"))
            ;;
        init)
            COMPREPLY=($(compgen -W "-n --name -f --force -h --help" -- "$cur"))
            ;;
        config)
            COMPREPLY=($(compgen -W "-e --edit -g --global -p --project --path -h --help" -- "$cur"))
            ;;
        *)
            COMPREPLY=()
            ;;
    esac
}

complete -F _wt_completions wt
