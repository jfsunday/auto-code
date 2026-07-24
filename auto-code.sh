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
# shellcheck source=lib/auth.sh
source "$LIB_DIR/auth.sh"
# shellcheck source=lib/state.sh
source "$LIB_DIR/state.sh"
# shellcheck source=lib/github.sh
source "$LIB_DIR/github.sh"
# shellcheck source=lib/claude.sh
source "$LIB_DIR/claude.sh"
# shellcheck source=lib/context.sh
source "$LIB_DIR/context.sh"
# shellcheck source=lib/usage.sh
source "$LIB_DIR/usage.sh"
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
  --local               Work locally only: no push, no PR, no context-update.
                        Issue is NOT marked processed — a later run without
                        --local can finish/push it (combine with --resume).
  --resume              (No-op: resume happens automatically when a local
                        work branch `auto/issue-N-*` exists. In query modes
                        --oldest/--n-oldest/--all, hanging issues jump ahead.)

Token usage report (no cycle, no watch — prints and exits):
  --usage               Show lifetime totals + top repos
  --usage <owner/repo>  Show per-issue breakdown for that repo

Optional context sessions (auto-persisted per repo):
  --no-init             Skip CLAUDE.md init session; use existing CLAUDE.md if any
  --init                Re-enable init (overrides persisted --no-init)
  --no-context-update   Skip post-PR context-update session
  --context-update      Re-enable context-update
  --reset-options       Wipe persisted per-repo settings back to defaults

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
USAGE_MODE=0
LOCAL_MODE=0
RESUME=0
CLI_INIT_SET=0
CLI_INIT_VAL=1
CLI_CTX_SET=0
CLI_CTX_VAL=1
RESET_OPTIONS=0

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
        --usage) USAGE_MODE=1; shift ;;
        --local) LOCAL_MODE=1; shift ;;
        --resume) RESUME=1; shift ;;
        --no-init)            CLI_INIT_SET=1; CLI_INIT_VAL=0; shift ;;
        --init)               CLI_INIT_SET=1; CLI_INIT_VAL=1; shift ;;
        --no-context-update)  CLI_CTX_SET=1;  CLI_CTX_VAL=0;  shift ;;
        --context-update)     CLI_CTX_SET=1;  CLI_CTX_VAL=1;  shift ;;
        --reset-options)      RESET_OPTIONS=1; shift ;;
        --) shift; break ;;
        -*) log_error "Unknown option: $1"; usage; exit 2 ;;
        *)
            if [[ -z $REPO_SPEC ]]; then REPO_SPEC=$1
            else log_error "Unexpected positional arg: $1"; exit 2
            fi
            shift ;;
    esac
done

# --usage mode: report and exit. Repo spec optional here.
if (( USAGE_MODE )); then
    if [[ -n $REPO_SPEC ]]; then
        parse_repo_spec "$REPO_SPEC" || exit 2
        usage_report_repo "$REPO_SLUG"
    else
        usage_report_global
    fi
    exit 0
fi

if [[ -z $REPO_SPEC ]]; then
    log_error "Missing <owner/repo> argument."
    usage; exit 2
fi

parse_repo_spec "$REPO_SPEC" || exit 2
mkdir -p "$REPOS_DIR"

# Activate bot identity if configured. Fails hard on misconfig.
bot_auth_setup

# --- Options load-order: defaults → persisted → CLI overrides → auto-persist ---
state_ensure "$REPO_SLUG"

if (( RESET_OPTIONS )); then
    state_reset_settings "$REPO_SLUG"
    log_info "Options for ${REPO_OWNER}/${REPO_NAME} reset to defaults."
fi

SETTING_INIT=1
SETTING_CONTEXT_UPDATE=1
_val=$(state_get_setting "$REPO_SLUG" init);           [[ -n $_val ]] && SETTING_INIT=$_val
_val=$(state_get_setting "$REPO_SLUG" context_update); [[ -n $_val ]] && SETTING_CONTEXT_UPDATE=$_val

if (( CLI_INIT_SET )); then
    SETTING_INIT=$CLI_INIT_VAL
    state_set_setting "$REPO_SLUG" init "$CLI_INIT_VAL"
fi
if (( CLI_CTX_SET )); then
    SETTING_CONTEXT_UPDATE=$CLI_CTX_VAL
    state_set_setting "$REPO_SLUG" context_update "$CLI_CTX_VAL"
fi

log_info "Options: init=$SETTING_INIT context_update=$SETTING_CONTEXT_UPDATE"

export REPO_OWNER REPO_NAME REPO_SLUG REPO_PATH BASE_BRANCH MAX_REVIEWS
export DRY_RUN VERBOSE FORCE_RETRY LOCAL_MODE RESUME CLAUDE_MODEL CLAUDE_RETRIES CLAUDE_BACKOFF_BASE
export CLAUDE_MAX_BUDGET_USD PROMPTS_DIR
export SETTING_INIT SETTING_CONTEXT_UPDATE AUTOCODING_GH_USER AUTOCODING_GIT_NAME AUTOCODING_GIT_EMAIL BOT_ACTIVE

(( LOCAL_MODE )) && log_info "Local mode: no push, no PR, no context-update."

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
        if process_issue "$n"; then
            if (( LOCAL_MODE == 0 )); then
                state_mark_processed "$REPO_SLUG" "$n" "$LAST_PR_URL"
                log_ok "Issue #$n → $LAST_PR_URL"
            else
                log_ok "Issue #$n → committed locally on branch (not marked processed, no PR)"
            fi
        else
            state_mark_error "$REPO_SLUG" "$n" "$LAST_ERROR"
            log_error "Issue #$n failed: $LAST_ERROR"
            rc=1
        fi
    done
    usage_log_cycle "$REPO_SLUG"
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
