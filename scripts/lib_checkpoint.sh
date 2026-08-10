#!/bin/bash
# =============================================================================
#  lib_checkpoint.sh  —  Restartability
#
#  Lets a failed or interrupted pipeline be re-run without repeating work that
#  already completed successfully.
#
#  Provides:
#    ckpt_init <dir> <run_id>     Open (or reopen) the checkpoint file
#    ckpt_last_run_id <dir>       Run id of the last incomplete run ("" if none)
#    ckpt_is_done <key>           True if the unit of work already completed
#    ckpt_mark_done <key> [note]  Record a unit of work as completed
#    ckpt_count                   Number of completed units
#    ckpt_complete                Mark the whole run finished (clears resume)
#
#  Key convention used by the pipeline:  <APPLICATION>|<STEP>
#    e.g. LIFEDOC_QA|attachment_list, LIFEDOC_QA|table_extract
#
#  Requires logger.sh to be sourced first.
# =============================================================================

[[ -n "${__ILM_CKPT_SOURCED:-}" ]] && return 0
__ILM_CKPT_SOURCED=1

: "${CKPT_DIR:=}"
: "${CKPT_FILE:=}"
CKPT_POINTER=""

# =============================================================================
#  ckpt_init <dir> <run_id>
#    Creates <dir>/<run_id>.ckpt and records <run_id> in <dir>/CURRENT_RUN so a
#    later invocation can discover what to resume.
# =============================================================================
ckpt_init() {
    local dir="$1"
    local rid="$2"

    if [[ -z "$dir" || -z "$rid" ]]; then
        log ERROR "ckpt_init: directory and run_id are required"
        return 1
    fi

    if ! mkdir -p "$dir"; then
        log ERROR "ckpt_init: cannot create checkpoint directory $dir"
        return 1
    fi

    CKPT_DIR="$dir"
    CKPT_FILE="$dir/${rid}.ckpt"
    CKPT_POINTER="$dir/CURRENT_RUN"

    touch "$CKPT_FILE" || { log ERROR "ckpt_init: cannot create $CKPT_FILE"; return 1; }
    printf '%s\n' "$rid" > "$CKPT_POINTER" 2>/dev/null || true

    export CKPT_DIR CKPT_FILE
    return 0
}

# =============================================================================
#  ckpt_last_run_id <dir>
#    Echoes the run id of the last run that did not complete, or nothing.
# =============================================================================
ckpt_last_run_id() {
    local dir="$1"
    local pointer="$dir/CURRENT_RUN"
    [[ -f "$pointer" ]] || return 0
    local rid
    rid="$(head -n 1 "$pointer" 2>/dev/null)"
    [[ -n "$rid" && -f "$dir/${rid}.ckpt" ]] && printf '%s' "$rid"
    return 0
}

# =============================================================================
#  ckpt_is_done <key>
# =============================================================================
ckpt_is_done() {
    local key="$1"
    [[ -n "$CKPT_FILE" && -f "$CKPT_FILE" ]] || return 1
    grep -Fxq "$key" "$CKPT_FILE" 2>/dev/null
}

# =============================================================================
#  ckpt_mark_done <key> [note]
#    Appended immediately (and flushed) so an abrupt kill cannot lose it.
# =============================================================================
ckpt_mark_done() {
    local key="$1"
    local note="${2-}"
    [[ -n "$CKPT_FILE" ]] || return 0
    ckpt_is_done "$key" && return 0
    printf '%s\n' "$key" >> "$CKPT_FILE" 2>/dev/null || true
    # Human-readable companion log (not used for resume decisions)
    printf '%s|%s|%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$key" "$note" \
        >> "${CKPT_FILE}.log" 2>/dev/null || true
    return 0
}

# =============================================================================
#  ckpt_count
# =============================================================================
ckpt_count() {
    [[ -n "$CKPT_FILE" && -f "$CKPT_FILE" ]] || { printf '0'; return 0; }
    # NOTE: `grep -c` prints 0 AND exits 1 on no match, so a `|| printf 0`
    # fallback would fire as well and emit "00". Capture first, default after.
    local n
    n="$(grep -c . "$CKPT_FILE" 2>/dev/null)" || n=0
    printf '%s' "${n:-0}"
}

# =============================================================================
#  ckpt_complete
#    Marks the run as fully finished. The checkpoint file is retained as
#    evidence but the resume pointer is cleared so the next run starts fresh.
# =============================================================================
ckpt_complete() {
    [[ -n "$CKPT_POINTER" && -f "$CKPT_POINTER" ]] && rm -f "$CKPT_POINTER" 2>/dev/null
    [[ -n "$CKPT_FILE" ]] && printf 'RUN_COMPLETED %s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "${CKPT_FILE}.log" 2>/dev/null
    return 0
}
