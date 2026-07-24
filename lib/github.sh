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
        jq '.processed | keys | map(tonumber)' "$file" 2>/dev/null || echo '[]'
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
# Requires: REPO_OWNER, REPO_NAME, REPO_PATH, BASE_BRANCH.
gh_clone_if_missing() {
    if [[ ! -d $REPO_PATH/.git ]]; then
        log_info "Cloning ${REPO_OWNER}/${REPO_NAME} into $REPO_PATH"
        if ! gh repo clone "${REPO_OWNER}/${REPO_NAME}" "$REPO_PATH" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
            log_error "gh repo clone failed"
            return 1
        fi
    else
        log_info "Repo present at $REPO_PATH — fetching and syncing $BASE_BRANCH"
        (
            cd "$REPO_PATH" || exit 1
            git fetch origin --prune
            # Refuse if working tree is dirty (safety)
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
gh_pr_create() {
    local title=$1 body_file=$2 out
    out=$(cd "$REPO_PATH" && gh pr create --base "$BASE_BRANCH" --title "$title" --body-file "$body_file" 2>&1) || {
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
