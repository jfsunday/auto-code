#!/usr/bin/env bash
# Per-phase engine/model selection.
#
# Each pipeline phase (plan / code / review / fix) may run on its own engine
# and model. Empty values fall back to the global CODING_ENGINE / CLAUDE_MODEL.
#
# Configure via config.env, CLI flags (--engine-plan/--model-plan/...), or the
# interactive wizard. Values are read from these env vars:
#   ENGINE_PLAN   MODEL_PLAN
#   ENGINE_CODE   MODEL_CODE
#   ENGINE_REVIEW MODEL_REVIEW
#   ENGINE_FIX    MODEL_FIX
#
# models_resolve <label> maps a claude_run label ("plan", "code", "review-2",
# "fix-1", ...) to a phase and, if a phase override exists, assigns to the
# CODING_ENGINE / CLAUDE_MODEL that are in scope at the call site.
#
# IMPORTANT: claude_run declares `local CODING_ENGINE CLAUDE_MODEL` right before
# calling this function. Bash dynamic scoping means the assignments below land
# on those locals — so the override is confined to that single session and the
# global values are untouched.

# Defaults (empty = inherit global). Respect anything already set by config.env.
: "${ENGINE_PLAN:=}"
: "${MODEL_PLAN:=}"
: "${ENGINE_CODE:=}"
: "${MODEL_CODE:=}"
: "${ENGINE_REVIEW:=}"
: "${MODEL_REVIEW:=}"
: "${ENGINE_FIX:=}"
: "${MODEL_FIX:=}"

# models_resolve <label>
# Mutates CODING_ENGINE / CLAUDE_MODEL in the caller's scope when a phase
# override is configured. No-op for labels without a phase mapping
# (e.g. "init", "context-update", "parallel-check").
models_resolve() {
    local label=$1 phase e m
    case $label in
        plan)     phase=plan ;;
        code)     phase=code ;;
        review-*) phase=review ;;
        fix-*)    phase=fix ;;
        *)        return 0 ;;   # unknown phase → keep globals
    esac

    case $phase in
        plan)   e=$ENGINE_PLAN;   m=$MODEL_PLAN ;;
        code)   e=$ENGINE_CODE;   m=$MODEL_CODE ;;
        review) e=$ENGINE_REVIEW; m=$MODEL_REVIEW ;;
        fix)    e=$ENGINE_FIX;    m=$MODEL_FIX ;;
    esac

    if [[ -n $e ]]; then
        case $e in
            claude|opencode) CODING_ENGINE=$e ;;
            *) command -v log_warn >/dev/null 2>&1 && \
                 log_warn "models_resolve: ignoring invalid engine '$e' for phase '$phase' (use claude|opencode)" ;;
        esac
    fi
    [[ -n $m ]] && CLAUDE_MODEL=$m
    return 0
}

# models_summary — one-line human summary of the active per-phase overrides.
models_summary() {
    local out=""
    [[ -n $ENGINE_PLAN$MODEL_PLAN ]]     && out+="plan=${ENGINE_PLAN:-*}/${MODEL_PLAN:-*} "
    [[ -n $ENGINE_CODE$MODEL_CODE ]]     && out+="code=${ENGINE_CODE:-*}/${MODEL_CODE:-*} "
    [[ -n $ENGINE_REVIEW$MODEL_REVIEW ]] && out+="review=${ENGINE_REVIEW:-*}/${MODEL_REVIEW:-*} "
    [[ -n $ENGINE_FIX$MODEL_FIX ]]       && out+="fix=${ENGINE_FIX:-*}/${MODEL_FIX:-*} "
    [[ -z $out ]] && out="(none — all phases use global engine/model)"
    printf '%s' "$out"
}
