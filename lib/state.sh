#!/usr/bin/env bash
# Persistent state per repo. File: $AUTOCODING_STATE_DIR/<slug>.json
#
# Schema (fields are added lazily; old files remain readable):
# {
#   "processed": { "<issue>": {
#       "pr_url": "...", "at": "<iso>",
#       "usage": { "tokens":N, "input":N, "output":N, "cache_create":N, "cache_read":N,
#                  "sessions": { "<label>": { same shape without .sessions } } }
#   }},
#   "errors":    { "<issue>": {"message": "...", "at": "<iso>"} },
#   "totals":    { "tokens":N, "input":N, "output":N, "cache_create":N, "cache_read":N,
#                  "issues_processed":N, "sessions_count":N }
# }
#
# Global lifetime file: $AUTOCODING_HOME/usage-global.json (mirrors the totals
# schema plus a by_repo map).

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
        '.processed[$n] = ((.processed[$n] // {}) + {pr_url:$u, at:$t}) | del(.errors[$n])' \
        "$file" >"$tmp" && mv "$tmp" "$file"
}

# --- Per-repo settings (currently: init, context_update) ---

# state_get_setting <slug> <key>
# Prints "1" or "0" if set, otherwise nothing.
state_get_setting() {
    local slug=$1 key=$2 file
    file=$(_state_file "$slug")
    [[ -f $file ]] || return 0
    jq -r --arg k "$key" '
        .settings[$k]
        | if . == null then empty
          elif type == "boolean" then (if . then "1" else "0" end)
          else . | tostring end
    ' "$file"
}

# state_set_setting <slug> <key> <0|1>
state_set_setting() {
    local slug=$1 key=$2 val=$3
    state_ensure "$slug"
    local file bool tmp
    file=$(_state_file "$slug")
    if [[ $val == 1 ]]; then bool=true; else bool=false; fi
    tmp=$(mktemp)
    jq --arg k "$key" --argjson v "$bool" \
        '.settings //= {} | .settings[$k] = $v' "$file" >"$tmp" && mv "$tmp" "$file"
}

# state_reset_settings <slug> — wipes .settings
state_reset_settings() {
    local slug=$1 file tmp
    file=$(_state_file "$slug")
    [[ -f $file ]] || return 0
    tmp=$(mktemp)
    jq 'del(.settings)' "$file" >"$tmp" && mv "$tmp" "$file"
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

# --- Usage tracking ---

_global_usage_file() {
    echo "$AUTOCODING_HOME/usage-global.json"
}

_state_ensure_global() {
    local f; f=$(_global_usage_file)
    mkdir -p "$AUTOCODING_HOME"
    if [[ ! -f $f ]]; then
        echo '{"tokens":0,"input":0,"output":0,"cache_create":0,"cache_read":0,"sessions_count":0,"issues_processed":0,"by_repo":{}}' >"$f"
    fi
}

# Records/overwrites tokens for one session under one issue. If the issue was
# never seen before, its processed entry is created shell-only (pr_url empty)
# so the usage tree has a home. This entry does NOT count as "processed" for
# state_is_processed until state_mark_processed is called.
state_record_session() {
    local slug=$1 num=$2 label=$3 tok=$4 in=$5 out=$6 cc=$7 cr=$8
    local file; file=$(_state_file "$slug")
    state_ensure "$slug"
    local tmp; tmp=$(mktemp)
    jq --arg n "$num" --arg l "$label" \
       --argjson t "$tok" --argjson i "$in" --argjson o "$out" \
       --argjson cc "$cc" --argjson cr "$cr" '
        .processed[$n] //= {pr_url:"", at:""} |
        .processed[$n].usage //= {tokens:0,input:0,output:0,cache_create:0,cache_read:0,sessions:{}} |
        .processed[$n].usage.sessions[$l] = {tokens:$t,input:$i,output:$o,cache_create:$cc,cache_read:$cr}
       ' "$file" >"$tmp" && mv "$tmp" "$file"
}

# Recomputes issue-level totals from its sessions, then recomputes repo .totals
# from all issues, then propagates the delta into the global lifetime file.
state_finalize_usage() {
    local slug=$1 num=$2
    local file; file=$(_state_file "$slug")
    state_ensure "$slug"

    # 1. Sum sessions into issue-level totals
    local tmp; tmp=$(mktemp)
    jq --arg n "$num" '
        .processed[$n].usage //= {tokens:0,input:0,output:0,cache_create:0,cache_read:0,sessions:{}} |
        (.processed[$n].usage.sessions // {}) as $ss |
        .processed[$n].usage.tokens       = ([$ss[].tokens // 0]       | add // 0) |
        .processed[$n].usage.input        = ([$ss[].input // 0]        | add // 0) |
        .processed[$n].usage.output       = ([$ss[].output // 0]       | add // 0) |
        .processed[$n].usage.cache_create = ([$ss[].cache_create // 0] | add // 0) |
        .processed[$n].usage.cache_read   = ([$ss[].cache_read // 0]   | add // 0)
    ' "$file" >"$tmp" && mv "$tmp" "$file"

    # 2. Recompute repo totals; capture old vs new for delta
    local old_json new_json
    old_json=$(jq -c '.totals // {tokens:0,input:0,output:0,cache_create:0,cache_read:0,issues_processed:0,sessions_count:0}' "$file")

    tmp=$(mktemp)
    jq '
        (.processed // {}) as $p |
        [$p[] | select(.pr_url != "")] as $done |
        .totals = {
            tokens:       ([$p[].usage.tokens       // 0] | add // 0),
            input:        ([$p[].usage.input        // 0] | add // 0),
            output:       ([$p[].usage.output       // 0] | add // 0),
            cache_create: ([$p[].usage.cache_create // 0] | add // 0),
            cache_read:   ([$p[].usage.cache_read   // 0] | add // 0),
            issues_processed: ($done | length),
            sessions_count: ([$p[].usage.sessions // {} | length] | add // 0)
        }
    ' "$file" >"$tmp" && mv "$tmp" "$file"
    new_json=$(jq -c '.totals' "$file")

    # 3. Propagate the delta to global (and set by_repo[slug] snapshot).
    state_add_to_global "$slug" "$old_json" "$new_json"
}

# Applies (new - old) to global top-level counters and snapshots the current
# repo totals into .by_repo[$slug].
state_add_to_global() {
    local slug=$1 old_json=$2 new_json=$3
    _state_ensure_global
    local gf; gf=$(_global_usage_file)
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local tmp; tmp=$(mktemp)
    jq --arg s "$slug" --arg t "$ts" \
       --argjson old "$old_json" --argjson new "$new_json" '
        def d(k): ($new[k] // 0) - ($old[k] // 0);
        .tokens          += d("tokens") |
        .input           += d("input") |
        .output          += d("output") |
        .cache_create    += d("cache_create") |
        .cache_read      += d("cache_read") |
        .sessions_count  += d("sessions_count") |
        .issues_processed += d("issues_processed") |
        .by_repo[$s] = ($new + {last_at:$t})
    ' "$gf" >"$tmp" && mv "$tmp" "$gf"
}
