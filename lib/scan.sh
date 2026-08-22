#!/usr/bin/env bash
# Codebase scanner — analyses a repo with Claude and creates GitHub issues.
#
# Usage (via auto-code.sh subcommand):
#   auto-code scan <owner/repo> [options]
#
# Scans for bugs, security issues, code quality, missing features/tests,
# and performance problems. Optionally chains into --fix to auto-resolve.

scan_main() {
    local SCAN_PATHS=""
    local SCAN_FIX=0
    local SCAN_DRY_RUN=0
    local SCAN_MAX_FINDINGS=""
    local SCAN_MIN_PRIORITY="low"
    local SCAN_MODEL=""
    local SCAN_ENGINE=""
    local SCAN_REPO_SPEC=""
    local SCAN_CONTEXT=""

    # --- Argument parsing ---
    while (( $# )); do
        case $1 in
            --path)         SCAN_PATHS=$2; shift 2 ;;
            --fix)          SCAN_FIX=1; shift ;;
            --dry-run)      SCAN_DRY_RUN=1; shift ;;
            --max-findings) SCAN_MAX_FINDINGS=$2; shift 2 ;;
            --priority)     SCAN_MIN_PRIORITY=$2; shift 2 ;;
            --model)        SCAN_MODEL=$2; shift 2 ;;
            --engine)       SCAN_ENGINE=$2; shift 2 ;;
            --context)      SCAN_CONTEXT=$2; shift 2 ;;
            -h|--help)
                cat <<'HELPEOF'
auto-code scan <owner/repo> [options]

Scan a repository for bugs, security issues, code quality problems,
missing features, insufficient tests, and performance issues.
Creates GitHub issues for each finding.

Options:
  --path PATH,...        Only scan specific paths (default: whole repo)
  --fix                  Auto-fix created issues via auto-code
  --dry-run              Show findings without creating issues
  --max-findings N       Max number of findings (default: unlimited)
  --priority LEVEL       Minimum priority: high, medium, low (default: low)
  --model NAME           Model for the scan session
  --engine NAME          Engine for the scan session
  --context TEXT         Extra context or instructions for the scan
  -h, --help             Show this help
