#!/bin/bash
# =============================================================================
#  logger.sh  —  Universal logging framework for the ILM export scripts
#
#  Usage:
#      SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#      . "$SCRIPT_DIR/logger.sh"
#
#      log_init "/efs/ILM_EXPORT/logs/myscript_20260810.log"   # optional
#      log INFO "message"          # legacy-compatible form
#      log_info "message"          # convenience form
#      log_warn "something odd"
#      error_exit "unrecoverable"  # logs FATAL and exits 1
#
#  Behaviour:
#    - If log_init is not called (or LOG_FILE is empty) output goes to the
#      console ONLY. Nothing is ever written to the current directory.
#    - Console output is colourised when attached to a TTY; the log file
#      always receives plain text.
#    - WARN / ERROR / FATAL are written to stderr, everything else to stdout.
#
#  Environment variables:
#    LOG_FILE   Path of the log file. Empty = console only.
#    LOG_LEVEL  Minimum level to emit: DEBUG | INFO | WARN | ERROR | FATAL
#               (default INFO)
#    LOG_COLOR  auto (default) | always | never
#
#  Requires bash 4.0+.
# =============================================================================

# --- Include guard: safe to source multiple times ---------------------------
[[ -n "${__ILM_LOGGER_SOURCED:-}" ]] && return 0
__ILM_LOGGER_SOURCED=1

# --- Defaults (respect values already set by the caller) --------------------
: "${LOG_FILE:=}"
: "${LOG_LEVEL:=INFO}"
: "${LOG_COLOR:=auto}"
: "${LOG_TS_FORMAT:=%Y-%m-%d %H:%M:%S}"

# --- Level -> numeric severity ----------------------------------------------
__log_severity() {
    case "${1^^}" in
        DEBUG)        echo 10 ;;
        INFO|STEP)    echo 20 ;;
        WARN|WARNING) echo 30 ;;
        ERROR)        echo 40 ;;
        FATAL)        echo 50 ;;
        *)            echo 20 ;;
    esac
}

# --- Colour support ----------------------------------------------------------
__log_use_color() {
    case "$LOG_COLOR" in
        always) return 0 ;;
        never)  return 1 ;;
        *)      [[ -t 1 && -z "${NO_COLOR:-}" ]] ;;
    esac
}

__log_color_for() {
    case "${1^^}" in
        DEBUG) printf '\033[2m'    ;;  # dim
        INFO)  printf '\033[0m'    ;;  # default
        STEP)  printf '\033[1;34m' ;;  # bold blue
        WARN)  printf '\033[0;33m' ;;  # yellow
        ERROR) printf '\033[0;31m' ;;  # red
        FATAL) printf '\033[1;31m' ;;  # bold red
        *)     printf '\033[0m'    ;;
    esac
}

# =============================================================================
#  log_init [logfile]
#    Creates the log file (and its directory) and routes output to it.
#    Called with no argument, or an empty string, logging stays console-only.
#    Returns non-zero if the file cannot be created.
# =============================================================================
log_init() {
    local file="${1:-}"

    if [[ -z "$file" ]]; then
        LOG_FILE=""
        return 0
    fi

    local dir
    dir="$(dirname "$file")"

    if ! mkdir -p "$dir" 2>/dev/null; then
        printf '[%s] [ERROR] Cannot create log directory: %s\n' \
            "$(date "+$LOG_TS_FORMAT")" "$dir" >&2
        return 1
    fi

    if ! touch "$file" 2>/dev/null; then
        printf '[%s] [ERROR] Cannot create log file: %s\n' \
            "$(date "+$LOG_TS_FORMAT")" "$file" >&2
        return 1
    fi

    chmod 664 "$file" 2>/dev/null || true
    LOG_FILE="$file"
    return 0
}

# =============================================================================
#  log <LEVEL> <message...>
#    Core logging function. Kept signature-compatible with the previous
#    per-script loggers so existing calls keep working unchanged.
# =============================================================================
log() {
    local level="${1:-INFO}"; shift
    local msg="$*"

    # Threshold check
    local sev min
    sev=$(__log_severity "$level")
    min=$(__log_severity "$LOG_LEVEL")
    (( sev < min )) && return 0

    local ts line
    ts="$(date "+$LOG_TS_FORMAT")"
    line="$(printf '[%s] [%-5s] %b' "$ts" "${level^^}" "$msg")"

    # Console (stderr for WARN and above, so errors survive stdout redirection)
    local stream=1
    (( sev >= 30 )) && stream=2

    if __log_use_color; then
        local color reset
        color="$(__log_color_for "$level")"
        reset=$'\033[0m'
        if (( stream == 2 )); then
            printf '%s%s%s\n' "$color" "$line" "$reset" >&2
        else
            printf '%s%s%s\n' "$color" "$line" "$reset"
        fi
    else
        if (( stream == 2 )); then
            printf '%s\n' "$line" >&2
        else
            printf '%s\n' "$line"
        fi
    fi

    # Log file (plain text, never coloured)
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
    fi

    return 0
}

# --- Convenience wrappers ----------------------------------------------------
log_debug() { log DEBUG "$@"; }
log_info()  { log INFO  "$@"; }
log_warn()  { log WARN  "$@"; }
log_error() { log ERROR "$@"; }
log_step()  { log STEP  "$@"; }

# --- Separators / banners ----------------------------------------------------
log_line() {
    log "${1:-INFO}" "------------------------------------------------------------"
}

log_banner() {
    log INFO "############################################################"
    log INFO "#  $*"
    log INFO "############################################################"
}

# =============================================================================
#  step_banner <step> <title>
#  step_complete <step> <start_epoch>
#    Used by ilm_pipeline.sh for step-level traceability.
# =============================================================================
step_banner() {
    local step="$1"; shift
    log STEP "============================================================"
    log STEP "  STEP ${step} : $*"
    log STEP "============================================================"
}

step_complete() {
    local step="$1"; local step_start="${2:-$(date +%s)}"
    local duration=$(( $(date +%s) - step_start ))
    log STEP "  [STEP ${step} COMPLETE] Duration: ${duration}s"
    log STEP "------------------------------------------------------------"
}

# =============================================================================
#  Error handling
#    error_exit <message> [exit_code]   - logs FATAL and terminates
#    warn <message>                     - logs WARN and continues
# =============================================================================
error_exit() {
    local msg="$1"; local code="${2:-1}"
    log FATAL "$msg"
    [[ -n "$LOG_FILE" ]] && log FATAL "Aborted. Log: $LOG_FILE"
    exit "$code"
}

warn() { log WARN "$@"; }

# =============================================================================
#  log_trap_int [message]
#    Installs a SIGINT handler that logs cleanly before exiting with 130.
# =============================================================================
log_trap_int() {
    local msg="${1:-Script interrupted by user (Ctrl+C). Exiting.}"
    # shellcheck disable=SC2064
    trap "log ERROR \"$msg\"; exit 130" INT
}
