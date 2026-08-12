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

    read -rp "  Engine (claude|opencode) [${CODING_ENGINE:-claude}]: " ans
    if [[ -n $ans ]]; then
        case $ans in
            claude|opencode)
                CODING_ENGINE=$ans
                state_set_setting "$REPO_SLUG" engine "$ans"
                ;;
            *) log_warn "Ignoring invalid engine '$ans' — keeping ${CODING_ENGINE:-claude}" ;;
        esac
    fi

    read -rp "  Model               [$CLAUDE_MODEL]: " ans
    if [[ -n $ans ]]; then
        CLAUDE_MODEL=$ans
        state_set_setting "$REPO_SLUG" model "$ans"
    fi

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
    printf '    engine=%s  model=%s  max_reviews=%s  base=%s\n' "${CODING_ENGINE:-claude}" "$CLAUDE_MODEL" "$MAX_REVIEWS" "$BASE_BRANCH" >&2
    if [[ -n ${CUSTOM_BRANCH_NAME:-} ]]; then
        printf '    branch prefix=%s\n' "$CUSTOM_BRANCH_NAME" >&2
    fi
    printf '\n' >&2

    # >>> autocode-parallel: parallel + per-phase model prompts
    read -rp "  Parallel issues? (y/N) [$( ((PARALLEL_ENABLED)) && echo yes || echo no )]: " ans
    if [[ $ans =~ ^[Yy] ]]; then
        PARALLEL_ENABLED=1
        read -rp "  Max parallel [${PARALLEL_MAX:-3}]: " ans
        [[ $ans =~ ^[0-9]+$ ]] && PARALLEL_MAX=$ans
    elif [[ $ans =~ ^[Nn] ]]; then
        PARALLEL_ENABLED=0
    fi
    state_set_setting "$REPO_SLUG" parallel "$PARALLEL_ENABLED"
    state_set_setting "$REPO_SLUG" parallel_max "$PARALLEL_MAX"

    read -rp "  Configure per-phase models? (y/N): " ans
    if [[ $ans =~ ^[Yy] ]]; then
        read -rp "    plan   engine [${ENGINE_PLAN:-inherit}]: " ans;   [[ -n $ans ]] && ENGINE_PLAN=$ans
        read -rp "    plan   model  [${MODEL_PLAN:-inherit}]: " ans;    [[ -n $ans ]] && MODEL_PLAN=$ans
        read -rp "    code   engine [${ENGINE_CODE:-inherit}]: " ans;   [[ -n $ans ]] && ENGINE_CODE=$ans
        read -rp "    code   model  [${MODEL_CODE:-inherit}]: " ans;    [[ -n $ans ]] && MODEL_CODE=$ans
        read -rp "    review engine [${ENGINE_REVIEW:-inherit}]: " ans; [[ -n $ans ]] && ENGINE_REVIEW=$ans
        read -rp "    review model  [${MODEL_REVIEW:-inherit}]: " ans;  [[ -n $ans ]] && MODEL_REVIEW=$ans
        read -rp "    fix    engine [${ENGINE_FIX:-inherit}]: " ans;    [[ -n $ans ]] && ENGINE_FIX=$ans
        read -rp "    fix    model  [${MODEL_FIX:-inherit}]: " ans;     [[ -n $ans ]] && MODEL_FIX=$ans
    fi
    export PARALLEL_ENABLED PARALLEL_MAX ENGINE_PLAN MODEL_PLAN ENGINE_CODE MODEL_CODE ENGINE_REVIEW MODEL_REVIEW ENGINE_FIX MODEL_FIX
    # <<< autocode-parallel

    read -rp "  Proceed? [Y/n] " ans
    if [[ $ans =~ ^[Nn] ]]; then
        log_info "Aborted by user."
        exit 0
    fi

    export CODING_ENGINE CLAUDE_MODEL MAX_REVIEWS BASE_BRANCH CUSTOM_BRANCH_NAME
}
