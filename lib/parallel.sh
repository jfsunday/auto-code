#!/usr/bin/env bash
# Parallel issue processing with an LLM pre-check and rate-limit-aware
# concurrency control.
#
# Entry point: parallel_run <issue> [<issue> ...]
#
# Strategy:
#   1. Ensure the primary clone exists (serial, once).
#   2. Ask the coding engine which issues are safe to run in parallel. The
#      answer is a set of "waves"; issues in the same wave are unlikely to touch
#      the same files, so they may run concurrently. Waves run in order.
#   3. Run each wave with concurrency capped at PARALLEL_MAX. Each issue runs as
#      an isolated `auto-code --issue N` subprocess bound to its OWN git
#      WORKTREE of the primary clone (own working dir + own branch, shared git
#      objects). Every issue therefore gets its own branch + PR and workflow.sh
#      needs only a tiny worktree-aware branch (AUTOCODE_WORKTREE).
#   4. Rate limits: any worker that hits a limit stamps a shared flag
#      (lib/ratelimit.sh). The scheduler drains in-flight workers, waits until
#      the limit clears, then resumes SEQUENTIALLY (concurrency 1) and ramps
#      back up to PARALLEL_MAX after RL_RAMP_INTERVAL seconds of clean running.
#   5. After each worker finishes, its isolated state is folded back into the
#      main state file by the single-threaded scheduler (no locks needed) and
#      its worktree is removed.
#
# Why worktrees (not full clones): `git worktree add` shares the primary clone's
# object database, so each slot costs only the checked-out files + a little
# metadata — no re-download, near-instant setup, trivial cleanup via
# `git worktree remove`. Each worktree has an independent HEAD/index, so several
# issues can be built on different branches at the same time without the
# "branch already checked out" conflict that a single working tree would hit.
#
# Requires (sourced by auto-code.sh before this file): logging.sh, github.sh,
# claude.sh, state.sh, ratelimit.sh, config.sh, auth.sh.

# ---- module-scoped scheduler state (set in parallel_run) --------------------
PAR_ROOT=""          # temp root holding per-slot worktrees + state/logs
PAR_CAP=1            # current concurrency cap
PAR_CLEAN_SINCE=0    # epoch of last cap change / clean checkpoint
PAR_RC=0             # aggregate return code (1 if any issue failed)

