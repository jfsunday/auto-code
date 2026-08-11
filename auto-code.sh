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
# shellcheck source=lib/wizard.sh
source "$LIB_DIR/wizard.sh"
# shellcheck source=lib/workflow.sh
source "$LIB_DIR/workflow.sh"

usage() {
    cat <<'EOF'
auto-code <owner/repo> [options]
auto-code add-issue <owner/repo> "<title>" [--body "<text>" | --body-file <path>]

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
  --stealth             Repo stays clean: CLAUDE.md and .claude/context/ files
                        live under ~/.config/autocoding/repos/<slug>/, never
                        committed. Only real code changes end up in the PR.
  --no-stealth          Re-enable committing context artifacts to the repo
  --auto-merge          Merge the PR immediately after creating it. Pulls the
                        updated base branch locally so the next issue starts
                        from up-to-date code (avoids serial-phase conflicts).
                        Also closes the source issue (safety net in case
                        "Closes #N" auto-close is skipped by GitHub).
                        Skipped in --local mode.
  --no-auto-merge       Disable auto-merge (default)
  --auto-merge-strategy Merge strategy: merge (default) | squash | rebase
  --reset-options       Wipe persisted per-repo settings back to defaults

Coding engine (persisted per repo):
  --engine NAME         claude (default) | opencode. Selects the CLI that runs
                        the plan/code/review/fix/context sessions. Both agents
                        read CLAUDE.md automatically; opencode additionally
                        picks up AGENTS.md and ~/.config/opencode/AGENTS.md.
  --model NAME          Model to use. Passed through to the selected engine.
                        For --engine opencode use provider/model form
                        (e.g. anthropic/claude-sonnet-4-5, google/gemini-2.5-pro).
                        For --engine claude a plain alias works (opus, sonnet).

Interactive:
  -i, --interactive     Ask for branch prefix, model, max-reviews, base-branch
                        before starting. Values apply to the whole run.
  --branch <name>       Explicit branch name. With one issue/task: used as-is.
                        With multiple issues: used as prefix (name-42, name-43).

Task mode (no GitHub issues — works with any git remote):
  --task "<title>"      Describe the work directly instead of pulling an issue.
                        Skips gh_issue_get + gh_pr_create. Pushes the branch;
                        you create MR/PR yourself on GitLab/Gitea/etc.
  --task-body "<text>"  Optional body text for the task
  --task-body-file <p>  Read body from file
  --task-id <slug>      Override branch slug (default: from title). Reusing the
                        same id auto-resumes the existing task branch.

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
CLI_STEALTH_SET=0
CLI_STEALTH_VAL=0
CLI_BASE_SET=0
CLI_AM_SET=0
CLI_AM_VAL=0
AUTO_MERGE_STRATEGY="merge"
CLI_ENGINE_SET=0
CLI_ENGINE_VAL=""
CLI_MODEL_SET=0
CLI_MODEL_VAL=""
RESET_OPTIONS=0
INTERACTIVE=0
TASK_MODE=0
TASK_TITLE=""
TASK_BODY=""
TASK_BODY_FILE=""
TASK_ID=""

# Sub-commands ------------------------------------------------------------
if [[ ${1:-} == "add-issue" ]]; then
    shift
    REPO_SPEC=""
    ISSUE_TITLE=""
    ISSUE_BODY=""
    ISSUE_BODY_FILE=""
    while (( $# )); do
        case $1 in
            --body)      ISSUE_BODY=$2; shift 2 ;;
            --body-file) ISSUE_BODY_FILE=$2; shift 2 ;;
            -h|--help)
                echo "auto-code add-issue <owner/repo> \"<title>\" [--body \"<text>\" | --body-file <path>]"
                exit 0 ;;
            -*) log_error "add-issue: unknown option: $1"; exit 2 ;;
            *)
                if [[ -z $REPO_SPEC ]]; then REPO_SPEC=$1
                elif [[ -z $ISSUE_TITLE ]]; then ISSUE_TITLE=$1
                else log_error "add-issue: unexpected arg: $1"; exit 2
                fi
                shift ;;
        esac
    done
    [[ -z $REPO_SPEC || -z $ISSUE_TITLE ]] && { log_error "add-issue: need <owner/repo> and \"<title>\""; exit 2; }
    parse_repo_spec "$REPO_SPEC" || exit 2
    bot_auth_setup
    _args=(--repo "$REPO_OWNER/$REPO_NAME" --title "$ISSUE_TITLE")
    if [[ -n $ISSUE_BODY_FILE ]]; then
        [[ -f $ISSUE_BODY_FILE ]] || { log_error "body file not found: $ISSUE_BODY_FILE"; exit 2; }
        _args+=(--body-file "$ISSUE_BODY_FILE")
    elif [[ -n $ISSUE_BODY ]]; then
        _args+=(--body "$ISSUE_BODY")
    else
        _args+=(--body "")
    fi
    url=$(gh issue create "${_args[@]}") || { log_error "gh issue create failed"; exit 1; }
    log_ok "Issue created: $url"
    exit 0
