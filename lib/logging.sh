#!/usr/bin/env bash
# Colored, timestamped logging. Writes to stderr and, if LOG_FILE is set, appends there too.

if [[ -t 2 ]]; then
    _C_RESET=$'\033[0m'
    _C_INFO=$'\033[36m'   # cyan
    _C_WARN=$'\033[33m'   # yellow
    _C_ERR=$'\033[31m'    # red
    _C_OK=$'\033[32m'     # green
    _C_DIM=$'\033[2m'
else
    _C_RESET=''; _C_INFO=''; _C_WARN=''; _C_ERR=''; _C_OK=''; _C_DIM=''
fi

_log() {
    local level=$1 color=$2; shift 2
    local ts msg
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    msg="[$ts] [$level] $*"
    printf '%s%s%s\n' "$color" "$msg" "$_C_RESET" >&2
    if [[ -n ${LOG_FILE:-} ]]; then
        printf '%s\n' "$msg" >>"$LOG_FILE"
    fi
}

log_info()  { _log INFO  "$_C_INFO"  "$@"; }
log_ok()    { _log OK    "$_C_OK"    "$@"; }
log_warn()  { _log WARN  "$_C_WARN"  "$@"; }
log_error() { _log ERROR "$_C_ERR"   "$@"; }
log_debug() {
    [[ ${VERBOSE:-0} == 1 ]] || return 0
    _log DEBUG "$_C_DIM" "$@"
}

# Set LOG_FILE for the current issue. Creates dir as needed.
set_log_file_for_issue() {
    local issue_num=$1
    local dir="$AUTOCODING_LOG_DIR/$REPO_SLUG"
    mkdir -p "$dir"
    LOG_FILE="$dir/issue-${issue_num}-$(date +%Y%m%d-%H%M%S).log"
    log_debug "Log file: $LOG_FILE"
}
