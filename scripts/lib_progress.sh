#!/bin/bash
# =============================================================================
#  lib_progress.sh  —  Progress display
#
#  Provides:
#    progress_init <total> [label]   Start a progress run
#    progress_step [label]           Advance by one and render
#    progress_set <n> [label]        Set absolute position and render
#    progress_finish [label]         Render the final 100% line
#    progress_eta                    Remaining time as HH:MM:SS
#
#  Rendering is emitted through the logger, so progress is visible on the
#  console AND captured in the log file / audit evidence. No ANSI cursor
#  tricks are used, which keeps log files clean and greppable.
#
#  Requires logger.sh to be sourced first.
# =============================================================================

[[ -n "${__ILM_PROGRESS_SOURCED:-}" ]] && return 0
__ILM_PROGRESS_SOURCED=1

PROGRESS_TOTAL=0
PROGRESS_CURRENT=0
PROGRESS_LABEL=""
PROGRESS_START=0
: "${PROGRESS_WIDTH:=30}"

# --- seconds -> HH:MM:SS -----------------------------------------------------
progress_hms() {
    local s="${1:-0}"
    (( s < 0 )) && s=0
    printf '%02d:%02d:%02d' $(( s / 3600 )) $(( (s % 3600) / 60 )) $(( s % 60 ))
}

progress_init() {
    PROGRESS_TOTAL="${1:-0}"
    PROGRESS_LABEL="${2:-Progress}"
    PROGRESS_CURRENT=0
    PROGRESS_START=$(date +%s)
    log INFO "$PROGRESS_LABEL: 0/$PROGRESS_TOTAL (0%)"
}

progress_eta() {
    local elapsed remaining rate
    (( PROGRESS_CURRENT <= 0 || PROGRESS_TOTAL <= 0 )) && { printf '--:--:--'; return 0; }
    elapsed=$(( $(date +%s) - PROGRESS_START ))
    remaining=$(( PROGRESS_TOTAL - PROGRESS_CURRENT ))
    (( remaining <= 0 )) && { printf '00:00:00'; return 0; }
    # integer maths: eta = elapsed * remaining / current
    progress_hms $(( elapsed * remaining / PROGRESS_CURRENT ))
}

progress_render() {
    local label="$*"
    local total=$PROGRESS_TOTAL
    local cur=$PROGRESS_CURRENT

    (( total <= 0 )) && return 0
    (( cur > total )) && cur=$total

    local pct=$(( cur * 100 / total ))
    local filled=$(( pct * PROGRESS_WIDTH / 100 ))
    local empty=$(( PROGRESS_WIDTH - filled ))

    local bar_filled bar_empty
    bar_filled="$(printf '%*s' "$filled" '')"; bar_filled="${bar_filled// /#}"
    bar_empty="$(printf '%*s' "$empty" '')";   bar_empty="${bar_empty// /.}"

    local elapsed
    elapsed=$(( $(date +%s) - PROGRESS_START ))

    log INFO "$(printf '[%s%s] %3d%% (%d/%d) elapsed %s eta %s %s' \
        "$bar_filled" "$bar_empty" "$pct" "$cur" "$total" \
        "$(progress_hms "$elapsed")" "$(progress_eta)" \
        "${label:+- $label}")"
}

progress_step() {
    PROGRESS_CURRENT=$(( PROGRESS_CURRENT + 1 ))
    progress_render "$@"
}

progress_set() {
    PROGRESS_CURRENT="${1:-0}"; shift
    progress_render "$@"
}

progress_finish() {
    PROGRESS_CURRENT=$PROGRESS_TOTAL
    progress_render "${@:-complete}"
}
