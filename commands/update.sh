#!/bin/bash
# commands/update.sh - Self-update wt to the latest version

# Update wt by fast-forwarding the git checkout it runs from. The default
# install symlinks the launcher at this checkout, so a pulled change is live
# immediately. Package-manager installs (e.g. Homebrew) are not git checkouts
# and update through their own tooling instead.
cmd_update() {
    local branch=""
    local check_only=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--branch)
                [[ -z "${2:-}" ]] && { log_error "Option $1 requires an argument"; return 1; }
                branch="$2"
                shift 2
                ;;
            -c|--check)
                check_only=1
                shift
                ;;
            -h|--help)
                show_update_help
                return 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_update_help
                return 1
                ;;
            *)
                log_error "Unexpected argument: $1"
                show_update_help
                return 1
                ;;
        esac
    done

    local src="$WT_SCRIPT_DIR"

    # rev-parse (not a `.git` dir check) so this works from a linked worktree
    # too, where `.git` is a file pointing at the real gitdir.
    if ! git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log_error "$WT_CMD is not running from a git checkout ($src)."
        echo "  Update it the way you installed it — e.g. 'brew upgrade', or re-run install.sh." >&2
        return 1
    fi

    # Resolve the branch to track: --branch flag > WT_REPO_BRANCH > current branch.
    [[ -z "$branch" ]] && branch="${WT_REPO_BRANCH:-}"
    if [[ -z "$branch" ]]; then
        branch="$(git -C "$src" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
    fi
    # A detached HEAD reports "HEAD"; there's no branch to track, so use main.
    [[ "$branch" == "HEAD" ]] && branch="main"

    # Never clobber uncommitted local changes (a fast-forward would fail anyway,
    # but bail early with a clear message).
    if ! git -C "$src" diff --quiet 2>/dev/null || ! git -C "$src" diff --cached --quiet 2>/dev/null; then
        log_error "Uncommitted changes in $src."
        echo "  Commit or stash them first, or update manually with git." >&2
        return 1
    fi

    log_info "Fetching latest changes (branch: $branch)..."
    if ! git -C "$src" fetch --quiet origin "$branch" 2>/dev/null; then
        log_error "Could not fetch from origin. Check your network and that 'origin' has branch '$branch'."
        return 1
    fi

    local before after
    before="$(git -C "$src" rev-parse HEAD 2>/dev/null || echo unknown)"
    after="$(git -C "$src" rev-parse "origin/$branch" 2>/dev/null || echo unknown)"

    if [[ "$before" == "$after" ]]; then
        log_success "$WT_CMD is already up to date."
        return 0
    fi

    local behind
    behind="$(git -C "$src" rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo "?")"

    if [[ "$check_only" -eq 1 ]]; then
        log_info "$behind new commit(s) available on origin/$branch."
        echo "  Run '$WT_CMD update' to apply." >&2
        return 0
    fi

    log_info "Updating ($behind new commit(s))..."
    if ! git -C "$src" merge --ff-only "origin/$branch" >/dev/null 2>&1; then
        log_error "Local branch has diverged from origin/$branch and can't be fast-forwarded."
        echo "  Resolve it manually: git -C '$src' status" >&2
        return 1
    fi

    log_success "Updated to the latest $branch ($behind commit(s))."

    # Code runs live from the checkout, so it's already current. Completions are
    # copied at install time on some shells, so flag when they've changed.
    if git -C "$src" diff --name-only "$before" "$after" 2>/dev/null | grep -q '^completions/'; then
        log_warn "Shell completions changed — re-run install.sh to refresh them."
    fi

    return 0
}

show_update_help() {
    cat << 'EOF' | _wt_sub
Usage: wt update [options]

Update wt to the latest version by fast-forwarding the git checkout it runs
from. Only works for git-checkout installs (the default). Package-manager
installs (e.g. Homebrew) update through their own tooling.

Options:
  -c, --check        Check for updates without applying them
  -b, --branch NAME  Track a specific branch (default: current branch, or
                     WT_REPO_BRANCH if set)
  -h, --help         Show this help message

Examples:
  wt update
  wt update --check
  wt update --branch main
EOF
}