HELPEOF
                return 0 ;;
            -*)
                log_error "scan: unknown option: $1"; return 2 ;;
            *)
                if [[ -z $SCAN_REPO_SPEC ]]; then
                    SCAN_REPO_SPEC=$1
                else
                    log_error "scan: unexpected arg: $1"; return 2
                fi
                shift ;;
        esac
    done

    # --- Validate ---
    if [[ -z $SCAN_REPO_SPEC ]]; then
        log_error "scan: missing <owner/repo> argument"
        return 2
    fi

    case $SCAN_MIN_PRIORITY in
        high|medium|low) ;;
        *) log_error "scan: --priority must be high, medium or low"; return 2 ;;
    esac

    # --- Setup ---
    parse_repo_spec "$SCAN_REPO_SPEC" || return 2
    bot_auth_setup
    state_ensure "$REPO_SLUG"

    # Apply engine/model overrides for scan session
    if [[ -n $SCAN_ENGINE ]]; then
        CODING_ENGINE=$SCAN_ENGINE
        export CODING_ENGINE
    fi
    if [[ -n $SCAN_MODEL ]]; then
        CLAUDE_MODEL=$SCAN_MODEL
        export CLAUDE_MODEL
    fi

    export REPO_OWNER REPO_NAME REPO_SLUG REPO_PATH BASE_BRANCH

    gh_clone_if_missing || return 1

    # --- Fetch existing issues for deduplication ---
    log_info "Fetching existing open issues for deduplication..."
    local existing_json
    existing_json=$(_gh issue list --state open --json number,title --limit 500 2>/dev/null) || existing_json="[]"
    local EXISTING_ISSUES
    EXISTING_ISSUES=$(echo "$existing_json" | jq -r '.[] | "- #\(.number): \(.title)"' 2>/dev/null || echo "(none)")
    export EXISTING_ISSUES

    # --- Determine scan scope ---
    local SCAN_SCOPE
    if [[ -n $SCAN_PATHS ]]; then
        # Convert comma-separated paths to absolute paths
        local _paths="" _p
        IFS=',' read -ra _path_arr <<< "$SCAN_PATHS"
        for _p in "${_path_arr[@]}"; do
            _p=$(echo "$_p" | xargs)  # trim whitespace
            [[ -n $_paths ]] && _paths+=", "
            _paths+="$REPO_PATH/$_p"
        done
        SCAN_SCOPE="Only scan these paths: $_paths"
    else
        SCAN_SCOPE="Scan the entire repository at $REPO_PATH"
    fi
    export SCAN_SCOPE

    # --- Set CLAUDE_MD_PATH ---
    local CLAUDE_MD_PATH="$REPO_PATH/CLAUDE.md"
    if (( ${SETTING_STEALTH:-0} == 1 )) && [[ -n ${AUTOCODING_REPOS_CTX_DIR:-} ]]; then
        if [[ -f "$REPO_PATH/CLAUDE.md" ]]; then
            CLAUDE_MD_PATH="$REPO_PATH/CLAUDE.md"
        else
            CLAUDE_MD_PATH="$AUTOCODING_REPOS_CTX_DIR/$REPO_SLUG/CLAUDE.md"
        fi
    fi
    export CLAUDE_MD_PATH

    # --- Export MAX_FINDINGS and extra context for prompt ---
    local MAX_FINDINGS="${SCAN_MAX_FINDINGS:-unlimited}"
    export MAX_FINDINGS
    local EXTRA_CONTEXT="${SCAN_CONTEXT:-}"
    export EXTRA_CONTEXT

    # --- Run Claude scan session ---
    local log_dir="$AUTOCODING_LOG_DIR/$REPO_SLUG/scan-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$log_dir"
    LOG_FILE="$log_dir/scan.log"

    log_info "Starting scan of ${REPO_OWNER}/${REPO_NAME} (max findings: ${SCAN_MAX_FINDINGS:-unlimited}, min priority: $SCAN_MIN_PRIORITY)"

    if ! claude_run "$PROMPTS_DIR/scan.md" "$log_dir" "scan"; then
        log_error "Scan session failed"
        return 1
    fi

    # --- Extract JSON from last line ---
    local json_line
    json_line=$(printf '%s' "$CLAUDE_LAST_RESULT" | grep -E '^\[' | tail -1)

    if [[ -z $json_line ]] || ! echo "$json_line" | jq '.' >/dev/null 2>&1; then
        log_error "Scan did not produce valid JSON output"
        log_error "Last result (tail): $(printf '%s' "$CLAUDE_LAST_RESULT" | tail -5)"
        return 1
    fi

    local findings_count
    findings_count=$(echo "$json_line" | jq 'length')
    log_info "Raw findings: $findings_count"

    # --- Priority filter ---
    local filtered_json="$json_line"
    if [[ $SCAN_MIN_PRIORITY != "low" ]]; then
        if [[ $SCAN_MIN_PRIORITY == "high" ]]; then
            filtered_json=$(echo "$json_line" | jq '[.[] | select(.priority == "high")]')
        elif [[ $SCAN_MIN_PRIORITY == "medium" ]]; then
            filtered_json=$(echo "$json_line" | jq '[.[] | select(.priority == "high" or .priority == "medium")]')
        fi
        findings_count=$(echo "$filtered_json" | jq 'length')
        log_info "After priority filter ($SCAN_MIN_PRIORITY+): $findings_count"
    fi

    # --- Max findings cap ---
    if [[ -n $SCAN_MAX_FINDINGS ]] && (( findings_count > SCAN_MAX_FINDINGS )); then
        filtered_json=$(echo "$filtered_json" | jq ".[0:$SCAN_MAX_FINDINGS]")
        findings_count=$SCAN_MAX_FINDINGS
        log_info "Capped to $SCAN_MAX_FINDINGS findings"
    fi

    if (( findings_count == 0 )); then
        log_ok "No findings to report."
        return 0
    fi

    # --- Display findings ---
    log_info "=== Scan Results ==="
    local i title priority labels
    for (( i=0; i<findings_count; i++ )); do
        title=$(echo "$filtered_json" | jq -r ".[$i].title")
        priority=$(echo "$filtered_json" | jq -r ".[$i].priority")
        labels=$(echo "$filtered_json" | jq -r ".[$i].labels | join(\",\")")
        log_info "  [$priority] $title  ($labels)"
    done

    # --- Dry-run: stop here ---
    if (( SCAN_DRY_RUN )); then
        log_ok "Dry run complete. $findings_count finding(s) found, no issues created."
        echo "$filtered_json" | jq '.'
        return 0
    fi

    # --- Ensure labels exist ---
    log_info "Ensuring labels..."
    _gh label create "auto-scan" --color "d4c5f9" --force 2>/dev/null || true
    local _lbl
    for _lbl in bug security quality feature tests performance; do
        _gh label create "$_lbl" --force 2>/dev/null || true
    done

    # --- Create issues ---
    local -a CREATED_ISSUES=()
    local body url num
    for (( i=0; i<findings_count; i++ )); do
        title=$(echo "$filtered_json" | jq -r ".[$i].title")
        body=$(echo "$filtered_json" | jq -r ".[$i].body")
        labels=$(echo "$filtered_json" | jq -r ".[$i].labels | join(\",\")")

        local label_args="auto-scan"
        [[ -n $labels ]] && label_args="auto-scan,$labels"

        url=$(_gh issue create \
            --title "$title" \
            --body "$body" \
            --label "$label_args" 2>&1) || {
            log_warn "Failed to create issue: $title"
            continue
        }

        num=${url##*/}
        CREATED_ISSUES+=("$num")
        log_ok "Created issue #$num: $title ($url)"
    done

    if [[ ${#CREATED_ISSUES[@]} -eq 0 ]]; then
        log_warn "No issues were created."
        return 1
    fi

    log_ok "Created ${#CREATED_ISSUES[@]} issue(s): ${CREATED_ISSUES[*]}"

    # --- Record scan in state ---
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local state_file
    state_file=$(_state_file "$REPO_SLUG")
    local created_json
    created_json=$(printf '%s\n' "${CREATED_ISSUES[@]}" | jq -R 'tonumber' | jq -s '.')
    local tmp; tmp=$(mktemp)
    jq --arg ts "$ts" \
       --argjson created "$created_json" \
       --argjson tokens "${CLAUDE_LAST_TOKENS:-0}" '
        .scans //= {} |
        .scans[$ts] = {
            findings: ($created | length),
            created: $created,
            usage: { tokens: $tokens }
        }
    ' "$state_file" >"$tmp" && mv "$tmp" "$state_file"

    # --- Chain to --fix if requested ---
    if (( SCAN_FIX )); then
        local issue_list
        issue_list=$(IFS=,; echo "${CREATED_ISSUES[*]}")
        log_info "Starting auto-fix for issues: $issue_list"
        exec "$SCRIPT_DIR/auto-code.sh" "$REPO_OWNER/$REPO_NAME" \
            --issues "$issue_list"
    fi

    return 0
}
