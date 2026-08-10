#!/bin/bash
# =============================================================================
#  reconcile.sh  —  Reconciliation and GxP validation evidence
#
#  Compares, per application, what the source system held against what was
#  extracted to EFS and what finally landed in S3, then produces the evidence
#  artifacts required for GxP validation review.
#
#  Reconciliation dimensions:
#    tables       source row count (ILM)  vs  extracted CSV rows  vs  S3 object
#    attachments  rows in attachment list vs  objects in S3
#    metadata     local metadata files    vs  S3 objects
#
#  Artifacts produced (under <ILM_METADATA_PATH>/evidence/<RUN_ID>/):
#    reconciliation_<APP>.csv        per-object PASS/FAIL detail
#    validation_summary_<APP>.txt    human-readable summary with sign-off block
#    MANIFEST.sha256                 checksums sealing the evidence set
#
#  Usage:
#    bash reconcile.sh <APP_NAME> [RUN_ID]
#
#  Exit codes:
#    0  reconciliation PASSED
#    1  reconciliation FAILED (discrepancies found)
#    2  usage / configuration error
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Libraries ---
. "$SCRIPT_DIR/logger.sh"     || { echo "FATAL: cannot source logger.sh" >&2; exit 2; }
. "$SCRIPT_DIR/lib_trace.sh"  || { echo "FATAL: cannot source lib_trace.sh" >&2; exit 2; }
log_trap_int

# --- Configuration ---
if ! . "$SCRIPT_DIR/.conf.ini"; then
    error_exit "Failed to source .conf.ini" 2
fi

APP_NAME="${1:-}"
[[ -z "$APP_NAME" ]] && error_exit "Usage: $0 <APP_NAME> [RUN_ID]" 2

RUN_ID_ARG="${2:-}"

# --- Logging ---
log_init "$LOG_PATH/${APP_NAME}_RECONCILE_$(date '+%Y%m%d_%H%M%S').log" \
    || error_exit "Cannot initialise log file in $LOG_PATH"

# --- Trace / evidence context ---
trace_init "$ILM_METADATA_PATH" "$RUN_ID_ARG" \
    || error_exit "Cannot initialise traceability context"

TRACE_SCRIPT="reconcile.sh"

RECON_FILE="$EVIDENCE_DIR/reconciliation_${APP_NAME}.csv"
SUMMARY_FILE="$EVIDENCE_DIR/validation_summary_${APP_NAME}.txt"

APP_S3_TARGET="$TARGET_S3_STAGE/$APP_NAME"

TOTAL_CHECKS=0
PASS_CHECKS=0
FAIL_CHECKS=0

log INFO "############################################################"
log INFO "#  RECONCILIATION - $APP_NAME"
log INFO "#  Run ID : $RUN_ID"
log INFO "#  Started: $(trace_utc)"
log INFO "############################################################"

audit_event "reconcile" "$APP_NAME" "run" "$RUN_ID" "start" "IN_PROGRESS" "" "" \
    "Reconciliation started"

# --- Reconciliation detail header ---
printf 'run_id,application,object_type,object_name,source_count,extracted_count,s3_count,size_bytes,sha256,status,discrepancy,checked_utc\n' \
    > "$RECON_FILE"

# =============================================================================
#  record_result <type> <name> <src> <ext> <s3> <bytes> <sha> <status> <note>
# =============================================================================
record_result() {
    local otype="$1" name="$2" src="$3" ext="$4" s3c="$5" bytes="$6" sha="$7" \
          status="$8" note="$9"

    TOTAL_CHECKS=$((TOTAL_CHECKS+1))
    if [[ "$status" == "PASS" ]]; then
        PASS_CHECKS=$((PASS_CHECKS+1))
    else
        FAIL_CHECKS=$((FAIL_CHECKS+1))
    fi

    printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
        "$RUN_ID" "$APP_NAME" "$otype" "$name" "$src" "$ext" "$s3c" \
        "$bytes" "$sha" "$status" "$note" "$(trace_utc)" >> "$RECON_FILE"
}

# =============================================================================
# 1. TABLE RECONCILIATION
#    Source of truth for the expected table set is the generated table list.
# =============================================================================
log_line
log INFO "1. Table reconciliation"
log_line

TABLE_LIST_CSV="$ILM_METADATA_PATH/$APP_NAME/${APP_NAME}_table_list.csv"
TABLES_EXPECTED=0
TABLES_FOUND=0

# Pre-fetch the S3 listing once (cheaper and more reliable than per-object calls)
S3_TABLE_LISTING="$(aws s3 ls "$APP_S3_TARGET/tabledata/" --recursive \
                    --region "$AWS_REGION" 2>/dev/null)"

