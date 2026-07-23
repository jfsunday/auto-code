#!/usr/bin/env bash
# Usage reporting — formatting and pretty-printing on top of state.sh.

# format_tokens N -> "500", "12.3k", "3.2M"
format_tokens() {
    local n=${1:-0}
    if (( n < 1000 )); then
        echo "$n"
    elif (( n < 1000000 )); then
        awk -v n="$n" 'BEGIN{ printf "%.1fk", n/1000 }'
    else
        awk -v n="$n" 'BEGIN{ printf "%.1fM", n/1000000 }'
    fi
}

# One-line issue summary. Called at the end of process_issue.
usage_log_issue() {
    local slug=$1 num=$2 file
    file=$(_state_file "$slug")
    [[ -f $file ]] || return 0
    local total sessions
    total=$(jq -r --arg n "$num" '.processed[$n].usage.tokens // 0' "$file")
    sessions=$(jq -r --arg n "$num" '.processed[$n].usage.sessions // {} | to_entries | map("\(.key) \(.value.tokens // 0)") | join(" · ")' "$file")
    local pretty="" IFS_SAVE=$IFS
    IFS=$'\n'
    for pair in $(jq -r --arg n "$num" '.processed[$n].usage.sessions // {} | to_entries[] | "\(.key)\t\(.value.tokens // 0)"' "$file"); do
        local label=${pair%%$'\t'*}
        local tok=${pair##*$'\t'}
        pretty+="${label} $(format_tokens "$tok") · "
    done
    IFS=$IFS_SAVE
    pretty=${pretty% · }
    log_ok "Issue #${num} usage: $(format_tokens "$total") tokens ($pretty)"
}

# Cycle summary. Called after run_cycle finishes processing all selected issues.
usage_log_cycle() {
    local slug=$1 file gf
    file=$(_state_file "$slug")
    gf=$(_global_usage_file)
    [[ -f $file ]] || return 0
    local repo_total lifetime
    repo_total=$(jq -r '.totals.tokens // 0' "$file")
    if [[ -f $gf ]]; then
        lifetime=$(jq -r '.tokens // 0' "$gf")
    else
        lifetime=0
    fi
    log_info "Cycle done. Repo total: $(format_tokens "$repo_total") · Lifetime: $(format_tokens "$lifetime")"
}

# Human-readable repo report — printed by `auto-code --usage <owner/repo>`.
usage_report_repo() {
    local slug=$1 file gf
    file=$(_state_file "$slug")
    if [[ ! -f $file ]]; then
        echo "No state for $slug — nothing to report."
        return 0
    fi
    gf=$(_global_usage_file)
    local pretty_repo=${slug/__/\/}

    printf 'Repo: %s\nLocation: %s\n\n' "$pretty_repo" "$file"
    printf '%-8s %10s %10s   %s\n' "Issue" "Tokens" "Sessions" "PR"
    printf '%-8s %10s %10s   %s\n' "-----" "------" "--------" "--"

    jq -r '
        .processed // {}
        | to_entries
        | sort_by(.key | tonumber)
        | .[]
        | [.key,
           (.value.usage.tokens // 0 | tostring),
           (.value.usage.sessions // {} | length | tostring),
           (.value.pr_url // "")]
        | @tsv
    ' "$file" | while IFS=$'\t' read -r n tokens sess pr; do
        printf '#%-7s %10s %10s   %s\n' "$n" "$(format_tokens "$tokens")" "$sess" "$pr"
    done

    printf '%-8s %10s %10s\n' "-----" "------" "--------"
    local rt rs ri
    rt=$(jq -r '.totals.tokens // 0' "$file")
    rs=$(jq -r '.totals.sessions_count // 0' "$file")
    ri=$(jq -r '.totals.issues_processed // 0' "$file")
    printf '%-8s %10s %10s   (%s issues)\n' "Total" "$(format_tokens "$rt")" "$rs" "$ri"

    echo
    local lt li ls
    if [[ -f $gf ]]; then
        lt=$(jq -r '.tokens // 0' "$gf")
        li=$(jq -r '.issues_processed // 0' "$gf")
        ls=$(jq -r '.sessions_count // 0' "$gf")
        printf 'Lifetime across all repos: %s tokens, %s issues, %s sessions\n' \
            "$(format_tokens "$lt")" "$li" "$ls"
    fi
}

# Human-readable global report — printed by `auto-code --usage` (no repo arg).
usage_report_global() {
    local gf; gf=$(_global_usage_file)
    if [[ ! -f $gf ]]; then
        echo "No usage recorded yet."
        return 0
    fi

    local lt li ls
    lt=$(jq -r '.tokens // 0' "$gf")
    li=$(jq -r '.issues_processed // 0' "$gf")
    ls=$(jq -r '.sessions_count // 0' "$gf")

    printf 'Lifetime totals\n'
    printf '  Tokens:            %s\n' "$(format_tokens "$lt")"
    printf '  Issues processed:  %s\n' "$li"
    printf '  Sessions:          %s\n\n' "$ls"

    printf 'Per repo (top 20 by tokens)\n'
    printf '%-40s %10s %10s %10s   %s\n' "Repo" "Tokens" "Issues" "Sessions" "Last activity"
    printf '%-40s %10s %10s %10s   %s\n' "----" "------" "------" "--------" "-------------"
    jq -r '
        .by_repo // {}
        | to_entries
        | sort_by(-(.value.tokens // 0))
        | .[0:20]
        | .[]
        | [.key,
           (.value.tokens // 0 | tostring),
           (.value.issues_processed // 0 | tostring),
           (.value.sessions_count // 0 | tostring),
           (.value.last_at // "")]
        | @tsv
    ' "$gf" | while IFS=$'\t' read -r slug tokens issues sess last; do
        local pretty=${slug/__/\/}
        printf '%-40s %10s %10s %10s   %s\n' "$pretty" "$(format_tokens "$tokens")" "$issues" "$sess" "$last"
    done
}
