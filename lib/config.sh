#!/usr/bin/env bash
# Central configuration. Sourced by auto-code.sh. Load order:
#   1. built-in defaults
#   2. ~/.config/autocoding/config.env (if present)
#   3. CLI flags (parsed later in auto-code.sh)

set -o pipefail

: "${AUTOCODING_HOME:=$HOME/.config/autocoding}"
: "${AUTOCODING_STATE_DIR:=$AUTOCODING_HOME/state}"
: "${AUTOCODING_LOG_DIR:=$AUTOCODING_HOME/logs}"
: "${AUTOCODING_REPOS_CTX_DIR:=$AUTOCODING_HOME/repos}"
: "${AUTOCODING_CONFIG_FILE:=$AUTOCODING_HOME/config.env}"

# Built-in defaults
: "${REPOS_DIR:=$HOME/Projekte}"
: "${BASE_BRANCH:=main}"
: "${MAX_REVIEWS:=3}"
: "${WATCH_INTERVAL:=15m}"
: "${CLAUDE_MODEL:=opus}"
: "${CLAUDE_RETRIES:=3}"
: "${CLAUDE_BACKOFF_BASE:=5}"
: "${CLAUDE_MAX_BUDGET_USD:=}"

# Bot identity (optional). If AUTOCODING_GH_USER is set, all gh/git calls the
# script makes are done as that GitHub user via `gh auth token --user <user>`.
# Your normal shell keeps whatever gh account is active — only the script
# switches, per-invocation.
: "${AUTOCODING_GH_USER:=}"
: "${AUTOCODING_GIT_NAME:=}"
: "${AUTOCODING_GIT_EMAIL:=}"

# Load user overrides
if [[ -r "$AUTOCODING_CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$AUTOCODING_CONFIG_FILE"
fi

# Ensure state/log/repo-ctx dirs exist (idempotent)
mkdir -p "$AUTOCODING_STATE_DIR" "$AUTOCODING_LOG_DIR" "$AUTOCODING_REPOS_CTX_DIR"

# Parse a duration like "30s", "5m", "1h" into seconds. Prints seconds on stdout.
parse_duration() {
    local d=$1
    if [[ $d =~ ^([0-9]+)s$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ $d =~ ^([0-9]+)m$ ]]; then
        echo $(( BASH_REMATCH[1] * 60 ))
    elif [[ $d =~ ^([0-9]+)h$ ]]; then
        echo $(( BASH_REMATCH[1] * 3600 ))
    elif [[ $d =~ ^[0-9]+$ ]]; then
        echo "$d"
    else
        echo "ERR" >&2
        return 1
    fi
}

# Extract owner and name from "owner/repo" input. Sets globals REPO_OWNER, REPO_NAME, REPO_SLUG.
parse_repo_spec() {
    local spec=$1
    if [[ ! $spec =~ ^([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)$ ]]; then
        echo "Invalid repo spec: $spec (expected owner/repo)" >&2
        return 1
    fi
    REPO_OWNER=${BASH_REMATCH[1]}
    REPO_NAME=${BASH_REMATCH[2]}
    REPO_SLUG="${REPO_OWNER}__${REPO_NAME}"
    REPO_PATH="$REPOS_DIR/$REPO_NAME"
    return 0
}