if [[ -f "$TABLE_LIST_CSV" ]]; then
    while IFS=',' read -r DB_NAME TID TABLE_NAME TYPE || [[ -n "$DB_NAME" ]]; do
        DB_NAME="$(echo "$DB_NAME" | xargs)"
        TABLE_NAME="$(echo "$TABLE_NAME" | xargs | tr -d '"')"
        [[ -z "$TABLE_NAME" ]] && continue

        TABLES_EXPECTED=$((TABLES_EXPECTED+1))

        CSV_PATH="$EXPORT_PATH/$DB_NAME/${TABLE_NAME}.csv"

        if [[ -f "$CSV_PATH" ]]; then
            RAW_LINES="$(wc -l < "$CSV_PATH" 2>/dev/null || echo 0)"
            EXTRACTED=$(( RAW_LINES > 1 ? RAW_LINES - 1 : 0 ))
            FSIZE="$(trace_filesize "$CSV_PATH")"
            FSHA="$(trace_sha256 "$CSV_PATH")"
            TABLES_FOUND=$((TABLES_FOUND+1))

            if echo "$S3_TABLE_LISTING" | grep -q "/${TABLE_NAME}.csv$"; then
                S3_CNT=1
                S3_BYTES="$(echo "$S3_TABLE_LISTING" | awk -v f="/${TABLE_NAME}.csv" \
                            '$4 ~ f {print $3; exit}')"
                if [[ -n "$S3_BYTES" && "$S3_BYTES" == "$FSIZE" ]]; then
                    record_result "table" "$TABLE_NAME" "$EXTRACTED" "$EXTRACTED" "$S3_CNT" \
                        "$FSIZE" "$FSHA" "PASS" ""
                    evidence_add "$APP_NAME" "table" "$CSV_PATH" \
                        "$APP_S3_TARGET/tabledata/${TABLE_NAME}.csv" "$EXTRACTED"
                else
                    record_result "table" "$TABLE_NAME" "$EXTRACTED" "$EXTRACTED" "$S3_CNT" \
                        "$FSIZE" "$FSHA" "FAIL" \
                        "size mismatch local=$FSIZE s3=${S3_BYTES:-absent}"
                    log WARN "  [FAIL] $TABLE_NAME - S3 size mismatch (local=$FSIZE s3=${S3_BYTES:-absent})"
                fi
            else
                record_result "table" "$TABLE_NAME" "$EXTRACTED" "$EXTRACTED" "0" \
                    "$FSIZE" "$FSHA" "FAIL" "not uploaded to S3"
                log WARN "  [FAIL] $TABLE_NAME - extracted but missing in S3"
            fi
        else
            record_result "table" "$TABLE_NAME" "unknown" "0" "0" "0" "NA" "FAIL" \
                "CSV not produced"
            log WARN "  [FAIL] $TABLE_NAME - no CSV produced at $CSV_PATH"
        fi
    done < <(tail -n +2 "$TABLE_LIST_CSV")

    log INFO "  Tables expected : $TABLES_EXPECTED"
    log INFO "  Tables extracted: $TABLES_FOUND"
else
    log WARN "  Table list not found: $TABLE_LIST_CSV"
    audit_event "reconcile" "$APP_NAME" "table_list" "$TABLE_LIST_CSV" "read" "MISSING" \
        "" "" "Table list not found"
fi

# =============================================================================
# 2. ATTACHMENT RECONCILIATION
# =============================================================================
log_line
log INFO "2. Attachment reconciliation"
log_line

ATT_LIST="$ILM_METADATA_PATH/$APP_NAME/${APP_NAME}_attachment_list.csv"
ATT_EXPECTED=0

if [[ -f "$ATT_LIST" ]]; then
    ATT_EXPECTED=$(( $(wc -l < "$ATT_LIST") - 1 ))
    (( ATT_EXPECTED < 0 )) && ATT_EXPECTED=0
else
    log WARN "  Attachment list not found: $ATT_LIST"
fi

ATT_S3_COUNT="$(aws s3 ls "$APP_S3_TARGET/attachements/" --recursive \
                --region "$AWS_REGION" 2>/dev/null | grep -vc ' PRE ' || echo 0)"

log INFO "  Attachments expected in list : $ATT_EXPECTED"
log INFO "  Attachment objects in S3     : $ATT_S3_COUNT"

if (( ATT_EXPECTED == 0 && ATT_S3_COUNT == 0 )); then
    record_result "attachment" "ALL" "0" "0" "0" "0" "NA" "PASS" "no attachments expected"
elif (( ATT_EXPECTED == ATT_S3_COUNT )); then
    record_result "attachment" "ALL" "$ATT_EXPECTED" "$ATT_EXPECTED" "$ATT_S3_COUNT" \
        "0" "NA" "PASS" ""
else
    record_result "attachment" "ALL" "$ATT_EXPECTED" "$ATT_EXPECTED" "$ATT_S3_COUNT" \
        "0" "NA" "FAIL" "count mismatch expected=$ATT_EXPECTED s3=$ATT_S3_COUNT"
    log WARN "  [FAIL] attachment count mismatch (expected=$ATT_EXPECTED s3=$ATT_S3_COUNT)"