fi

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
        --base-branch) BASE_BRANCH=$2; CLI_BASE_SET=1; shift 2 ;;
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
        --stealth)            CLI_STEALTH_SET=1; CLI_STEALTH_VAL=1; shift ;;
        --no-stealth)         CLI_STEALTH_SET=1; CLI_STEALTH_VAL=0; shift ;;
        --auto-merge)         CLI_AM_SET=1; CLI_AM_VAL=1; shift ;;
        --no-auto-merge)      CLI_AM_SET=1; CLI_AM_VAL=0; shift ;;
        --auto-merge-strategy) AUTO_MERGE_STRATEGY=$2; shift 2 ;;
        --engine)             CLI_ENGINE_SET=1; CLI_ENGINE_VAL=$2; shift 2 ;;
        --model)              CLI_MODEL_SET=1;  CLI_MODEL_VAL=$2;  shift 2 ;;
        --interactive|-i)     INTERACTIVE=1; shift ;;
        --branch)             CUSTOM_BRANCH_NAME=$2; shift 2 ;;
        --task)               TASK_MODE=1; TASK_TITLE=$2; shift 2 ;;
        --task-body)          TASK_BODY=$2; shift 2 ;;
        --task-body-file)     TASK_BODY_FILE=$2; shift 2 ;;
        --task-id)            TASK_ID=$2; shift 2 ;;
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

# --task validation and derived vars (must run after parse_repo_spec so slugify works)
if (( TASK_MODE )); then
    [[ -z $TASK_TITLE ]] && { log_error "--task requires a title"; exit 2; }
    if [[ -n $TASK_BODY_FILE ]]; then
        [[ -f $TASK_BODY_FILE ]] || { log_error "task body file not found: $TASK_BODY_FILE"; exit 2; }
        TASK_BODY=$(cat "$TASK_BODY_FILE")
    fi
    [[ -z $TASK_ID ]] && TASK_ID=$(slugify "$TASK_TITLE")
    # Populate the ISSUE_* variables that the rest of the pipeline expects.
    ISSUE_NUM="task-${TASK_ID}"
    ISSUE_TITLE=$TASK_TITLE
    ISSUE_BODY=$TASK_BODY
    ISSUE_URL=""
    ISSUE_LABELS=""
    export TASK_MODE TASK_ID ISSUE_NUM ISSUE_TITLE ISSUE_BODY ISSUE_URL ISSUE_LABELS
fi

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
SETTING_STEALTH=0
SETTING_AUTO_MERGE=0
MODEL_EXPLICIT=0   # 1 once a model comes from persisted state or a CLI --model
_val=$(state_get_setting "$REPO_SLUG" init);           [[ -n $_val ]] && SETTING_INIT=$_val
_val=$(state_get_setting "$REPO_SLUG" context_update); [[ -n $_val ]] && SETTING_CONTEXT_UPDATE=$_val
_val=$(state_get_setting "$REPO_SLUG" stealth);        [[ -n $_val ]] && SETTING_STEALTH=$_val
_val=$(state_get_setting "$REPO_SLUG" auto_merge);     [[ -n $_val ]] && SETTING_AUTO_MERGE=$_val
_val=$(state_get_setting "$REPO_SLUG" base_branch);    [[ -n $_val ]] && BASE_BRANCH=$_val
_val=$(state_get_setting "$REPO_SLUG" engine);         [[ -n $_val ]] && CODING_ENGINE=$_val
_val=$(state_get_setting "$REPO_SLUG" model);          [[ -n $_val ]] && { CLAUDE_MODEL=$_val; MODEL_EXPLICIT=1; }

if (( CLI_INIT_SET )); then
    SETTING_INIT=$CLI_INIT_VAL
    state_set_setting "$REPO_SLUG" init "$CLI_INIT_VAL"
fi
if (( CLI_CTX_SET )); then
    SETTING_CONTEXT_UPDATE=$CLI_CTX_VAL
    state_set_setting "$REPO_SLUG" context_update "$CLI_CTX_VAL"
fi
if (( CLI_STEALTH_SET )); then
    SETTING_STEALTH=$CLI_STEALTH_VAL
    state_set_setting "$REPO_SLUG" stealth "$CLI_STEALTH_VAL"
fi
if (( CLI_AM_SET )); then
    SETTING_AUTO_MERGE=$CLI_AM_VAL
    state_set_setting "$REPO_SLUG" auto_merge "$CLI_AM_VAL"
fi
if (( CLI_BASE_SET )); then
    state_set_setting "$REPO_SLUG" base_branch "$BASE_BRANCH"
fi
if (( CLI_ENGINE_SET )); then
    case $CLI_ENGINE_VAL in
        claude|opencode) ;;
        *) log_error "--engine must be 'claude' or 'opencode' (got: $CLI_ENGINE_VAL)"; exit 2 ;;
    esac
    CODING_ENGINE=$CLI_ENGINE_VAL
    state_set_setting "$REPO_SLUG" engine "$CLI_ENGINE_VAL"
