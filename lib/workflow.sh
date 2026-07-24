#!/usr/bin/env bash
# Kern-Workflow für ein Issue: preflight → plan → code → review×N → PR → context-update.
#
# Exports on success: LAST_PR_URL
# Exports on failure: LAST_ERROR (with human-readable reason)

LAST_PR_URL=""
LAST_ERROR=""

# Helper: record whatever tokens the last claude_run produced.
# Used after every successful claude_run inside process_issue and the context helpers.
_record_last_session() {
    local label=$1
    state_record_session "$REPO_SLUG" "$ISSUE_NUM" "$label" \
        "${CLAUDE_LAST_TOKENS:-0}" "${CLAUDE_LAST_TOK_INPUT:-0}" "${CLAUDE_LAST_TOK_OUTPUT:-0}" \
        "${CLAUDE_LAST_TOK_CACHE_CREATE:-0}" "${CLAUDE_LAST_TOK_CACHE_READ:-0}"
}

# process_issue N — orchestriert den kompletten Zyklus für Issue N.
process_issue() {
    local n=$1
    LAST_PR_URL=""
    LAST_ERROR=""

    set_log_file_for_issue "$n"
    log_info "Processing issue #$n on ${REPO_OWNER}/${REPO_NAME}"

    if ! gh_issue_get "$n"; then
        LAST_ERROR="fetching issue #$n failed"
        return 1
    fi
    log_info "Issue title: $ISSUE_TITLE"

    # Auto-resume ONLY when the currently checked-out branch matches this
    # issue's auto/issue-N-* pattern. Old branches that just weren't cleaned
    # up don't count — they'd cause us to jump into finished work.
    local RESUME_MODE=0
    local active_branch=""
    if [[ -d "$REPO_PATH/.git" ]]; then
        active_branch=$(cd "$REPO_PATH" && git symbolic-ref --short HEAD 2>/dev/null)
    fi
    if [[ $active_branch =~ ^auto/issue-${n}- ]]; then
        WORK_BRANCH=$active_branch
        RESUME_MODE=1
        log_info "Currently on $WORK_BRANCH — auto-resuming (skipping init/plan/code)."
    else
        local slug; slug=$(slugify "$ISSUE_TITLE")
        WORK_BRANCH="auto/issue-${n}-${slug}"
    fi
    export WORK_BRANCH

    # Session output dir (rendered prompts + session json, kept outside repo)
    local sess_dir="$AUTOCODING_LOG_DIR/$REPO_SLUG/issue-${n}"
    mkdir -p "$sess_dir"

    # Paths for artefacts that live IN the repo (versioned with the branch)
    local ctx_dir_rel=".claude/context"
    local ctx_dir="$REPO_PATH/$ctx_dir_rel"
    PLAN_MD_PATH="$ctx_dir/issue-${n}-plan.md"
    SUMMARY_MD_PATH="$ctx_dir/issue-${n}-summary.md"
    export PLAN_MD_PATH SUMMARY_MD_PATH

    if (( RESUME_MODE == 0 )); then
        # --- Fresh path: sync repo, ensure CLAUDE.md, new branch, plan+code ---
        if ! gh_clone_if_missing; then
            LAST_ERROR="clone/sync of ${REPO_OWNER}/${REPO_NAME} failed"
            return 1
        fi
        if ! ensure_claude_md; then
            [[ -z $LAST_ERROR ]] && LAST_ERROR="CLAUDE.md init failed"
            return 1
        fi
        mkdir -p "$ctx_dir"

        log_info "Work branch: $WORK_BRANCH"
        (
            cd "$REPO_PATH" || exit 1
            git checkout "$BASE_BRANCH" >/dev/null
            git branch -D "$WORK_BRANCH" 2>/dev/null || true
            git checkout -b "$WORK_BRANCH" >/dev/null
        ) || { LAST_ERROR="branch checkout failed"; return 1; }

        # Plan
        if ! claude_run "$PROMPTS_DIR/plan.md" "$sess_dir" "plan"; then
            LAST_ERROR="plan session failed"
            return 1
        fi
        _record_last_session "plan"
        if [[ ! -s $PLAN_MD_PATH ]] && [[ ${DRY_RUN:-0} != 1 ]]; then
            LAST_ERROR="plan session did not create $PLAN_MD_PATH"
            return 1
        fi

        # Code
        if ! claude_run "$PROMPTS_DIR/code.md" "$sess_dir" "code"; then
            LAST_ERROR="code session failed"
            return 1
        fi
        _record_last_session "code"
        if [[ ${DRY_RUN:-0} == 1 ]]; then
            log_warn "DRY-RUN: skipping commit / review / PR steps."
            LAST_PR_URL="[dry-run]"
            return 0
        fi

        local changed_files
        changed_files=$(cd "$REPO_PATH" && git status --porcelain | wc -l | tr -d ' ')
        if [[ $changed_files == 0 ]]; then
            LAST_ERROR="code session produced no changes"
            return 1
        fi
        (
            cd "$REPO_PATH" || exit 1
            git add -A
            git_commit "Implement issue #${n}: ${ISSUE_TITLE}" >/dev/null
        ) || { LAST_ERROR="initial commit failed"; return 1; }
    else
        # --- Resume path: checkout existing branch, commit outstanding, proceed ---
        (
            cd "$REPO_PATH" || exit 1
            # Tolerate dirty: git checkout keeps modified files that don't conflict.
            git checkout "$WORK_BRANCH" >/dev/null 2>&1
        ) || { LAST_ERROR="resume checkout failed"; return 1; }
        mkdir -p "$ctx_dir"

        if [[ ! -f $PLAN_MD_PATH ]]; then
            log_warn "Resume: $PLAN_MD_PATH missing — review pass will have less context."
        fi

        local dirty
        dirty=$(cd "$REPO_PATH" && git status --porcelain | wc -l | tr -d ' ')
        if (( dirty > 0 )); then
            log_info "Resume: committing $dirty outstanding path(s) from previous run."
            (
                cd "$REPO_PATH" || exit 1
                git add -A
                git_commit "Resume: implement issue #${n}: ${ISSUE_TITLE}" >/dev/null
            ) || { LAST_ERROR="resume commit failed"; return 1; }
        else
            local commits_ahead
            commits_ahead=$(cd "$REPO_PATH" && git rev-list --count "${BASE_BRANCH}..HEAD" 2>/dev/null || echo 0)
            if [[ $commits_ahead == 0 ]]; then
                LAST_ERROR="resume: work branch has no commits and nothing to commit"
                return 1
            fi
            log_info "Resume: nothing outstanding; $commits_ahead existing commit(s) ahead of $BASE_BRANCH."
        fi
    fi

    # ---- Review loop ----
    local i status_line last_status="NEEDS_FIX"
    for (( i=1; i<=MAX_REVIEWS; i++ )); do
        REVIEW_MD_PATH="$ctx_dir/issue-${n}-review-${i}.md"
        export REVIEW_MD_PATH
        log_info "Review pass $i/$MAX_REVIEWS"
        if ! claude_run "$PROMPTS_DIR/review.md" "$sess_dir" "review-${i}"; then
            log_warn "Review session $i failed — treating as NEEDS_FIX and continuing."
            last_status="NEEDS_FIX"
            continue
        fi
        _record_last_session "review-${i}"
        status_line=$(printf '%s\n' "$CLAUDE_LAST_RESULT" | tail -n1 | tr -d '[:space:]')
        case $status_line in
            STATUS:OK)        last_status="OK"; log_ok "Review $i: OK"; break ;;
            STATUS:NEEDS_FIX) last_status="NEEDS_FIX"; log_info "Review $i: NEEDS_FIX" ;;
            *)                last_status="NEEDS_FIX"; log_warn "Review $i: unparseable status line ('$status_line') — treating as NEEDS_FIX" ;;
        esac

        # Commit whatever the review session may have written (review MD)
        (cd "$REPO_PATH" && git add -A && git diff --cached --quiet || git_commit "Add review $i for issue #${n}" >/dev/null) || true

        if [[ $last_status == NEEDS_FIX ]] && (( i < MAX_REVIEWS )); then
            if ! claude_run "$PROMPTS_DIR/fix.md" "$sess_dir" "fix-${i}"; then
                log_warn "Fix session $i failed — moving on."
                continue
            fi
            _record_last_session "fix-${i}"
            (
                cd "$REPO_PATH" || exit 1
                if ! git diff --quiet || ! git diff --cached --quiet; then
                    git add -A
                    git_commit "Review fix ${i} for issue #${n}" >/dev/null
                else
                    echo "fix session $i produced no diff" >&2
                fi
            ) || log_warn "Fix commit $i failed."
        fi
    done

    # ---- Summary + PR body ----
    _build_pr_body "$n" "$last_status" "$SUMMARY_MD_PATH"
    (cd "$REPO_PATH" && git add -A && (git diff --cached --quiet || git_commit "Add PR summary for issue #${n}" >/dev/null)) || true

    if (( ${LOCAL_MODE:-0} == 1 )); then
        LAST_PR_URL="[local:${WORK_BRANCH}]"
        log_ok "Local mode: stopping after commits on branch $WORK_BRANCH"
        state_finalize_usage "$REPO_SLUG" "$n"
        usage_log_issue "$REPO_SLUG" "$n"
        return 0
    fi

    # ---- Push + PR ----
    if ! (cd "$REPO_PATH" && git_push_bot "$WORK_BRANCH" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"); then
        LAST_ERROR="git push failed"
        return 1
    fi

    local pr_title
    if [[ $last_status == OK ]]; then
        pr_title="Issue #${n}: ${ISSUE_TITLE}"
    else
        pr_title="[needs review] Issue #${n}: ${ISSUE_TITLE}"
    fi
    if ! gh_pr_create "$pr_title" "$SUMMARY_MD_PATH"; then
        LAST_ERROR="PR creation failed"
        return 1
    fi
    log_ok "PR opened: $LAST_PR_URL"

    # ---- Post-PR: update CLAUDE.md if warranted ----
    update_claude_md || true

    # ---- Finalize usage & log summary ----
    state_finalize_usage "$REPO_SLUG" "$n"
    usage_log_issue "$REPO_SLUG" "$n"

    return 0
}

# _build_pr_body ISSUE_NUM LAST_STATUS OUT_PATH
_build_pr_body() {
    local n=$1 status=$2 out=$3
    {
        echo "Closes #${n}"
        echo
        echo "Automated via auto-code."
        echo
        if [[ $status != OK ]]; then
            echo "> ⚠️ Review status after ${MAX_REVIEWS} review pass(es): **${status}**. Please inspect carefully before merging."
            echo
        fi
        echo "## Plan"
        if [[ -f $PLAN_MD_PATH ]]; then
            sed -e 's/^## /### /' "$PLAN_MD_PATH"
        else
            echo "(plan file missing — see logs)"
        fi
        echo
        echo "## Review passes"
        local i
        for (( i=1; i<=MAX_REVIEWS; i++ )); do
            local rf="$(dirname "$PLAN_MD_PATH")/issue-${n}-review-${i}.md"
            [[ -f $rf ]] || continue
            echo "### Pass ${i}"
            sed -e 's/^## /#### /' "$rf"
            echo
        done
    } >"$out"
}
