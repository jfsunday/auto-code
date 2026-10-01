#!/usr/bin/env bash
# GitHub layer — thin wrappers around `gh` with strong error reporting.

_gh() { gh --repo "${REPO_OWNER}/${REPO_NAME}" "$@"; }

# Returns a JSON array of already-processed issue numbers for the current
# repo (or [] if FORCE_RETRY is on or state is missing).
_processed_ids_json() {
    if (( ${FORCE_RETRY:-0} == 1 )); then
        echo '[]'; return 0
    fi
    local file
    file=$(_state_file "$REPO_SLUG")
    if [[ -f $file ]]; then
        # Only numeric keys matter for issue-list filtering; task-<slug> keys are ignored.
        jq '.processed | keys | map(select(test("^[0-9]+$"))) | map(tonumber)' "$file" 2>/dev/null || echo '[]'
    else
        echo '[]'
    fi
}

# Returns the issue number if HEAD is currently on an auto/issue-N-* branch,
# empty otherwise. This is the ONLY signal for "hanging work" — old branches
# that were already merged and just weren't cleaned up don't count.
_active_work_issue() {
    [[ -d "$REPO_PATH/.git" ]] || return 0
    local br
    br=$(cd "$REPO_PATH" && git symbolic-ref --short HEAD 2>/dev/null)
    if [[ $br =~ ^auto/issue-([0-9]+)- ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

# Returns eligible issue numbers, one per line, in this order:
#   1. The issue whose auto/issue-N-* branch is currently checked out (if any),
#      even if it appears in state.processed — the checkout is a strong signal
#      that work is unfinished.
#   2. Remaining open issues NOT in state.processed (unless FORCE_RETRY),
#      oldest first.
_list_eligible_issues() {
    local raw ex active all_sorted
    raw=$(_gh issue list --state open --json number,createdAt --limit 500)
    ex=$(_processed_ids_json)
    active=$(_active_work_issue)
    all_sorted=$(echo "$raw" | jq -r 'sort_by(.createdAt) | .[].number')

    # 1. The active work-branch issue first (if it's still open)
    if [[ -n $active ]] && grep -qx "$active" <<<"$all_sorted"; then
        echo "$active"
    fi

    # 2. The rest, filtered by processed, excluding the one we just printed
    local n
    for n in $all_sorted; do
        [[ $n == "$active" ]] && continue
        if ! echo "$ex" | jq -e --argjson n "$n" 'index($n)' >/dev/null 2>&1; then
            echo "$n"
        fi
    done
}

# Select which issue numbers to process. Prints one issue number per line.
# Args: MODE ARG
#   oldest       -> newest 1
#   issue N      -> N
#   issues N,M   -> N\nM
#   n-oldest N   -> N oldest
#   all          -> every open issue, oldest first
select_issues() {
    local mode=$1 arg=${2:-}
    case $mode in
        issue)
            [[ -z $arg ]] && { log_error "--issue requires a number"; return 1; }
            echo "$arg"
            ;;
        issues)
            [[ -z $arg ]] && { log_error "--issues requires a comma list"; return 1; }
            tr ',' '\n' <<<"$arg" | awk 'NF'
            ;;
        oldest)
            _list_eligible_issues | head -1
            ;;
        n-oldest)
            [[ -z $arg ]] && { log_error "--n-oldest requires a count"; return 1; }
            _list_eligible_issues | head -n "$arg"
            ;;
        all)
            _list_eligible_issues
            ;;
        *)
            log_error "Unknown selection mode: $mode"; return 1 ;;
    esac
}

# Fetches an issue and sets ISSUE_NUM, ISSUE_TITLE, ISSUE_BODY, ISSUE_URL, ISSUE_LABELS.
gh_issue_get() {
    local n=$1 json
    if ! json=$(_gh issue view "$n" --json number,title,body,url,labels 2>&1); then
        log_error "gh issue view failed: $json"
        return 1
    fi
    ISSUE_NUM=$(jq -r '.number' <<<"$json")
    ISSUE_TITLE=$(jq -r '.title' <<<"$json")
    ISSUE_BODY=$(jq -r '.body // ""' <<<"$json")
    ISSUE_URL=$(jq -r '.url' <<<"$json")
    ISSUE_LABELS=$(jq -r '[.labels[].name] | join(",")' <<<"$json")
    export ISSUE_NUM ISSUE_TITLE ISSUE_BODY ISSUE_URL ISSUE_LABELS
}

# Turn a string into a git-branch-safe slug (max 40 chars).
slugify() {
    local raw=$1
    printf '%s' "$raw" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' \
        | cut -c1-40 \
        | sed -E 's/-+$//'
}

# Clone repo into REPO_PATH if missing, else fetch + reset to BASE_BRANCH.
# Pure git — no `gh` CLI dependency. Uses git_clone_url() from lib/auth.sh
# to pick the right URL (bot https+token or user SSH).
gh_clone_if_missing() {
    if [[ ! -d $REPO_PATH/.git ]]; then
        local url; url=$(git_clone_url) || return 1
        log_info "Cloning ${REPO_OWNER}/${REPO_NAME} into $REPO_PATH"
        if ! git clone "$url" "$REPO_PATH" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
            log_error "git clone failed"
            return 1
        fi
    else
        log_info "Repo present at $REPO_PATH — fetching and syncing $BASE_BRANCH"
        (
            cd "$REPO_PATH" || exit 1
            git fetch origin --prune
            if ! git diff --quiet || ! git diff --cached --quiet; then
                echo "Working tree dirty in $REPO_PATH — refusing to touch" >&2
                exit 1
            fi
            git checkout "$BASE_BRANCH" 2>/dev/null || git checkout -b "$BASE_BRANCH" "origin/$BASE_BRANCH"
            git pull --ff-only origin "$BASE_BRANCH"
        ) || return 1
    fi
}

