#!/usr/bin/env bash
# Claude Code wrapper. Renders a prompt template with envsubst, invokes
# `claude -p` headless with retry+backoff, and returns the .result string.
#
# Usage:
#   claude_run <prompt_template> <session_out_dir> <label>
#     - prompt_template: absolute path to prompts/xxx.md
#     - session_out_dir: directory where rendered prompt and json output go
#     - label:           short tag (used for filenames), e.g. "plan", "review-1"
#
# Reads env: REPO_PATH, CLAUDE_MODEL, CLAUDE_RETRIES, CLAUDE_BACKOFF_BASE,
#            CLAUDE_MAX_BUDGET_USD, DRY_RUN, VERBOSE, LOG_FILE, and whatever
#            variables the template references (ISSUE_NUM, ISSUE_TITLE, ...).
#
# Sets CLAUDE_LAST_RESULT (string). Returns non-zero on failure after retries.

claude_run() {
    local template=$1 out_dir=$2 label=$3
    local rendered="$out_dir/prompt-${label}.md"
    local sess_out="$out_dir/session-${label}.json"

    mkdir -p "$out_dir"
    envsubst <"$template" >"$rendered"
    log_info "Rendered prompt → $rendered"

    if [[ ${DRY_RUN:-0} == 1 ]]; then
        log_warn "DRY-RUN: skipping claude call for '$label'"
        echo "--- $label prompt ---"
        cat "$rendered"
        echo "--- end prompt ---"
        CLAUDE_LAST_RESULT="[DRY-RUN result for $label]"
        export CLAUDE_LAST_RESULT
        _claude_reset_usage
        return 0
    fi

    local -a claude_cmd=(
        claude -p "$(cat "$rendered")"
        --dangerously-skip-permissions
        --add-dir "$REPO_PATH"
        --model "$CLAUDE_MODEL"
    )
    if [[ -n ${CLAUDE_MAX_BUDGET_USD:-} ]]; then
        claude_cmd+=(--max-budget-usd "$CLAUDE_MAX_BUDGET_USD")
    fi

    local attempt max=$CLAUDE_RETRIES
    local backoff=$CLAUDE_BACKOFF_BASE
    for (( attempt=1; attempt<=max; attempt++ )); do
        log_info "Claude session '$label' — attempt $attempt/$max"
        if _claude_do "$sess_out" "${claude_cmd[@]}"; then
            log_ok "Claude '$label' finished."
            return 0
        fi
        log_warn "Attempt $attempt failed."
        if (( attempt < max )); then
            log_warn "Backing off ${backoff}s before retry."
            sleep "$backoff"
            backoff=$(( backoff * 3 ))
        fi
    done
    log_error "Claude '$label' failed after $max attempts."
    return 1
}

