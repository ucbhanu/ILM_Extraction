#!/bin/bash
# =============================================================================
#  lib_trace.sh  —  Traceability, audit trail and GxP evidence
#
#  Provides:
#    trace_init <base_dir> [run_id]  Establish RUN_ID, audit trail, evidence dir
#    audit_event <step> <app> <object_type> <object_id> <action> <status> \
#                <count> <bytes> <message>
#                                    Append one immutable audit-trail record
#    evidence_add <app> <type> <path> <s3_uri> <row_count>
#                                    Record an artifact with size + SHA-256
#    evidence_finalize               Seal manifests (checksums + read-only)
#    trace_sha256 <file>             SHA-256 of a file
#
#  Audit trail design (21 CFR Part 11 / GxP oriented):
#    - Append-only, never rewritten or deleted by the pipeline
#    - Computer-generated UTC timestamps, independent of local time zone
#    - Records who (actor), what (action/object), when (UTC), where (host,
#      script) and the outcome (status) of every operation
#    - Monotonic event_seq so gaps in the record are detectable
#
#  Requires logger.sh to be sourced first.
# =============================================================================

[[ -n "${__ILM_TRACE_SOURCED:-}" ]] && return 0
__ILM_TRACE_SOURCED=1

: "${RUN_ID:=}"
: "${AUDIT_DIR:=}"
: "${EVIDENCE_DIR:=}"
: "${AUDIT_FILE:=}"
: "${TRACE_SCRIPT:=${0##*/}}"

__AUDIT_SEQ=0
TRACE_ACTOR="$(whoami 2>/dev/null || echo unknown)@$(hostname 2>/dev/null || echo unknown)"
TRACE_HOST="$(hostname 2>/dev/null || echo unknown)"

# --- UTC timestamp -----------------------------------------------------------
trace_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# --- SHA-256 (portable) ------------------------------------------------------
trace_sha256() {
    local f="$1"
    [[ -f "$f" ]] || { printf 'NA'; return 0; }
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
    else
        printf 'NA'
    fi
}

# --- CSV field escaping (RFC 4180: double the quotes) ------------------------
__csv() {
    local s="${1-}"
    s="${s//\"/\"\"}"
    printf '"%s"' "$s"
}

# --- File size in bytes ------------------------------------------------------
trace_filesize() {
    local f="$1"
    [[ -f "$f" ]] || { printf '0'; return 0; }
    stat -c '%s' "$f" 2>/dev/null || stat -f '%z' "$f" 2>/dev/null || printf '0'
}

# =============================================================================
#  trace_new_run_id
#    Unique, human-readable, sortable run identifier.
#    Format: <env>_<utc timestamp>_<host>_<pid>
# =============================================================================
trace_new_run_id() {
    local host
    host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)"
    printf '%s_%s_%s_%s' "${ENV:-ilm}" "$(date -u '+%Y%m%dT%H%M%SZ')" "$host" "$$"
}

# =============================================================================
#  trace_init <base_dir> [run_id]
#    Creates <base>/audit and <base>/evidence/<RUN_ID>.
#    Pass an existing run_id to resume a previous run (audit trail is appended,
#    never truncated).
# =============================================================================
trace_init() {
    local base="$1"
    local rid="${2:-}"

    if [[ -z "$base" ]]; then
        log ERROR "trace_init: base directory is required"
        return 1
    fi

    RUN_ID="${rid:-$(trace_new_run_id)}"
    AUDIT_DIR="$base/audit"
    EVIDENCE_DIR="$base/evidence/$RUN_ID"

    if ! mkdir -p "$AUDIT_DIR" "$EVIDENCE_DIR"; then
        log ERROR "trace_init: cannot create audit/evidence directories under $base"
        return 1
    fi

    AUDIT_FILE="$AUDIT_DIR/audit_trail_${RUN_ID}.csv"

    if [[ ! -f "$AUDIT_FILE" ]]; then
        printf 'run_id,event_seq,event_utc,actor,host,script,step,application,object_type,object_id,action,status,record_count,size_bytes,message\n' \
            > "$AUDIT_FILE" || return 1
        __AUDIT_SEQ=0
    else
        # Resuming: continue the sequence where the previous attempt stopped
        __AUDIT_SEQ=$(( $(wc -l < "$AUDIT_FILE") - 1 ))
        (( __AUDIT_SEQ < 0 )) && __AUDIT_SEQ=0
    fi

    export RUN_ID AUDIT_DIR EVIDENCE_DIR AUDIT_FILE
    return 0
}

