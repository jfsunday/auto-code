#!/usr/bin/env bash
# Rate-limit coordination shared across the parent scheduler and every worker
# subprocess.
#
# Mechanism: a single flag file (default $AUTOCODING_HOME/ratelimit.flag) whose
# mtime marks the last time ANY process saw a rate-limit response. Because all
# processes default AUTOCODING_HOME to the same path, a worker that hits a limit
# signals the parent scheduler simply by touching this file.
#
#   rl_detect <session_file>  -> 0 if the file looks like a rate-limit error
#   rl_mark                   -> stamp the flag (now)
#   rl_active                 -> 0 if a limit was seen within RL_COOLDOWN seconds
#   rl_age                    -> prints seconds since the last mark (or big number)
#   rl_wait_until_clear       -> blocks until no fresh signal for RL_COOLDOWN

: "${RL_FLAG:=${AUTOCODING_HOME:-$HOME/.config/autocoding}/ratelimit.flag}"
# Seconds a rate-limit signal is considered "still active" after the last hit.
: "${RL_COOLDOWN:=60}"
# Seconds of clean running before the scheduler raises concurrency by one.
: "${RL_RAMP_INTERVAL:=120}"

_rl_now() { date +%s; }

_rl_mtime() {
    [[ -f $RL_FLAG ]] || { echo 0; return; }
    # GNU stat first, BSD stat fallback.
    /usr/bin/stat -c %Y -- "$RL_FLAG" 2>/dev/null \
        || /usr/bin/stat -f %m -- "$RL_FLAG" 2>/dev/null \
        || echo 0
}

# rl_detect <session_file> — best-effort scan of a claude/opencode session dump
# (JSON or stream-json) for rate-limit indicators. Returns 0 (true) on match.
rl_detect() {
    local f=${1:-}
    [[ -n $f && -s $f ]] || return 1
    grep -qiE 'rate[ _-]?limit|rate_limit_error|429|too many requests|overloaded_error|"overloaded"|retry-after|usage limit|quota exceeded' "$f" 2>/dev/null
}

# rl_mark — record "a rate limit was just seen".
rl_mark() {
    mkdir -p "$(dirname "$RL_FLAG")" 2>/dev/null || true
    printf '%s\n' "$(_rl_now)" >"$RL_FLAG" 2>/dev/null || true
}

# rl_age — seconds since last mark; 999999 if never.
rl_age() {
    local m; m=$(_rl_mtime)
    if [[ $m == 0 ]]; then echo 999999; return; fi
    echo $(( $(_rl_now) - m ))
}

# rl_active — true if a rate limit was seen within RL_COOLDOWN seconds.
rl_active() {
    local age; age=$(rl_age)
    (( age < RL_COOLDOWN ))
}

# rl_wait_until_clear — block while rate-limited, polling every few seconds.
# Returns once no fresh signal has arrived for RL_COOLDOWN seconds.
rl_wait_until_clear() {
    local waited=0 step=5
    while rl_active; do
        local age; age=$(rl_age)
        local remain=$(( RL_COOLDOWN - age ))
        (( remain < 1 )) && remain=1
        command -v log_warn >/dev/null 2>&1 \
            && log_warn "Rate limit active (last hit ${age}s ago). Waiting ${remain}s more before resuming..."
        sleep "$step"
        waited=$(( waited + step ))
        # Safety valve: never wait forever.
        if (( waited > 3600 )); then
            command -v log_warn >/dev/null 2>&1 \
                && log_warn "Rate-limit wait exceeded 1h — giving up the wait and resuming cautiously."
            break
        fi
    done
}
