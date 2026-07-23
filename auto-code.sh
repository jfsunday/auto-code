#!/usr/bin/env bash
# auto-code — turn GitHub issues into pull requests with Claude Code.
#
# Usage:
#   auto-code <owner/repo> [options]
#
# See --help for full details.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
PROMPTS_DIR="$SCRIPT_DIR/prompts"

# shellcheck source=lib/config.sh
source "$LIB_DIR/config.sh"
# shellcheck source=lib/logging.sh
source "$LIB_DIR/logging.sh"
# shellcheck source=lib/state.sh
source "$LIB_DIR/state.sh"
# shellcheck source=lib/github.sh
source "$LIB_DIR/github.sh"
# shellcheck source=lib/claude.sh
source "$LIB_DIR/claude.sh"
# shellcheck source=lib/context.sh
source "$LIB_DIR/context.sh"
# shellcheck source=lib/workflow.sh
source "$LIB_DIR/workflow.sh"

usage() {
    cat <<'EOF'
auto-code <owner/repo> [options]

Turn GitHub issues into pull requests using Claude Code.

Issue selection (mutually exclusive, default --oldest):
  --oldest              Oldest open issue
  --issue N             Specific issue number
  --issues N,M,...      Multiple specific issues (sequential)
  --n-oldest N          N oldest issues (sequential)
  --all                 All open issues (sequential)

Behavior:
  --max-reviews N       Max review loops per issue (default: config MAX_REVIEWS)
  --base-branch NAME    PR target branch (default: config BASE_BRANCH)
  --repos-dir PATH      Where to clone repos (default: config REPOS_DIR)
  --watch               After a run, sleep and repeat
  --interval DUR        Watch interval, e.g. 30s / 5m / 1h (default: config WATCH_INTERVAL)
  --retry               Reprocess even if state says done or errored
  --dry-run             Render prompts and stop before the first Claude call
  --verbose             Live-stream Claude session output

  -h, --help            Show this help
EOF
}

# Defaults for CLI-parsed values
REPO_SPEC=""
SELECTION_MODE="oldest"
SELECTION_ARG=""
WATCH=0
DRY_RUN=0
VERBOSE=0
FORCE_RETRY=0

# Argument parsing --------------------------------------------------------
if [[ $# -eq 0 ]]; then usage; exit 0; fi

while (( $# )); do
    case $1 in
        -h|--help) usage; exit 0 ;;
        --oldest) SELECTION_MODE="oldest"; shift ;;
        --issue) SELECTION_MODE="issue"; SELECTION_ARG=$2; shift 2 ;;
        --issues) SELECTION_MODE="issues"; SELECTION_ARG=$2; shift 2 ;;
        --n-oldest) SELECTION_MODE="n-oldest"; SELECTION_ARG=$2; shift 2 ;;
        --all) SELECTION_MODE="all"; shift ;;
        --max-reviews) MAX_REVIEWS=$2; shift 2 ;;
        --base-branch) BASE_BRANCH=$2; shift 2 ;;
        --repos-dir) REPOS_DIR=$2; shift 2 ;;
        --watch) WATCH=1; shift ;;
        --interval) WATCH_INTERVAL=$2; shift 2 ;;
        --retry) FORCE_RETRY=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --verbose) VERBOSE=1; shift ;;
        --) shift; break ;;
        -*) log_error "Unknown option: $1"; usage; exit 2 ;;
        *)
            if [[ -z $REPO_SPEC ]]; then REPO_SPEC=$1
            else log_error "Unexpected positional arg: $1"; exit 2
            fi
            shift ;;
    esac
done

if [[ -z $REPO_SPEC ]]; then
    log_error "Missing <owner/repo> argument."
    usage; exit 2
fi

parse_repo_spec "$REPO_SPEC" || exit 2
mkdir -p "$REPOS_DIR"

export REPO_OWNER REPO_NAME REPO_SLUG REPO_PATH BASE_BRANCH MAX_REVIEWS
export DRY_RUN VERBOSE FORCE_RETRY CLAUDE_MODEL CLAUDE_RETRIES CLAUDE_BACKOFF_BASE
export CLAUDE_MAX_BUDGET_USD PROMPTS_DIR

# Main run: process one selection cycle. Called once, or repeatedly in watch mode.
run_cycle() {
    log_info "Cycle start for ${REPO_OWNER}/${REPO_NAME} (mode=$SELECTION_MODE)"

    # Ensure state file exists
    state_ensure "$REPO_SLUG"

    # Resolve issue list
    local -a issues
    if ! mapfile -t issues < <(select_issues "$SELECTION_MODE" "$SELECTION_ARG"); then
        log_error "Failed to select issues."
        return 1
    fi

    if [[ ${#issues[@]} -eq 0 ]]; then
        log_info "No matching open issues to process."
        return 0
    fi

    log_info "Will process ${#issues[@]} issue(s): ${issues[*]}"

    local n rc=0
    for n in "${issues[@]}"; do
        if (( FORCE_RETRY == 0 )) && state_is_processed "$REPO_SLUG" "$n"; then
            log_info "Issue #$n already processed (state). Skipping. Use --retry to force."
            continue
        fi
        if process_issue "$n"; then
            state_mark_processed "$REPO_SLUG" "$n" "$LAST_PR_URL"
            log_ok "Issue #$n → $LAST_PR_URL"
        else
            state_mark_error "$REPO_SLUG" "$n" "$LAST_ERROR"
            log_error "Issue #$n failed: $LAST_ERROR"
            rc=1
        fi
    done
    return $rc
}

# Graceful SIGINT for watch mode
_STOP=0
trap '_STOP=1; log_warn "Interrupt received. Will exit after current cycle."' INT TERM

if (( WATCH )); then
    interval_seconds=$(parse_duration "$WATCH_INTERVAL") || {
        log_error "Bad interval: $WATCH_INTERVAL"
        exit 2
    }
    log_info "Watch mode active. Interval: ${WATCH_INTERVAL} (${interval_seconds}s). Ctrl-C to stop."
    while (( _STOP == 0 )); do
        run_cycle || log_warn "Cycle finished with errors."
        (( _STOP )) && break
        log_info "Sleeping ${interval_seconds}s..."
        for _ in $(seq 1 "$interval_seconds"); do
            (( _STOP )) && break
            sleep 1
        done
    done
    log_info "Watch loop exited."
else
    run_cycle
fi