# parallel_run <issue>...  — top-level dispatcher called from run_cycle.
parallel_run() {
    local -a all=("$@")
    (( ${#all[@]} == 0 )) && return 0

    local maxp=${PARALLEL_MAX:-3}
    (( maxp < 1 )) && maxp=1
    log_info "Parallel mode: ${#all[@]} issue(s), max concurrency ${maxp}."

    # 1. Primary clone must exist so the pre-check session has a repo to run in
    #    and so we have an object store to base worktrees on.
    if ! gh_clone_if_missing; then
        LAST_ERROR="parallel: primary clone/sync of ${REPO_OWNER}/${REPO_NAME} failed"
        log_error "$LAST_ERROR"
        return 1
    fi

    # 2. Pre-check → FINAL_WAVES (array of space-separated issue-number lists).
    local -a FINAL_WAVES=()
    parallel_plan_waves FINAL_WAVES "${all[@]}"
    log_info "Schedule: ${#FINAL_WAVES[@]} wave(s):"
    local _w _i=1
    for _w in "${FINAL_WAVES[@]}"; do log_info "  wave $_i: [$_w]"; _i=$((_i+1)); done

    # 3. Set up the temp root that holds per-slot worktrees + state/log dirs.
    PAR_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/autocode-par.XXXXXX") || {
        LAST_ERROR="parallel: could not create temp root"; return 1; }
    PAR_CAP=$maxp
    PAR_CLEAN_SINCE=$(date +%s)
    PAR_RC=0

    # 4. Run each wave.
    local wave
    for wave in "${FINAL_WAVES[@]}"; do
        parallel_run_wave "$maxp" $wave
    done

    # 5. Cleanup. Remove any lingering worktrees and prune the registry, then
    #    drop the temp root — unless --local, where clones are kept for resume.
    if (( ${LOCAL_MODE:-0} == 0 )); then
        parallel_cleanup_worktrees
        rm -rf "$PAR_ROOT" 2>/dev/null || true
    else
        log_info "Local mode: worker worktrees kept under $PAR_ROOT for inspection/resume."
    fi

    command -v usage_log_cycle >/dev/null 2>&1 && usage_log_cycle "$REPO_SLUG"
    return $PAR_RC
}

# parallel_cleanup_worktrees — best-effort removal of every worktree we created
# under PAR_ROOT plus a registry prune. Safe to call more than once.
parallel_cleanup_worktrees() {
    [[ -n $PAR_ROOT && -d "$REPO_PATH/.git" ]] || return 0
    local d
    for d in "$PAR_ROOT"/slot-*/repos/*; do
        [[ -e $d ]] || continue
        git -C "$REPO_PATH" worktree remove --force "$d" >/dev/null 2>&1 || true
    done
    git -C "$REPO_PATH" worktree prune >/dev/null 2>&1 || true
}

# parallel_plan_waves <out_array_name> <issue>...
# Fills the named array with parallel-safe waves. Uses the LLM pre-check;
# falls back to fully-serial (one issue per wave) on any problem.
parallel_plan_waves() {
    local -n _out=$1; shift
    local -a nums=("$@")
    local maxp=${PARALLEL_MAX:-3}
    _out=()

    # Build a compact digest of the candidate issues for the model.
    local digest="" n j title body
    for n in "${nums[@]}"; do
        if j=$(gh --repo "${REPO_OWNER}/${REPO_NAME}" issue view "$n" \
                    --json number,title,body 2>/dev/null); then
            title=$(jq -r '.title // ""' <<<"$j" | tr -d '`$' | tr '\n' ' ')
            body=$(jq -r '.body // ""'  <<<"$j" | tr -d '`$' | tr '\n' ' ')
            body=${body:0:500}
            digest+="#${n}: ${title} :: ${body}"$'\n'
        else
            digest+="#${n}: (could not fetch title)"$'\n'
        fi
    done

    # Run the pre-check session (best effort).
    local normalized=""
    if [[ ${DRY_RUN:-0} != 1 ]]; then
        local out_dir="${AUTOCODING_LOG_DIR}/${REPO_SLUG}/parallel"
        mkdir -p "$out_dir"
        export ISSUES_DIGEST="$digest" PARALLEL_MAX="$maxp"
        if claude_run "$PROMPTS_DIR/parallel-check.md" "$out_dir" "parallel-check"; then
            local raw
            raw=$(printf '%s' "$CLAUDE_LAST_RESULT" | grep -oE '\[\[.*\]\]' | tail -1)
            if [[ -n $raw ]]; then
                # Normalize to arrays of KNOWN issue numbers, preserving order.
                local inset
                inset=$(printf '%s\n' "${nums[@]}" | jq -Rn '[inputs|select(length>0)|tonumber]')
                normalized=$(jq -cn --argjson m "$raw" --argjson all "$inset" '
                    ([ $m[]? | if type=="array" then [ .[]? | select(type=="number") ] else [] end ])
                    | map([ .[] | select( . as $x | ($all|index($x)) != null) ])
                    | map(select(length>0))
                ' 2>/dev/null) || normalized=""
            fi
        fi
    fi

    if [[ -z $normalized || $normalized == "[]" ]]; then
        [[ ${DRY_RUN:-0} != 1 ]] && \
            log_warn "Parallel pre-check unavailable/unparseable — running issues sequentially."
        local x; for x in "${nums[@]}"; do _out+=("$x"); done
        return 0
    fi

    # Dedupe across waves + chunk each wave to <= maxp; append any missing
    # issue as its own trailing wave. Done in bash for clarity.
    declare -A seen=()
    local line
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        local -a cur=()
        local x
        for x in $line; do
            [[ -n ${seen[$x]:-} ]] && continue
            seen[$x]=1
            cur+=("$x")
            if (( ${#cur[@]} == maxp )); then
                _out+=("${cur[*]}"); cur=()
            fi
        done
        (( ${#cur[@]} )) && _out+=("${cur[*]}")
    done < <(jq -r '.[] | @tsv' <<<"$normalized" | tr '\t' ' ')

    # Missing issues (model dropped them) → run each on its own.
    local x
    for x in "${nums[@]}"; do
        [[ -z ${seen[$x]:-} ]] && { _out+=("$x"); seen[$x]=1; }
    done

    (( ${#_out[@]} == 0 )) && { local y; for y in "${nums[@]}"; do _out+=("$y"); done; }
    return 0
}

# parallel_run_wave <maxp> <issue>...
# Runs one wave of mutually-safe issues, honoring PAR_CAP and rate limits.
parallel_run_wave() {
    local maxp=$1; shift
    local -a queue=("$@")
    (( ${#queue[@]} == 0 )) && return 0

    # Slot bookkeeping (locals; parallel_reap mutates them via dynamic scope).
    local -a free_slots=()
    local s; for (( s=0; s<maxp; s++ )); do free_slots+=("$s"); done
    declare -A PID2ISSUE=() PID2SLOT=()
    local running=0
    local last_pid=""

    while (( ${#queue[@]} > 0 || running > 0 )); do
        # --- rate-limit gate: drain everything, wait, then go sequential ---
        if rl_active; then
            if (( running > 0 )); then
                log_warn "Rate limit hit — draining ${running} in-flight worker(s) before pausing."
                while (( running > 0 )); do parallel_reap; done
            fi
            rl_wait_until_clear
            PAR_CAP=1
            PAR_CLEAN_SINCE=$(date +%s)
            log_info "Resuming after rate limit at concurrency 1 (will ramp up)."
        fi

        # --- ramp up after a clean stretch ---
        local nowt; nowt=$(date +%s)
        if (( PAR_CAP < maxp )) && (( nowt - PAR_CLEAN_SINCE >= RL_RAMP_INTERVAL )); then
            PAR_CAP=$(( PAR_CAP + 1 ))
            PAR_CLEAN_SINCE=$nowt
            log_info "No rate limits for a while — ramping concurrency up to ${PAR_CAP}."
        fi

        # --- launch up to the current cap ---
        while (( running < PAR_CAP )) && (( ${#queue[@]} > 0 )) && ! rl_active; do
            local n=${queue[0]}; queue=("${queue[@]:1}")
            local slot=${free_slots[0]}; free_slots=("${free_slots[@]:1}")
            if ! parallel_launch "$slot" "$n"; then
                # Launch failed (worktree could not be created) — record + skip.
                log_error "Issue #${n}: could not prepare worktree (slot ${slot})."
                state_mark_error "$REPO_SLUG" "$n" "worktree preparation failed"
                PAR_RC=1
                free_slots+=("$slot")
                continue
            fi
            PID2ISSUE[$last_pid]=$n
            PID2SLOT[$last_pid]=$slot
            running=$(( running + 1 ))
        done

        # --- reap one finished worker ---
        if (( running > 0 )); then
            parallel_reap
        fi
    done
    return 0
}

# parallel_launch <slot> <issue> — start one isolated worker subprocess bound to
# a fresh git worktree. Sets last_pid (in caller scope). Returns non-zero if the
# worktree could not be created (worker not launched).
parallel_launch() {
    local slot=$1 n=$2
    local sdir="$PAR_ROOT/slot-$slot"
    mkdir -p "$sdir/state" "$sdir/logs" "$sdir/repos"
    # Clear this slot's state file so folding picks up only THIS issue's data.
    rm -f "$sdir/state/${REPO_SLUG}.json" 2>/dev/null || true

    # --- create a fresh detached worktree of the primary clone for this issue ---
    # Detached HEAD at BASE_BRANCH's tip: no branch is checked out here, so it can
    # never clash with the primary clone (which holds BASE_BRANCH) or with any
    # sibling worktree. The worker then cuts its own work branch from this HEAD
    # (see workflow.sh AUTOCODE_WORKTREE path). Worktree creation is serialized
    # here in the parent, so concurrent `git worktree add` races cannot happen.
    local slot_repo="$sdir/repos/${REPO_NAME}"
    if [[ ! -d "$REPO_PATH/.git" ]]; then
        log_error "parallel_launch: primary clone missing at $REPO_PATH"
        return 1
    fi
    # Scrub any leftover worktree at this path (slot reuse / previous crash).
    git -C "$REPO_PATH" worktree remove --force "$slot_repo" >/dev/null 2>&1 || true
    rm -rf "$slot_repo" 2>/dev/null || true
    git -C "$REPO_PATH" worktree prune >/dev/null 2>&1 || true

    log_info "→ Preparing slot ${slot}: git worktree for issue #${n} (shared objects)..."
    if ! git -C "$REPO_PATH" worktree add --detach "$slot_repo" "$BASE_BRANCH" \
            >>"${LOG_FILE:-/dev/null}" 2>&1; then
        # Fallback: try detaching from origin/BASE_BRANCH if the local ref lagged.
        if ! git -C "$REPO_PATH" worktree add --detach "$slot_repo" "origin/$BASE_BRANCH" \
                >>"${LOG_FILE:-/dev/null}" 2>&1; then
            log_error "git worktree add failed for issue #${n} (base: $BASE_BRANCH)."
            rm -rf "$slot_repo" 2>/dev/null || true
            return 1
        fi
    fi

    local wlog="$sdir/logs/issue-${n}.out"

    # Reconstruct the effective options as explicit flags. The worker uses an
    # isolated state dir (so it won't read persisted per-repo settings), hence
    # we pass everything that matters on the command line.
    local -a args=(
        "$SCRIPT_DIR/auto-code.sh" "${REPO_OWNER}/${REPO_NAME}"
        --issue "$n"
        --no-parallel
        --repos-dir "$sdir/repos"
        --base-branch "$BASE_BRANCH"
        --max-reviews "$MAX_REVIEWS"
        --engine "$CODING_ENGINE"
        --model "$CLAUDE_MODEL"
        --auto-merge-strategy "$AUTO_MERGE_STRATEGY"
    )
    (( ${SETTING_STEALTH:-0} == 1 ))        && args+=(--stealth)         || args+=(--no-stealth)
    (( ${SETTING_AUTO_MERGE:-0} == 1 ))     && args+=(--auto-merge)      || args+=(--no-auto-merge)
    [[ ${SETTING_REVIEWER:-none} == none ]] && args+=(--no-reviewer)     || args+=(--reviewer "$SETTING_REVIEWER")
    (( ${SETTING_INIT:-1} == 1 ))           && args+=(--init)            || args+=(--no-init)
    (( ${SETTING_CONTEXT_UPDATE:-1} == 1 )) && args+=(--context-update)  || args+=(--no-context-update)
    (( ${LOCAL_MODE:-0} == 1 ))             && args+=(--local)
    (( ${FORCE_RETRY:-0} == 1 ))            && args+=(--retry)

    log_info "→ Launch issue #${n} (slot ${slot}). Log: $wlog"

    # Isolated home dirs keep worker state/logs separate. AUTOCODE_WORKTREE tells
    # workflow.sh its REPO_PATH is a pre-made detached worktree (skip clone + base
    # checkout, just branch off HEAD). Per-phase model env is forwarded so workers
    # honor the same plan/code/review/fix engine+model. RL_FLAG intentionally NOT
    # overridden → shared rate-limit signal.
    AUTOCODE_WORKTREE=1 \
    AUTOCODING_STATE_DIR="$sdir/state" \
    AUTOCODING_LOG_DIR="$sdir/logs" \
    ENGINE_PLAN="$ENGINE_PLAN"     MODEL_PLAN="$MODEL_PLAN" \
    ENGINE_CODE="$ENGINE_CODE"     MODEL_CODE="$MODEL_CODE" \
    ENGINE_REVIEW="$ENGINE_REVIEW" MODEL_REVIEW="$MODEL_REVIEW" \
    ENGINE_FIX="$ENGINE_FIX"       MODEL_FIX="$MODEL_FIX" \
        bash "${args[@]}" >"$wlog" 2>&1 &
    last_pid=$!
    return 0
}

# parallel_reap — wait for one worker to finish, fold its state, free its slot.
# Mutates caller locals: running, free_slots, PID2ISSUE, PID2SLOT (dynamic scope).
parallel_reap() {
    local fpid="" st=0
    if wait -n -p fpid 2>/dev/null; then st=0; else st=$?; fi

    # Fallback for bash without `wait -n -p`: poll known pids.
    if [[ -z ${fpid:-} ]]; then
        local p
        for p in "${!PID2ISSUE[@]}"; do
            if ! kill -0 "$p" 2>/dev/null; then
                fpid=$p; wait "$p" 2>/dev/null; st=$?; break
            fi
        done
    fi
    [[ -z ${fpid:-} ]] && { sleep 1; return 0; }

    local n=${PID2ISSUE[$fpid]:-} slot=${PID2SLOT[$fpid]:-}
    [[ -z $n ]] && return 0
    unset "PID2ISSUE[$fpid]" "PID2SLOT[$fpid]"
    running=$(( running - 1 ))
    [[ -n $slot ]] && free_slots+=("$slot")

    parallel_fold_state "$slot" "$n"
    (( st != 0 )) && PAR_RC=1

    # Remove this worker's worktree (unless --local, where we keep it to resume).
    if [[ -n $slot ]] && (( ${LOCAL_MODE:-0} == 0 )); then
        local slot_repo="$PAR_ROOT/slot-$slot/repos/${REPO_NAME}"
        git -C "$REPO_PATH" worktree remove --force "$slot_repo" >/dev/null 2>&1 \
            || rm -rf "$slot_repo" 2>/dev/null || true
        git -C "$REPO_PATH" worktree prune >/dev/null 2>&1 || true
    fi

    # If this worker tripped a rate limit, immediately fall back to sequential.
    if rl_active && (( PAR_CAP > 1 )); then
        PAR_CAP=1
        PAR_CLEAN_SINCE=$(date +%s)
        log_warn "Worker signaled a rate limit — dropping concurrency to 1."
    fi
    return 0
}

# parallel_fold_state <slot> <issue> — merge a worker's isolated state for one
# issue into the main state file, then recompute totals + global usage.
parallel_fold_state() {
    local slot=$1 n=$2
    local wf="$PAR_ROOT/slot-$slot/state/${REPO_SLUG}.json"
    local mf; mf=$(_state_file "$REPO_SLUG")
    state_ensure "$REPO_SLUG"

    if [[ ! -f $wf ]]; then
        log_warn "Issue #${n}: no worker state produced (worker likely failed early). Check its log."
        state_mark_error "$REPO_SLUG" "$n" "worker produced no state (see slot-$slot log)"
        PAR_RC=1
        return 0
    fi

    # Splice the worker's processed[N] / errors[N] into the main file.
    local tmp; tmp=$(mktemp)
    jq --arg n "$n" --slurpfile w "$wf" '
        ($w[0] // {}) as $ws |
        ( if ($ws.processed[$n] // null) != null
          then .processed[$n] = $ws.processed[$n]
          else . end ) |
        ( if ($ws.processed[$n].pr_url // "") != ""
          then del(.errors[$n])
          elif ($ws.errors[$n] // null) != null
          then .errors[$n] = $ws.errors[$n]
          else . end )
    ' "$mf" >"$tmp" 2>/dev/null && mv "$tmp" "$mf" || { rm -f "$tmp"; log_warn "Issue #${n}: state fold failed."; }

    # Recompute issue totals from folded sessions and propagate to global.
    state_finalize_usage "$REPO_SLUG" "$n"

    # Report outcome.
    local pr err
    pr=$(jq -r --arg n "$n" '.processed[$n].pr_url // ""' "$mf" 2>/dev/null)
    if [[ -n $pr && $pr != "null" ]]; then
        log_ok "Issue #${n} → ${pr}"
    else
        err=$(jq -r --arg n "$n" '.errors[$n].message // "unknown error"' "$mf" 2>/dev/null)
        log_error "Issue #${n} failed: ${err}"
        PAR_RC=1
    fi
    return 0
}
