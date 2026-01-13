#!/bin/bash
# Bash completion for wt (Git Worktree Manager)

_wt_completions() {
    local cur prev words cword
    _init_completion || return

    local commands="create new delete rm list ls start up stop down status st attach a run exec init config ports help version"

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
            # This is a simplified version - ideally would parse the YAML
            COMPREPLY=()
            return
            ;;
        -w|--window)
            # Complete with window names
            COMPREPLY=()
            return
            ;;
        -t|--template)
            # Complete with template names
            local templates=""
            local wt_dir="${WT_SCRIPT_DIR:-$HOME/.local/share/wt}"
            if [[ -d "$wt_dir/templates" ]]; then
                templates=$(ls "$wt_dir/templates" 2>/dev/null | sed 's/\.yaml$//')
            fi
            COMPREPLY=($(compgen -W "$templates default" -- "$cur"))
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
                # Complete with existing worktree branch names
                local worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                COMPREPLY=($(compgen -W "$worktrees" -- "$cur"))
            fi
            ;;
        stop|down)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-s --service -a --all -p --project -h --help" -- "$cur"))
            else
                local worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                COMPREPLY=($(compgen -W "$worktrees" -- "$cur"))
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
                local worktrees=$(git worktree list --porcelain 2>/dev/null | grep "^branch" | sed 's|branch refs/heads/||')
                COMPREPLY=($(compgen -W "$worktrees" -- "$cur"))
            fi
            ;;
        list|ls)
            COMPREPLY=($(compgen -W "-p --project -s --status --json -h --help" -- "$cur"))
            ;;
        init)
            COMPREPLY=($(compgen -W "-t --template -n --name -f --force -h --help" -- "$cur"))
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
