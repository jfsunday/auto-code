#!/usr/bin/env bash
# Interactive Wizard — runs once at the start of a cycle when --interactive is on.
# Overrides apply to the whole run (all issues in this invocation).

# Prompts the user for the four tunable values with sensible defaults.
# Reads/mutates: CLAUDE_MODEL, MAX_REVIEWS, BASE_BRANCH, CUSTOM_BRANCH_NAME.
run_wizard() {
    if [[ ! -t 0 ]]; then
        log_warn "--interactive requested but stdin is not a TTY — skipping wizard, using defaults."
        return 0
    fi

    printf '\n' >&2
    printf '  === Wizard: %s/%s ===\n' "$REPO_OWNER" "$REPO_NAME" >&2
    printf '  Press Enter to keep the default in [brackets].\n\n' >&2

    local ans

    read -rp "  Model               [$CLAUDE_MODEL]: " ans
    [[ -n $ans ]] && CLAUDE_MODEL=$ans

    read -rp "  Max review loops    [$MAX_REVIEWS]: " ans
    if [[ -n $ans ]]; then
        if [[ $ans =~ ^[0-9]+$ ]]; then
            MAX_REVIEWS=$ans
        else
            log_warn "Not a number: '$ans' — keeping $MAX_REVIEWS"
        fi
    fi

    read -rp "  Base branch (PR into) [$BASE_BRANCH]: " ans
    [[ -n $ans ]] && BASE_BRANCH=$ans

    read -rp "  Custom branch prefix (blank = auto/issue-N-<slug>): " ans
    if [[ -n $ans ]]; then
        # Very light sanity: strip whitespace and slashes at ends
        CUSTOM_BRANCH_NAME=$(echo "$ans" | sed -E 's|^[/[:space:]]+||; s|[/[:space:]]+$||')
    fi

    printf '\n' >&2
    printf '  Effective settings for this run:\n' >&2
    printf '    model=%s  max_reviews=%s  base=%s\n' "$CLAUDE_MODEL" "$MAX_REVIEWS" "$BASE_BRANCH" >&2
    if [[ -n ${CUSTOM_BRANCH_NAME:-} ]]; then
        printf '    branch prefix=%s\n' "$CUSTOM_BRANCH_NAME" >&2
    fi
    printf '\n' >&2

    read -rp "  Proceed? [Y/n] " ans
    if [[ $ans =~ ^[Nn] ]]; then
        log_info "Aborted by user."
        exit 0
    fi

    export CLAUDE_MODEL MAX_REVIEWS BASE_BRANCH CUSTOM_BRANCH_NAME
}