# Internal: runs one claude invocation, verbose or not, extracts result into
# CLAUDE_LAST_RESULT and usage numbers into CLAUDE_LAST_TOKENS etc.
# Returns 0 iff a non-empty result was produced.
_claude_do() {
    local sess_out=$1; shift
    local rc

    if (( VERBOSE == 1 )); then
        # Stream-json: NDJSON of events; tee to file, print text deltas live.
        (cd "$REPO_PATH" && "$@" \
                --output-format stream-json \
                --include-partial-messages \
                --verbose) \
            | tee "$sess_out" \
            | jq -r --unbuffered '
                if .type == "content_block_delta" and .delta.type == "text_delta" then .delta.text
                elif .type == "assistant" and (.message.content // [])[0].text? then .message.content[0].text
                else empty end' 2>/dev/null \
            | while IFS= read -r chunk; do printf '%s' "$chunk"; done
        rc=${PIPESTATUS[0]}
        (( VERBOSE == 1 )) && echo
        [[ $rc -ne 0 ]] && return 1
        CLAUDE_LAST_RESULT=$(jq -r 'select(.type=="result") | .result // empty' "$sess_out" 2>/dev/null | tail -1)
        _claude_extract_usage_stream "$sess_out"
    else
        if ! (cd "$REPO_PATH" && "$@" --output-format json) >"$sess_out" 2>>"${LOG_FILE:-/dev/null}"; then
            return 1
        fi
        CLAUDE_LAST_RESULT=$(jq -r '.result // empty' "$sess_out" 2>/dev/null)
        _claude_extract_usage_single "$sess_out"
    fi

    if [[ -z ${CLAUDE_LAST_RESULT:-} ]]; then
        log_error "Empty result from claude. Session dump: $sess_out"
        return 1
    fi
    export CLAUDE_LAST_RESULT
    log_info "Session tokens: input=$CLAUDE_LAST_TOK_INPUT output=$CLAUDE_LAST_TOK_OUTPUT cache_c=$CLAUDE_LAST_TOK_CACHE_CREATE cache_r=$CLAUDE_LAST_TOK_CACHE_READ (sum=$CLAUDE_LAST_TOKENS)"
    return 0
}

# Extract usage from --output-format json (single object).
_claude_extract_usage_single() {
    local f=$1
    _claude_reset_usage
    [[ -f $f ]] || return 0
    # Accept usage at .usage or nested at .result.usage — different Claude Code versions vary.
    local vals
    vals=$(jq -r '
        (.usage // .result.usage // {}) as $u |
        [
          ($u.input_tokens // 0),
          ($u.output_tokens // 0),
          ($u.cache_creation_input_tokens // 0),
          ($u.cache_read_input_tokens // 0)
        ] | @tsv
    ' "$f" 2>/dev/null) || return 0
    _claude_assign_usage "$vals"
}

# Extract usage from --output-format stream-json (NDJSON). The `result` event
# holds the final aggregated usage; some builds also emit per-message usage
# updates. We take the last `result` event's usage.
_claude_extract_usage_stream() {
    local f=$1
    _claude_reset_usage
    [[ -f $f ]] || return 0
    local vals
    vals=$(jq -r --slurp '
        map(select(.type == "result")) | last as $r |
        (($r // {}).usage // {}) as $u |
        [
          ($u.input_tokens // 0),
          ($u.output_tokens // 0),
          ($u.cache_creation_input_tokens // 0),
          ($u.cache_read_input_tokens // 0)
        ] | @tsv
    ' "$f" 2>/dev/null) || return 0
    _claude_assign_usage "$vals"
}

_claude_reset_usage() {
    CLAUDE_LAST_TOK_INPUT=0
    CLAUDE_LAST_TOK_OUTPUT=0
    CLAUDE_LAST_TOK_CACHE_CREATE=0
    CLAUDE_LAST_TOK_CACHE_READ=0
    CLAUDE_LAST_TOKENS=0
    export CLAUDE_LAST_TOK_INPUT CLAUDE_LAST_TOK_OUTPUT CLAUDE_LAST_TOK_CACHE_CREATE CLAUDE_LAST_TOK_CACHE_READ CLAUDE_LAST_TOKENS
}

# Args: tab-separated "input\toutput\tcache_create\tcache_read"
_claude_assign_usage() {
    local tsv=$1
    [[ -z $tsv ]] && return 0
    IFS=$'\t' read -r CLAUDE_LAST_TOK_INPUT CLAUDE_LAST_TOK_OUTPUT CLAUDE_LAST_TOK_CACHE_CREATE CLAUDE_LAST_TOK_CACHE_READ <<<"$tsv"
    : "${CLAUDE_LAST_TOK_INPUT:=0}"
    : "${CLAUDE_LAST_TOK_OUTPUT:=0}"
    : "${CLAUDE_LAST_TOK_CACHE_CREATE:=0}"
    : "${CLAUDE_LAST_TOK_CACHE_READ:=0}"
    CLAUDE_LAST_TOKENS=$(( CLAUDE_LAST_TOK_INPUT + CLAUDE_LAST_TOK_OUTPUT + CLAUDE_LAST_TOK_CACHE_CREATE + CLAUDE_LAST_TOK_CACHE_READ ))
    export CLAUDE_LAST_TOK_INPUT CLAUDE_LAST_TOK_OUTPUT CLAUDE_LAST_TOK_CACHE_CREATE CLAUDE_LAST_TOK_CACHE_READ CLAUDE_LAST_TOKENS
    if (( CLAUDE_LAST_TOKENS == 0 )) && [[ -z ${CLAUDE_WARNED_NO_USAGE:-} ]]; then
        log_warn "No usage numbers found in session output — token tracking will report 0."
        CLAUDE_WARNED_NO_USAGE=1
        export CLAUDE_WARNED_NO_USAGE
    fi
}
