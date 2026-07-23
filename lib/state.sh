#!/usr/bin/env bash
# Persistent state per repo. File: $AUTOCODING_STATE_DIR/<slug>.json
#
# Schema:
# {
#   "processed": { "<issue>": {"pr_url": "...", "at": "<iso>"} },
#   "errors":    { "<issue>": {"message": "...", "at": "<iso>"} }
# }

_state_file() {
    echo "$AUTOCODING_STATE_DIR/$1.json"
}

state_ensure() {
    local slug=$1 file
    file=$(_state_file "$slug")
    if [[ ! -f $file ]]; then
        echo '{"processed":{},"errors":{}}' >"$file"
    fi
}

state_is_processed() {
    local slug=$1 num=$2 file
    file=$(_state_file "$slug")
    [[ -f $file ]] || return 1
    jq -e --arg n "$num" '.processed[$n] // empty' "$file" >/dev/null 2>&1
}

state_mark_processed() {
    local slug=$1 num=$2 pr_url=${3:-} file ts
    file=$(_state_file "$slug")
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local tmp; tmp=$(mktemp)
    jq --arg n "$num" --arg u "$pr_url" --arg t "$ts" \
        '.processed[$n] = {pr_url:$u, at:$t} | del(.errors[$n])' \
        "$file" >"$tmp" && mv "$tmp" "$file"
}

state_mark_error() {
    local slug=$1 num=$2 msg=$3 file ts
    file=$(_state_file "$slug")
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local tmp; tmp=$(mktemp)
    jq --arg n "$num" --arg m "$msg" --arg t "$ts" \
        '.errors[$n] = {message:$m, at:$t}' \
        "$file" >"$tmp" && mv "$tmp" "$file"
}