# =============================================================================
#  audit_event <step> <app> <object_type> <object_id> <action> <status> \
#              <count> <bytes> <message>
#    All arguments are optional (pass "" to skip) but order is fixed.
# =============================================================================
audit_event() {
    [[ -z "$AUDIT_FILE" ]] && return 0

    local step="${1-}" app="${2-}" otype="${3-}" oid="${4-}" action="${5-}" \
          status="${6-}" count="${7-}" bytes="${8-}" msg="${9-}"

    __AUDIT_SEQ=$(( __AUDIT_SEQ + 1 ))

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(__csv "$RUN_ID")" \
        "$__AUDIT_SEQ" \
        "$(__csv "$(trace_utc)")" \
        "$(__csv "$TRACE_ACTOR")" \
        "$(__csv "$TRACE_HOST")" \
        "$(__csv "$TRACE_SCRIPT")" \
        "$(__csv "$step")" \
        "$(__csv "$app")" \
        "$(__csv "$otype")" \
        "$(__csv "$oid")" \
        "$(__csv "$action")" \
        "$(__csv "$status")" \
        "$(__csv "$count")" \
        "$(__csv "$bytes")" \
        "$(__csv "$msg")" \
        >> "$AUDIT_FILE" 2>/dev/null || true
}

# =============================================================================
#  evidence_add <app> <type> <path> <s3_uri> <row_count>
#    Records one produced artifact in the per-application evidence manifest.
#    type: table | attachment | metadata | log
# =============================================================================
evidence_add() {
    [[ -z "$EVIDENCE_DIR" ]] && return 0

    local app="${1-}" otype="${2-}" path="${3-}" s3uri="${4-}" rows="${5-}"
    local manifest="$EVIDENCE_DIR/manifest_${app}.csv"

    if [[ ! -f "$manifest" ]]; then
        printf 'run_id,application,artifact_type,file_name,local_path,s3_uri,row_count,size_bytes,sha256,created_utc,created_by\n' \
            > "$manifest" || return 1
    fi

    local size sha
    size="$(trace_filesize "$path")"
    sha="$(trace_sha256 "$path")"

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(__csv "$RUN_ID")" \
        "$(__csv "$app")" \
        "$(__csv "$otype")" \
        "$(__csv "$(basename "$path")")" \
        "$(__csv "$path")" \
        "$(__csv "$s3uri")" \
        "$(__csv "$rows")" \
        "$(__csv "$size")" \
        "$(__csv "$sha")" \
        "$(__csv "$(trace_utc)")" \
        "$(__csv "$TRACE_ACTOR")" \
        >> "$manifest" 2>/dev/null || true
}

# =============================================================================
#  evidence_finalize
#    Seals the evidence set: writes SHA-256 of every manifest plus the audit
#    trail into MANIFEST.sha256, then makes the artifacts read-only so the
#    evidence cannot be silently altered after the run.
# =============================================================================
evidence_finalize() {
    [[ -z "$EVIDENCE_DIR" ]] && return 0

    local sealfile="$EVIDENCE_DIR/MANIFEST.sha256"
    : > "$sealfile" || return 1

    local f
    for f in "$EVIDENCE_DIR"/manifest_*.csv "$EVIDENCE_DIR"/reconciliation_*.csv \
             "$EVIDENCE_DIR"/validation_summary_*.txt "$AUDIT_FILE"; do
        [[ -f "$f" ]] || continue
        printf '%s  %s\n' "$(trace_sha256 "$f")" "$(basename "$f")" >> "$sealfile"
    done

    printf 'sealed_utc=%s\nsealed_by=%s\nrun_id=%s\n' \
        "$(trace_utc)" "$TRACE_ACTOR" "$RUN_ID" >> "$sealfile"

    chmod 444 "$EVIDENCE_DIR"/*.csv "$EVIDENCE_DIR"/*.txt "$sealfile" 2>/dev/null || true
    chmod 444 "$AUDIT_FILE" 2>/dev/null || true

    log INFO "Evidence sealed: $sealfile"
    return 0
}
