#!/usr/bin/env bash
# CLAUDE.md init/update. Location depends on SETTING_STEALTH:
#   - stealth OFF: $REPO_PATH/CLAUDE.md, committed to $BASE_BRANCH (default)
#   - stealth ON:  $AUTOCODING_REPOS_CTX_DIR/$REPO_SLUG/CLAUDE.md, never committed.
#     If a hand-curated CLAUDE.md already exists in the repo it is preferred
#     as read-only context and NOT touched.

# Returns the path to the CLAUDE.md the script should treat as authoritative
# for this run, or empty if none exists yet and none should be created.
_claude_md_path() {
    if (( ${SETTING_STEALTH:-0} == 1 )); then
        # Prefer an existing in-repo CLAUDE.md as read-only context
        if [[ -f "$REPO_PATH/CLAUDE.md" ]]; then
            echo "$REPO_PATH/CLAUDE.md"
            return 0
        fi
        # Otherwise external
        echo "$AUTOCODING_REPOS_CTX_DIR/$REPO_SLUG/CLAUDE.md"
    else
        echo "$REPO_PATH/CLAUDE.md"
    fi
}

ensure_claude_md() {
    local claude_md; claude_md=$(_claude_md_path)
    if [[ -f $claude_md ]]; then
        log_info "CLAUDE.md present at $claude_md"
        return 0
    fi
    if (( ${SETTING_INIT:-1} == 0 )); then
        log_info "CLAUDE.md missing but init disabled — running without project context."
        return 0
    fi

    log_info "CLAUDE.md missing — running project-init session (target: $claude_md)"
    mkdir -p "$(dirname "$claude_md")"
    # Override the path Claude should write to (prompt uses ${REPO_PATH}/CLAUDE.md via envsubst;
    # we override that expectation by exporting a specific target).
    export CLAUDE_MD_PATH="$claude_md"

    local out_dir="$AUTOCODING_LOG_DIR/$REPO_SLUG/issue-${ISSUE_NUM}"
    if ! claude_run "$PROMPTS_DIR/project-init.md" "$out_dir" "init"; then
        LAST_ERROR="project-init session failed"
        return 1
    fi
    _record_last_session "init"
    if [[ ! -f $claude_md ]]; then
        LAST_ERROR="project-init did not create $claude_md"
        return 1
    fi

    if (( ${SETTING_STEALTH:-0} == 1 )); then
        log_ok "CLAUDE.md written to external context dir (not committed)."
        return 0
    fi

    (
        cd "$REPO_PATH" || exit 1
        git checkout "$BASE_BRANCH"
        git add CLAUDE.md
        git_commit "Initialize CLAUDE.md project context" >/dev/null
        if [[ ${BOT_ACTIVE:-0} == 1 ]]; then
            git_push_bot "$BASE_BRANCH"
        else
            git push origin "$BASE_BRANCH"
        fi
    ) || { LAST_ERROR="failed to commit CLAUDE.md"; return 1; }
    log_ok "CLAUDE.md initialized and pushed to $BASE_BRANCH."
}

update_claude_md() {
    if (( ${SETTING_CONTEXT_UPDATE:-1} == 0 )); then
        log_info "context-update skipped (disabled for this repo)."
        return 0
    fi
    local claude_md; claude_md=$(_claude_md_path)
    export CLAUDE_MD_PATH="$claude_md"

    local out_dir="$AUTOCODING_LOG_DIR/$REPO_SLUG/issue-${ISSUE_NUM}"
    log_info "Running context-update session (post-PR)."
    if ! claude_run "$PROMPTS_DIR/context-update.md" "$out_dir" "context-update"; then
        log_warn "context-update session failed — skipping."
        return 0
    fi
    _record_last_session "context-update"
    local last_line
    last_line=$(printf '%s\n' "$CLAUDE_LAST_RESULT" | tail -n1 | tr -d '[:space:]')
    if [[ $last_line != STATUS:UPDATED ]]; then
        log_info "No CLAUDE.md update needed."
        return 0
    fi

    if (( ${SETTING_STEALTH:-0} == 1 )); then
        log_ok "CLAUDE.md updated in external context dir (not committed)."
        return 0
    fi

    local tmp; tmp=$(mktemp)
    cp "$REPO_PATH/CLAUDE.md" "$tmp"
    (
        cd "$REPO_PATH" || exit 1
        git checkout -- CLAUDE.md 2>/dev/null || true
        git checkout "$BASE_BRANCH"
        git pull --ff-only origin "$BASE_BRANCH"
        cp "$tmp" CLAUDE.md
        if git diff --quiet -- CLAUDE.md; then
            echo "No actual diff on CLAUDE.md after rebase — skipping commit." >&2
            exit 0
        fi
        git add CLAUDE.md
        git_commit "Update CLAUDE.md context after issue #${ISSUE_NUM}" >/dev/null
        if [[ ${BOT_ACTIVE:-0} == 1 ]]; then
            git_push_bot "$BASE_BRANCH"
        else
            git push origin "$BASE_BRANCH"
        fi
    ) || log_warn "context-update commit failed — continuing."
    rm -f "$tmp"
}
