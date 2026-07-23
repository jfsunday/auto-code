#!/usr/bin/env bash
# CLAUDE.md init/update in the target repo.

# Ensures $REPO_PATH/CLAUDE.md exists. If missing, runs the project-init prompt,
# then commits the new file directly to $BASE_BRANCH.
# Requires: gh_issue_get already ran (ISSUE_* set).
ensure_claude_md() {
    local claude_md="$REPO_PATH/CLAUDE.md"
    if [[ -f $claude_md ]]; then
        log_info "CLAUDE.md already present."
        return 0
    fi
    if (( ${SETTING_INIT:-1} == 0 )); then
        log_info "CLAUDE.md missing but init disabled for this repo — running without project context."
        return 0
    fi

    log_info "CLAUDE.md missing — running project-init session."
    local out_dir="$AUTOCODING_LOG_DIR/$REPO_SLUG/issue-${ISSUE_NUM}"
    if ! claude_run "$PROMPTS_DIR/project-init.md" "$out_dir" "init"; then
        LAST_ERROR="project-init session failed"
        return 1
    fi
    _record_last_session "init"
    if [[ ! -f $claude_md ]]; then
        LAST_ERROR="project-init did not create CLAUDE.md"
        return 1
    fi

    (
        cd "$REPO_PATH" || exit 1
        git checkout "$BASE_BRANCH"
        git add CLAUDE.md
        git commit -m "Initialize CLAUDE.md project context" >/dev/null
        git push origin "$BASE_BRANCH"
    ) || { LAST_ERROR="failed to commit CLAUDE.md"; return 1; }
    log_ok "CLAUDE.md initialized and pushed to $BASE_BRANCH."
}

# Runs the context-update prompt after a successful PR; if Claude signals
# STATUS: UPDATED, commits and pushes the CLAUDE.md change to $BASE_BRANCH.
update_claude_md() {
    if (( ${SETTING_CONTEXT_UPDATE:-1} == 0 )); then
        log_info "context-update skipped (disabled for this repo)."
        return 0
    fi
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
        git commit -m "Update CLAUDE.md context after issue #${ISSUE_NUM}" >/dev/null
        git push origin "$BASE_BRANCH"
    ) || log_warn "context-update commit failed — continuing."
    rm -f "$tmp"
}