# Create a PR from current branch. Args: TITLE BODY_FILE_ABS
# Runs inside REPO_PATH so gh picks up the current branch. Body file must be absolute.
# Sets LAST_PR_URL.
# Merge a PR immediately and pull the updated base branch locally so the next
# issue starts from an up-to-date base (prevents parallel-branch conflicts).
# Args: PR_URL [ISSUE_NUMBER]. Strategy from $AUTO_MERGE_STRATEGY.
# If ISSUE_NUMBER is passed and numeric, closes that issue after merge as a
# safety net — "Closes #N" auto-close only fires when the PR targets the
# repo's default branch, so bots merging into a non-default base can leave
# issues open.
gh_pr_merge_now() {
    local pr_url=$1 issue_num=${2:-} strategy=${AUTO_MERGE_STRATEGY:-merge} flag
    case $strategy in
        merge)  flag="--merge" ;;
        squash) flag="--squash" ;;
        rebase) flag="--rebase" ;;
        *) log_error "Unknown --auto-merge-strategy: $strategy"; return 1 ;;
    esac
    log_info "Auto-merging $pr_url with $strategy..."
    local out
    if ! out=$(gh pr merge "$pr_url" $flag --delete-branch 2>&1); then
        log_error "gh pr merge failed: $out"
        return 1
    fi
    log_ok "PR merged and remote branch deleted."
    # Pull the updated base into the local repo so the next issue branches from it.
    (
        cd "$REPO_PATH" || exit 1
        git fetch origin --prune 2>&1 | tail -3
        git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true
        git pull --ff-only origin "$BASE_BRANCH" 2>&1 | tail -3
        # Local work branch is stale now; remove it
        git branch -D "$WORK_BRANCH" 2>/dev/null || true
    ) || log_warn "Local base sync after merge had issues (non-fatal)."
    log_ok "Local $BASE_BRANCH is up-to-date."

    # Close the source issue explicitly. Idempotent: gh returns success even
    # if the issue is already closed (e.g. by GitHub's Closes-#N auto-close).
    if [[ -n $issue_num && $issue_num =~ ^[0-9]+$ ]]; then
        local close_out
        if close_out=$(_gh issue close "$issue_num" \
                        --reason completed \
                        --comment "Auto-closed after PR merge ($pr_url)." 2>&1); then
            log_ok "Issue #$issue_num closed."
        else
            # Not fatal — merge already succeeded. Common causes: already
            # closed, insufficient permissions, or issue moved/deleted.
            log_warn "Could not close issue #$issue_num: $close_out"
        fi
    fi
}

# Request a review on a PR that was not auto-merged. Args: PR_URL.
# Reviewer from $SETTING_REVIEWER: "owner" (repo owner), "<login>", or "none".
# Never fatal — the PR already exists; failures only log a warning.
# Skips org owners (orgs can't review) and the PR author (GitHub rejects
# self-review requests, e.g. when no bot identity is active).
gh_pr_request_review() {
    local pr_url=$1 who=${SETTING_REVIEWER:-none} login type me out
    if [[ -z $who || $who == none ]]; then
        log_info "Review request disabled."
        return 0
    fi
    if [[ $who == owner ]]; then
        if ! read -r login type < <(gh api "repos/${REPO_OWNER}/${REPO_NAME}" \
                --jq '.owner.login + " " + .owner.type' 2>/dev/null) || [[ -z $login ]]; then
            log_warn "Could not resolve repo owner — no review requested."
            return 0
        fi
        if [[ $type == Organization ]]; then
            log_warn "Repo owner '$login' is an org — use --reviewer <login> to request a review."
            return 0
        fi
    else
        login=${who#@}
    fi
    me=$(gh api user --jq .login 2>/dev/null)
    if [[ -n $me && ${login,,} == "${me,,}" ]]; then
        log_info "Reviewer @$login is the PR author — skipping review request."
        return 0
    fi
    if ! out=$(_gh pr edit "$pr_url" --add-reviewer "$login" 2>&1); then
        log_warn "Could not request review from @$login: $out"
        return 0
    fi
    log_ok "Review requested from @$login."
}

gh_pr_create() {
    local title=$1 body_file=$2 out
    # Pass --head explicitly. Without this, gh looks up the current branch's
    # tracking upstream — which our token push sets to the raw https URL, not
    # to `origin`. That trips gh into "you must first push the current branch".
    out=$(cd "$REPO_PATH" && gh pr create \
            --repo "${REPO_OWNER}/${REPO_NAME}" \
            --base "$BASE_BRANCH" \
            --head "$WORK_BRANCH" \
            --title "$title" \
            --body-file "$body_file" 2>&1) || {
        log_error "gh pr create failed: $out"
        return 1
    }
    LAST_PR_URL=$(grep -Eo 'https://github.com/[^ ]+/pull/[0-9]+' <<<"$out" | head -1)
    if [[ -z $LAST_PR_URL ]]; then
        log_warn "PR created but URL not parsed; raw output: $out"
        LAST_PR_URL=$out
    fi
    export LAST_PR_URL
}
