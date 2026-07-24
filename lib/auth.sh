#!/usr/bin/env bash
# Bot-identity layer. Optional: if AUTOCODING_GH_USER is set, every gh/git
# call the script makes runs as that user, without touching your interactive
# shell's active gh account.
#
# Mechanism:
#   - GH_TOKEN env is set to `gh auth token --user "$AUTOCODING_GH_USER"`.
#     gh CLI picks GH_TOKEN over cached credentials automatically.
#   - Git commits go through git_commit() so we can inject --author + committer
#     config for the bot.
#   - Git pushes go through git_push_bot() which builds an https+token URL so
#     the bot's token is used regardless of the origin URL (ssh or https).
#
# If AUTOCODING_GH_USER is set but no token can be found, the script exits
# hard — no fallback to your default account.

bot_auth_setup() {
    [[ -z ${AUTOCODING_GH_USER:-} ]] && return 0

    if ! command -v gh >/dev/null 2>&1; then
        log_error "AUTOCODING_GH_USER set but 'gh' not found on PATH."
        exit 1
    fi

    local tok
    tok=$(gh auth token --user "$AUTOCODING_GH_USER" 2>/dev/null)
    if [[ -z $tok ]]; then
        log_error "AUTOCODING_GH_USER=$AUTOCODING_GH_USER but no gh token found."
        log_error "Run:   gh auth login   and log in as $AUTOCODING_GH_USER (adds a second account)."
        exit 1
    fi
    export GH_TOKEN=$tok
    # gh's own convention: unset GITHUB_TOKEN so it doesn't override GH_TOKEN
    unset GITHUB_TOKEN

    # Sanity: what does github think this token belongs to?
    local who
    who=$(gh api user --jq '.login' 2>/dev/null)
    if [[ $who != "$AUTOCODING_GH_USER" ]]; then
        log_error "Token check failed: token belongs to '$who' but AUTOCODING_GH_USER=$AUTOCODING_GH_USER."
        exit 1
    fi

    log_info "Bot identity active: all gh/git operations run as '$AUTOCODING_GH_USER'."
    BOT_ACTIVE=1
    export BOT_ACTIVE
}

# git_commit "<message>" — commit with bot's author/committer if configured,
# otherwise plain `git commit`. Must be run inside the target repo (caller cds).
git_commit() {
    local msg=$1
    if [[ ${BOT_ACTIVE:-0} == 1 ]] && [[ -n ${AUTOCODING_GIT_NAME:-} ]] && [[ -n ${AUTOCODING_GIT_EMAIL:-} ]]; then
        GIT_AUTHOR_NAME="$AUTOCODING_GIT_NAME" GIT_AUTHOR_EMAIL="$AUTOCODING_GIT_EMAIL" \
        GIT_COMMITTER_NAME="$AUTOCODING_GIT_NAME" GIT_COMMITTER_EMAIL="$AUTOCODING_GIT_EMAIL" \
            git commit -m "$msg"
    else
        git commit -m "$msg"
    fi
}

# git_push_bot <branch> — push the branch to origin. If BOT_ACTIVE, force
# an https+token URL so the bot's identity is used regardless of the origin
# protocol (ssh/https). Must be run inside the target repo (caller cds).
git_push_bot() {
    local branch=$1
    if [[ ${BOT_ACTIVE:-0} == 1 ]]; then
        [[ -z ${GH_TOKEN:-} ]] && { echo "BOT_ACTIVE but GH_TOKEN empty" >&2; return 1; }
        local url="https://x-access-token:${GH_TOKEN}@github.com/${REPO_OWNER}/${REPO_NAME}.git"
        git push --set-upstream "$url" "HEAD:refs/heads/$branch"
    else
        git push -u origin "$branch"
    fi
}