fi
if (( CLI_MODEL_SET )); then
    CLAUDE_MODEL=$CLI_MODEL_VAL
    MODEL_EXPLICIT=1
    state_set_setting "$REPO_SLUG" model "$CLI_MODEL_VAL"
fi

# Engine-specific default model. CLAUDE_MODEL's built-in default is a Claude
# alias (e.g. "opus") that opencode cannot resolve — it would silently ignore it
# and fall back to its own last-used model. So when the engine is opencode and
# the user never picked a model explicitly (no --model, none persisted), use the
# opencode default OPENCODE_MODEL instead.
if (( MODEL_EXPLICIT == 0 )) && [[ $CODING_ENGINE == opencode && -n ${OPENCODE_MODEL:-} ]]; then
    CLAUDE_MODEL=$OPENCODE_MODEL
fi

# opencode expects provider/model form — warn if it looks like a bare Claude alias.
if [[ $CODING_ENGINE == opencode && $CLAUDE_MODEL != */* ]]; then
    log_warn "engine=opencode but model '$CLAUDE_MODEL' has no provider/ prefix — opencode may reject it and fall back to its own model."
    log_warn "Use a provider/model id from your opencode config, e.g. --model $OPENCODE_MODEL or --model litellm/claude-sonnet-4-6."
fi

# Make sure the selected engine binary is actually installed before we spend time.
if ! command -v "$CODING_ENGINE" >/dev/null 2>&1; then
    log_error "Selected engine '$CODING_ENGINE' not found in PATH. Install it or pass --engine claude."
    exit 2
fi

log_info "Options: engine=$CODING_ENGINE model=$CLAUDE_MODEL init=$SETTING_INIT context_update=$SETTING_CONTEXT_UPDATE stealth=$SETTING_STEALTH auto_merge=$SETTING_AUTO_MERGE base=$BASE_BRANCH"

if (( INTERACTIVE )); then
    run_wizard
fi

export REPO_OWNER REPO_NAME REPO_SLUG REPO_PATH BASE_BRANCH MAX_REVIEWS
export DRY_RUN VERBOSE FORCE_RETRY LOCAL_MODE RESUME CODING_ENGINE CLAUDE_MODEL CLAUDE_RETRIES CLAUDE_BACKOFF_BASE
export CLAUDE_MAX_BUDGET_USD PROMPTS_DIR
export SETTING_INIT SETTING_CONTEXT_UPDATE SETTING_STEALTH SETTING_AUTO_MERGE AUTO_MERGE_STRATEGY INTERACTIVE
export AUTOCODING_GH_USER AUTOCODING_GIT_NAME AUTOCODING_GIT_EMAIL BOT_ACTIVE
export AUTOCODING_REPOS_CTX_DIR CUSTOM_BRANCH_NAME

(( LOCAL_MODE )) && log_info "Local mode: no push, no PR, no context-update."

# Main run: process one selection cycle. Called once, or repeatedly in watch mode.
run_cycle() {
    log_info "Cycle start for ${REPO_OWNER}/${REPO_NAME} (mode=$SELECTION_MODE)"

    # Ensure state file exists
    state_ensure "$REPO_SLUG"

    # Resolve target list. In --task mode we skip GitHub entirely.
    local -a issues
    if (( TASK_MODE )); then
        issues=("$ISSUE_NUM")
        log_info "Task mode: $TASK_TITLE (id=$TASK_ID)"
    else
        if ! mapfile -t issues < <(select_issues "$SELECTION_MODE" "$SELECTION_ARG"); then
            log_error "Failed to select issues."
            return 1
        fi

        if [[ ${#issues[@]} -eq 0 ]]; then
            log_info "No matching open issues to process."
            return 0
        fi

        log_info "Will process ${#issues[@]} issue(s): ${issues[*]}"
    fi

    local n rc=0
    if (( ${#issues[@]} > 1 )); then MULTI_TARGETS=1; else MULTI_TARGETS=0; fi
    export MULTI_TARGETS
    for n in "${issues[@]}"; do
        if process_issue "$n"; then
            if (( TASK_MODE == 1 )); then
                log_ok "Task '$TASK_TITLE' → $LAST_PR_URL"
            elif (( LOCAL_MODE == 0 )); then
                state_mark_processed "$REPO_SLUG" "$n" "$LAST_PR_URL"
                log_ok "Issue #$n → $LAST_PR_URL"
            else
                log_ok "Issue #$n → committed locally on branch (not marked processed, no PR)"
            fi
        else
            state_mark_error "$REPO_SLUG" "$n" "$LAST_ERROR"
            if (( TASK_MODE == 1 )); then
                log_error "Task '$TASK_TITLE' failed: $LAST_ERROR"
            else
                log_error "Issue #$n failed: $LAST_ERROR"
            fi
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