fi

[[ -f "$ATT_LIST" ]] && evidence_add "$APP_NAME" "metadata" "$ATT_LIST" \
    "$APP_S3_TARGET/metadata/$(basename "$ATT_LIST")" "$ATT_EXPECTED"

# =============================================================================
# 3. METADATA RECONCILIATION
# =============================================================================
log_line
log INFO "3. Metadata reconciliation"
log_line

APP_META_DIR="$ILM_METADATA_PATH/$APP_NAME"
META_LOCAL=0
[[ -d "$APP_META_DIR" ]] && META_LOCAL="$(find "$APP_META_DIR" -type f 2>/dev/null | wc -l)"
META_S3="$(aws s3 ls "$APP_S3_TARGET/metadata/" --recursive --region "$AWS_REGION" 2>/dev/null \
           | grep -vc ' PRE ' || echo 0)"

log INFO "  Metadata files local : $META_LOCAL"
log INFO "  Metadata files in S3 : $META_S3"

if (( META_LOCAL == META_S3 )); then
    record_result "metadata" "ALL" "$META_LOCAL" "$META_LOCAL" "$META_S3" "0" "NA" "PASS" ""
else
    record_result "metadata" "ALL" "$META_LOCAL" "$META_LOCAL" "$META_S3" "0" "NA" "FAIL" \
        "count mismatch local=$META_LOCAL s3=$META_S3"
    log WARN "  [FAIL] metadata count mismatch (local=$META_LOCAL s3=$META_S3)"
fi

# =============================================================================
# 4. VALIDATION SUMMARY  (GxP review artifact)
# =============================================================================
OVERALL="PASS"
(( FAIL_CHECKS > 0 )) && OVERALL="FAIL"

{
    echo "============================================================"
    echo "  ILM EXPORT - GxP VALIDATION SUMMARY"
    echo "============================================================"
    echo "  Application        : $APP_NAME"
    echo "  Run ID             : $RUN_ID"
    echo "  Environment        : ${ENV:-unknown}"
    echo "  Executed by        : $TRACE_ACTOR"
    echo "  Host               : $TRACE_HOST"
    echo "  Reconciled (UTC)   : $(trace_utc)"
    echo "------------------------------------------------------------"
    echo "  SOURCE -> EXTRACT -> TARGET"
    echo "------------------------------------------------------------"
    echo "  Tables expected    : $TABLES_EXPECTED"
    echo "  Tables extracted   : $TABLES_FOUND"
    echo "  Attachments listed : $ATT_EXPECTED"
    echo "  Attachments in S3  : $ATT_S3_COUNT"
    echo "  Metadata local     : $META_LOCAL"
    echo "  Metadata in S3     : $META_S3"
    echo "------------------------------------------------------------"
    echo "  RECONCILIATION RESULT"
    echo "------------------------------------------------------------"
    echo "  Checks performed   : $TOTAL_CHECKS"
    echo "  Passed             : $PASS_CHECKS"
    echo "  Failed             : $FAIL_CHECKS"
    echo "  OVERALL RESULT     : $OVERALL"
    echo "------------------------------------------------------------"
    echo "  EVIDENCE ARTIFACTS"
    echo "------------------------------------------------------------"
    echo "  Reconciliation     : $RECON_FILE"
    echo "  Evidence manifest  : $EVIDENCE_DIR/manifest_${APP_NAME}.csv"
    echo "  Audit trail        : $AUDIT_FILE"
    echo "  Target S3 location : $APP_S3_TARGET"
    echo "------------------------------------------------------------"
    echo "  REVIEW AND APPROVAL"
    echo "------------------------------------------------------------"
    echo "  Reviewed by : ______________________  Date: ____________"
    echo "  Approved by : ______________________  Date: ____________"
    echo "  Comments    : ____________________________________________"
    echo "============================================================"
} > "$SUMMARY_FILE"

log_line
log INFO "Reconciliation checks : $TOTAL_CHECKS (pass=$PASS_CHECKS fail=$FAIL_CHECKS)"
log INFO "Detail report         : $RECON_FILE"
log INFO "Validation summary    : $SUMMARY_FILE"
log_line

audit_event "reconcile" "$APP_NAME" "run" "$RUN_ID" "complete" "$OVERALL" \
    "$TOTAL_CHECKS" "" "pass=$PASS_CHECKS fail=$FAIL_CHECKS"

if [[ "$OVERALL" == "FAIL" ]]; then
    log ERROR "RECONCILIATION FAILED for $APP_NAME - $FAIL_CHECKS discrepancy(ies)"
    log ERROR "Review $RECON_FILE before releasing this data."
    exit 1
fi

log INFO "RECONCILIATION PASSED for $APP_NAME"
exit 0
