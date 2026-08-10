#!/bin/bash
# =============================================================================
#  ilm_pipeline.sh  —  ILM Full Export Pipeline
#
#  Description:
#    Orchestrates the end-to-end ILM data export process with full error
#    handling, step-level traceability, per-application metadata reporting,
#    and automated upload of all data, metadata, and logs to S3.
#
#  Pipeline Steps:
#    1.  List all ILM applications
#          → Runs: 01_applications_list.sh
#          → Output: $ILM_METADATA_PATH/application_list.txt
#
#    2.  Generate table lists for all applications
#          → Runs: 02_app_table_list.sh
#          → Output: $ILM_METADATA_PATH/{APP}/{APP}_table_list.csv (per app)
#
#    ── Per-Application Loop (steps 3–7) ──────────────────────────────────
#
#    3.  [Per App] Generate attachment list from DB (AM_ATTACHMENTS)
#          → Runs: inline ssasql query
#          → Output: $ILM_METADATA_PATH/{APP}/{APP}_attachment_list.csv
#
#    4.  [Per App] Extract attachments via Lambda → S3
#          → Runs: 03_app_attachement_extraction.sh
#          → Output: s3://$EXPORT_LOC/{APP}/...
#
#    5.  [Per App] Extract tables to CSV with headers
#          → Runs: 04_app_table_extraction.sh
#          → Output: $EXPORT_PATH/{DB}/{TABLE}.csv
#
#    6.  [Per App] Generate metadata report
#          → Output: $ILM_METADATA_PATH/{APP}/{APP}_metadata_{ts}.csv
#          → Columns: srno, filename, type, count, size_bytes,
#                     source_path, extracted_path, created_date, created_by
#
#    7.  [Per App] Copy application data, metadata & logs to S3
#          → 7a: table CSVs    → s3://{TARGET_S3_STAGE}/{APP}/tabledata/
#          → 7b: attachments   → s3://{TARGET_S3_STAGE}/{APP}/attachements/
#          → 7c: metadata      → s3://{TARGET_S3_STAGE}/{APP}/metadata/
#          → 7d: app logs      → s3://{TARGET_S3_STAGE}/{APP}/logs/
#
#    ── Post-Loop ─────────────────────────────────────────────────────────
#
#    7G. Copy global ILM metadata & pipeline logs to S3
#          → ilm_metadata → s3://{TARGET_S3_STAGE}/ilm_metadata/
#          → pipeline logs → s3://{TARGET_S3_STAGE}/pipeline_logs/
#
#  Error Handling:
#    - FATAL  : stops the pipeline (config, missing scripts, step 1/2 failure)
#    - WARN   : logs and continues (per-app extraction / copy errors)
#    - Ctrl+C : trapped and logged cleanly
#
#  Usage:
#    bash ilm_pipeline.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_START=$(date +%s)
CREATED_BY="$(whoami)@$(hostname)"

# =============================================================================
# 0. LOGGER AND SUPPORT LIBRARIES
# =============================================================================
. "$SCRIPT_DIR/logger.sh"         || { echo "[FATAL] cannot source logger.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib_trace.sh"      || { echo "[FATAL] cannot source lib_trace.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib_checkpoint.sh" || { echo "[FATAL] cannot source lib_checkpoint.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib_progress.sh"   || { echo "[FATAL] cannot source lib_progress.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib_s3.sh"         || { echo "[FATAL] cannot source lib_s3.sh" >&2; exit 1; }

TRACE_SCRIPT="ilm_pipeline.sh"

# =============================================================================
# 0. ARGUMENTS
#      --resume   continue the last incomplete run, skipping completed work
#      --fresh    ignore any previous checkpoint and start a new run
# =============================================================================
RESUME_MODE=false
for arg in "$@"; do
    case "$arg" in
        --resume) RESUME_MODE=true ;;
        --fresh)  RESUME_MODE=false ;;
        -h|--help)
            echo "Usage: bash ilm_pipeline.sh [--resume|--fresh]"
            exit 0 ;;
        *)
            echo "[FATAL] Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

# =============================================================================
# 0. SOURCE CONFIGURATION
# =============================================================================
if ! . "$SCRIPT_DIR/.conf.ini"; then
    echo "[FATAL] Failed to source .conf.ini" >&2; exit 1
fi
if ! source "$IDV_HOME/ssaenv.sh"; then
    echo "[FATAL] Failed to source $IDV_HOME/ssaenv.sh" >&2; exit 1
fi

# =============================================================================
# 0. PIPELINE LOG SETUP
# =============================================================================
PIPELINE_LOG_DIR="$LOG_PATH/pipeline"
if ! mkdir -p "$PIPELINE_LOG_DIR"; then
    echo "[FATAL] Cannot create pipeline log directory: $PIPELINE_LOG_DIR" >&2; exit 1
fi
chmod 766 "$PIPELINE_LOG_DIR"

LOG_TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
PIPELINE_LOG="$PIPELINE_LOG_DIR/ilm_pipeline_${LOG_TIMESTAMP}.log"

log_init "$PIPELINE_LOG" || { echo "[FATAL] Cannot create $PIPELINE_LOG" >&2; exit 1; }

# Export LOG_FILE so sub-scripts that honour this variable append to it too
export LOG_FILE="$PIPELINE_LOG"

# =============================================================================
# 0. TRACEABILITY AND RESTARTABILITY
# =============================================================================
CKPT_ROOT="$ILM_METADATA_PATH/checkpoints"
RESUME_RUN_ID=""

if $RESUME_MODE; then
    RESUME_RUN_ID="$(ckpt_last_run_id "$CKPT_ROOT")"
    if [[ -n "$RESUME_RUN_ID" ]]; then
        log INFO "Resuming previous run: $RESUME_RUN_ID"
    else
        log WARN "--resume requested but no incomplete run found; starting a new run"
    fi
fi

trace_init "$ILM_METADATA_PATH" "$RESUME_RUN_ID" \
    || { echo "[FATAL] Cannot initialise traceability context" >&2; exit 1; }
ckpt_init "$CKPT_ROOT" "$RUN_ID" \
    || { echo "[FATAL] Cannot initialise checkpoint context" >&2; exit 1; }

RESUMED_UNITS=$(ckpt_count)

# =============================================================================
# FUNCTIONS
# =============================================================================
# log / step_banner / step_complete / error_exit / warn come from logger.sh

# --- Fail the run, recording the reason in the audit trail ------------------
pipeline_abort() {
    audit_event "pipeline" "" "run" "$RUN_ID" "abort" "FAILED" "" "" "$1"
    error_exit "$1"
}

# --- Trap Ctrl+C ---
trap 'audit_event "pipeline" "" "run" "$RUN_ID" "interrupt" "ABORTED" "" "" "SIGINT received"; log "FATAL" "Pipeline interrupted by user (Ctrl+C). Resume with: bash ilm_pipeline.sh --resume"; exit 130' INT

# =============================================================================
# 0. VALIDATE REQUIRED SCRIPTS
# =============================================================================
REQUIRED_SCRIPTS=(
    "01_applications_list.sh"
    "02_app_table_list.sh"
    "03_app_attachement_extraction.sh"
    "04_app_table_extraction.sh"
    "reconcile.sh"
)
for s in "${REQUIRED_SCRIPTS[@]}"; do
    [[ -f "$SCRIPT_DIR/$s" ]] || pipeline_abort "Required script not found: $SCRIPT_DIR/$s"
done

# =============================================================================
# 0. PIPELINE HEADER
# =============================================================================
APP_LIST_FILE="$ILM_METADATA_PATH/application_list.txt"
PIPELINE_FILE_COUNT=0
APP_COUNTER=0
APPS_SKIPPED=0
APPS_FAILED=0
RECON_FAILED=0

log "INFO" "################################################################"
log "INFO" "#        ILM FULL EXPORT PIPELINE — STARTED                   #"
log "INFO" "################################################################"
log "INFO" "  Run ID      : $RUN_ID"
log "INFO" "  Mode        : $( $RESUME_MODE && echo 'RESUME' || echo 'FRESH' )"
log "INFO" "  Started By  : $CREATED_BY"
log "INFO" "  Started At  : $(date '+%Y-%m-%d %H:%M:%S')  ($(trace_utc))"
log "INFO" "  Script Dir  : $SCRIPT_DIR"
log "INFO" "  Export Path : $EXPORT_PATH"
log "INFO" "  Metadata    : $ILM_METADATA_PATH"
log "INFO" "  Pipeline Log: $PIPELINE_LOG"
log "INFO" "  Audit Trail : $AUDIT_FILE"
log "INFO" "  Evidence Dir: $EVIDENCE_DIR"
log "INFO" "  Checkpoint  : $CKPT_FILE"
log "INFO" "  Resumed Work: $RESUMED_UNITS unit(s) already complete"
log "INFO" "################################################################"

audit_event "pipeline" "" "run" "$RUN_ID" "start" "IN_PROGRESS" "" "" \
    "Pipeline started by $CREATED_BY (resume=$RESUME_MODE)"

# =============================================================================
# STEP 1 — List ILM Applications
#           Output: $ILM_METADATA_PATH/application_list.txt
# =============================================================================
STEP1_START=$(date +%s)
step_banner 1 "List ILM Applications"

if ckpt_is_done "GLOBAL|applications_list"; then
    log "INFO" "[RESUME] Step 1 already completed — skipping"
    audit_event "step1" "" "script" "01_applications_list.sh" "skip" "SKIPPED" "" "" \
        "Already completed in this run"
else
    log "INFO" "Running: 01_applications_list.sh"
    if ! bash "$SCRIPT_DIR/01_applications_list.sh"; then
        audit_event "step1" "" "script" "01_applications_list.sh" "execute" "FAILED" "" "" \
            "Sub-script returned non-zero"
        pipeline_abort "01_applications_list.sh failed. Check sub-script output above."
    fi
    ckpt_mark_done "GLOBAL|applications_list" "step 1"
    audit_event "step1" "" "script" "01_applications_list.sh" "execute" "SUCCESS" "" "" \
        "Application list generated"
fi

[[ -f "$APP_LIST_FILE" ]] || pipeline_abort "Application list not found after step 1: $APP_LIST_FILE"
TOTAL_APPS=$(grep -c . "$APP_LIST_FILE" || true)
log "INFO" "Total applications found: $TOTAL_APPS"
log "INFO" "Application list : $APP_LIST_FILE"
audit_event "step1" "" "application_list" "$APP_LIST_FILE" "verify" "SUCCESS" \
    "$TOTAL_APPS" "$(trace_filesize "$APP_LIST_FILE")" "Applications discovered"
step_complete 1 $STEP1_START

# =============================================================================
# STEP 2 — Generate Table Lists for All Applications
#           Output: $ILM_METADATA_PATH/{APP}/{APP}_table_list.csv
# =============================================================================
STEP2_START=$(date +%s)
step_banner 2 "Generate Table Lists (all applications)"

if ckpt_is_done "GLOBAL|table_lists"; then
    log "INFO" "[RESUME] Step 2 already completed — skipping"
    audit_event "step2" "" "script" "02_app_table_list.sh" "skip" "SKIPPED" "" "" \
        "Already completed in this run"
else
    log "INFO" "Running: 02_app_table_list.sh"
    if ! bash "$SCRIPT_DIR/02_app_table_list.sh"; then
        audit_event "step2" "" "script" "02_app_table_list.sh" "execute" "FAILED" "" "" \
            "Sub-script returned non-zero"
        pipeline_abort "02_app_table_list.sh failed. Check sub-script output above."
    fi
    ckpt_mark_done "GLOBAL|table_lists" "step 2"
    audit_event "step2" "" "script" "02_app_table_list.sh" "execute" "SUCCESS" "" "" \
        "Table lists generated"
fi
step_complete 2 $STEP2_START

# =============================================================================
# PROGRESS TRACKING across the per-application loop
# =============================================================================
progress_init "$TOTAL_APPS" "Applications"

# =============================================================================
# STEPS 3–7 — Per-Application Processing Loop
# =============================================================================
while IFS= read -r APP_NAME || [[ -n "$APP_NAME" ]]; do

    # Skip blank lines
    APP_NAME=$(echo "$APP_NAME" | xargs)
    [[ -z "$APP_NAME" ]] && continue

    ((APP_COUNTER++))
    APP_LOOP_START=$(date +%s)

    # --- Visual separation so each application is easy to spot -------------
    log "INFO" ""
    log "INFO" ""
    log "INFO" ""
    log APP "================================================================"
    log APP "================================================================"
    log APP "    APPLICATION [$APP_COUNTER / $TOTAL_APPS] : $APP_NAME"
    log APP "    Run ID: $RUN_ID"
    log APP "================================================================"
    log APP "================================================================"
    log "INFO" ""

    # --- Pause so the operator can follow progress on screen ---------------
    sleep "${APP_PAUSE_SECONDS:-3}"

    audit_event "application" "$APP_NAME" "application" "$APP_NAME" "start" "IN_PROGRESS" \
        "" "" "Application $APP_COUNTER of $TOTAL_APPS"

    # --- Restartability: skip an application that already finished ----------
    if ckpt_is_done "$APP_NAME|COMPLETE"; then
        log "INFO" "[RESUME] $APP_NAME already completed in this run — skipping"
        audit_event "application" "$APP_NAME" "application" "$APP_NAME" "skip" "SKIPPED" \
            "" "" "Completed in an earlier attempt of run $RUN_ID"
        ((APPS_SKIPPED++))
        progress_step "$APP_NAME (skipped)"
        continue
    fi

    # --- Paths ---
    APP_META_DIR="$ILM_METADATA_PATH/$APP_NAME"
    # Table list and attachment list both live under $ILM_METADATA_PATH/{APP}/
    # NOTE: 03_app_attachement_extraction.sh derives APP_NAME from dirname of the
    # attachment list, so the CSV MUST be placed inside a directory named $APP_NAME
    TABLE_LIST_CSV="$APP_META_DIR/${APP_NAME}_table_list.csv"
    APP_ATT_LIST="$APP_META_DIR/${APP_NAME}_attachment_list.csv"
    APP_EXPORT_DIR="$EXPORT_PATH/$APP_NAME"

    # --- Create per-app metadata directory ---
    if ! mkdir -p "$APP_META_DIR"; then
        warn "[$APP_NAME] Failed to create metadata dir $APP_META_DIR — skipping application"
        audit_event "application" "$APP_NAME" "directory" "$APP_META_DIR" "create" "FAILED" \
            "" "" "Cannot create metadata directory"
        ((APPS_FAILED++))
        progress_step "$APP_NAME (failed)"
        continue
    fi
    chmod 766 "$APP_META_DIR"

    # --- Validate table list ---
    if [[ ! -f "$TABLE_LIST_CSV" ]]; then
        warn "[$APP_NAME] Table list CSV not found: $TABLE_LIST_CSV — skipping application"
        audit_event "application" "$APP_NAME" "table_list" "$TABLE_LIST_CSV" "read" "FAILED" \
            "" "" "Table list missing"
        ((APPS_FAILED++))
        progress_step "$APP_NAME (failed)"
        continue
    fi
    TABLE_TOTAL=$(( $(wc -l < "$TABLE_LIST_CSV") - 1 ))
    log "INFO" "[$APP_NAME] Table list : $TABLE_LIST_CSV ($TABLE_TOTAL table(s))"
    audit_event "application" "$APP_NAME" "table_list" "$TABLE_LIST_CSV" "read" "SUCCESS" \
        "$TABLE_TOTAL" "$(trace_filesize "$TABLE_LIST_CSV")" "Table list validated"

    # =========================================================================
    # STEP 3 — Generate Attachment List from DB (AM_ATTACHMENTS)
    #           Output: $ILM_METADATA_PATH/{APP}/{APP}_attachment_list.csv
    # =========================================================================
    STEP3_START=$(date +%s)
    step_banner 3 "[$APP_NAME] Generate Attachment List"

    ATT_STEP_OK=true
    ATT_RAW_TMP="$APP_META_DIR/${APP_NAME}_att_query.tmp"

    if ckpt_is_done "$APP_NAME|attachment_list" && [[ -f "$APP_ATT_LIST" ]]; then
        log "INFO" "[RESUME] [$APP_NAME] Attachment list already generated — skipping"
        audit_event "step3" "$APP_NAME" "attachment_list" "$APP_ATT_LIST" "skip" "SKIPPED" \
            "" "" "Already generated in this run"
    else
    log "INFO" "[$APP_NAME] Querying AM_ATTACHMENTS in DB: $APP_NAME"
    if ! ssasql fas "$APP_NAME" "$DB_USER/$DB_PASS" <<SSASQL >"$ATT_RAW_TMP" 2>&1
alter session set systemcatalog=0;
.set width 1048576;
.set long 1048576;
.export {SELECT ATTACHMENT_DIRECTORY,ATTACHMENT_NAME FROM "DBO"."AM_ATTACHMENTS"} into '$APP_ATT_LIST' CSV;
.exit;
SSASQL
    then
        warn "[$APP_NAME] ssasql query for AM_ATTACHMENTS returned non-zero exit — attachment extraction skipped"
        audit_event "step3" "$APP_NAME" "attachment_list" "$APP_ATT_LIST" "query" "FAILED" \
            "" "" "ssasql returned non-zero"
        ATT_STEP_OK=false
    fi
    rm -f "$ATT_RAW_TMP"

    if $ATT_STEP_OK && [[ ! -f "$APP_ATT_LIST" ]]; then
        warn "[$APP_NAME] Attachment list CSV was not created by ssasql — attachment extraction skipped"
        audit_event "step3" "$APP_NAME" "attachment_list" "$APP_ATT_LIST" "query" "FAILED" \
            "" "" "Output CSV not created"
        ATT_STEP_OK=false
    fi

    if $ATT_STEP_OK; then
        ATT_ROW_COUNT=$(( $(wc -l < "$APP_ATT_LIST") ))
        # Add header row if ssasql export omitted it
        if ! head -1 "$APP_ATT_LIST" 2>/dev/null | grep -qi "ATTACHMENT_DIRECTORY"; then
            sed -i '1i ATTACHMENT_DIRECTORY,ATTACHMENT_NAME' "$APP_ATT_LIST"
        fi
        log "INFO" "[$APP_NAME] Attachment list saved : $APP_ATT_LIST ($ATT_ROW_COUNT record(s))"
        ckpt_mark_done "$APP_NAME|attachment_list" "$ATT_ROW_COUNT records"
        audit_event "step3" "$APP_NAME" "attachment_list" "$APP_ATT_LIST" "query" "SUCCESS" \
            "$ATT_ROW_COUNT" "$(trace_filesize "$APP_ATT_LIST")" "Attachment list generated"
        evidence_add "$APP_NAME" "metadata" "$APP_ATT_LIST" \
            "$TARGET_S3_STAGE/$APP_NAME/metadata/$(basename "$APP_ATT_LIST")" "$ATT_ROW_COUNT"
    fi
    fi
    step_complete 3 $STEP3_START

    # =========================================================================
    # STEP 4 — Extract Attachments via Lambda → S3
    #           Runs: 03_app_attachement_extraction.sh
    # =========================================================================
    STEP4_START=$(date +%s)
    step_banner 4 "[$APP_NAME] Extract Attachments"

    if ckpt_is_done "$APP_NAME|attachment_extract"; then
        log "INFO" "[RESUME] [$APP_NAME] Attachments already extracted — skipping"
        audit_event "step4" "$APP_NAME" "attachment" "ALL" "skip" "SKIPPED" "" "" \
            "Already extracted in this run"
    elif $ATT_STEP_OK; then
        log "INFO" "[$APP_NAME] Running: 03_app_attachement_extraction.sh $APP_ATT_LIST"
        if ! bash "$SCRIPT_DIR/03_app_attachement_extraction.sh" "$APP_ATT_LIST"; then
            warn "[$APP_NAME] 03_app_attachement_extraction.sh completed with errors — see sub-script log"
            audit_event "step4" "$APP_NAME" "attachment" "ALL" "extract" "FAILED" "" "" \
                "Sub-script returned non-zero"
        else
            log "INFO" "[$APP_NAME] Attachment extraction completed successfully"
            ckpt_mark_done "$APP_NAME|attachment_extract" "lambda extraction"
            audit_event "step4" "$APP_NAME" "attachment" "ALL" "extract" "SUCCESS" "" "" \
                "Attachments dispatched to Lambda"
        fi
    else
        log "INFO" "[$APP_NAME] Attachment extraction skipped (no attachment list generated)"
        audit_event "step4" "$APP_NAME" "attachment" "ALL" "extract" "SKIPPED" "" "" \
            "No attachment list available"
    fi
    step_complete 4 $STEP4_START

    # =========================================================================
    # STEP 5 — Extract Tables to CSV (with headers)
    #           Runs: 04_app_table_extraction.sh
    #           Output: $EXPORT_PATH/{DB}/{TABLE}.csv
    # =========================================================================
    STEP5_START=$(date +%s)
    step_banner 5 "[$APP_NAME] Extract Tables"

    if ckpt_is_done "$APP_NAME|table_extract"; then
        log "INFO" "[RESUME] [$APP_NAME] Tables already extracted — skipping"
        audit_event "step5" "$APP_NAME" "table" "ALL" "skip" "SKIPPED" "$TABLE_TOTAL" "" \
            "Already extracted in this run"
    else
        log "INFO" "[$APP_NAME] Running: 04_app_table_extraction.sh $TABLE_LIST_CSV"
        if ! bash "$SCRIPT_DIR/04_app_table_extraction.sh" "$TABLE_LIST_CSV"; then
            warn "[$APP_NAME] 04_app_table_extraction.sh completed with errors — see sub-script log"
            audit_event "step5" "$APP_NAME" "table" "ALL" "extract" "FAILED" "$TABLE_TOTAL" "" \
                "Sub-script returned non-zero"
        else
            log "INFO" "[$APP_NAME] Table extraction completed successfully"
            ckpt_mark_done "$APP_NAME|table_extract" "$TABLE_TOTAL tables"
            audit_event "step5" "$APP_NAME" "table" "ALL" "extract" "SUCCESS" "$TABLE_TOTAL" "" \
                "Tables exported to CSV"
        fi
    fi
    step_complete 5 $STEP5_START

    # =========================================================================
    # STEP 6 — Generate Per-Application Metadata Report
    #           Output: $ILM_METADATA_PATH/{APP}/{APP}_metadata_{ts}.csv
    #           Columns: srno, filename, type, count, size_bytes,
    #                    source_path, extracted_path, created_date, created_by
    # =========================================================================
    STEP6_START=$(date +%s)
    step_banner 6 "[$APP_NAME] Generate Metadata Report"

    META_REPORT="$APP_META_DIR/${APP_NAME}_metadata_${LOG_TIMESTAMP}.csv"
    REPORT_TS=$(date '+%Y-%m-%dT%H:%M:%S')
    SRNO=0

    # Write CSV header
    printf 'srno,filename,type,count,size_bytes,source_path,extracted_path,created_date,created_by\n' \
        > "$META_REPORT"

    # ── 6a. Table files ───────────────────────────────────────────────────────
    log "INFO" "[$APP_NAME] Scanning exported table CSV files under $EXPORT_PATH ..."
    TABLE_META_COUNT=0
    while IFS= read -r -d '' CSV_FILE; do
        FNAME=$(basename "$CSV_FILE")
        FSIZE=$(stat -c '%s' "$CSV_FILE" 2>/dev/null || echo 0)
        RAW_LINES=$(wc -l < "$CSV_FILE" 2>/dev/null || echo 1)
        # Subtract header row; guard against empty files
        FCOUNT=$(( RAW_LINES > 1 ? RAW_LINES - 1 : 0 ))
        # source_path = DB sub-folder name inside EXPORT_PATH
        SRC_DB=$(basename "$(dirname "$CSV_FILE")")

        ((SRNO++))
        ((TABLE_META_COUNT++))
        printf '%s,"%s",table,%s,%s,"%s","%s","%s","%s"\n' \
            "$SRNO" "$FNAME" "$FCOUNT" "$FSIZE" \
            "$APP_NAME/$SRC_DB" "$CSV_FILE" \
            "$REPORT_TS" "$CREATED_BY" >> "$META_REPORT"

        # GxP evidence: checksum every extracted data file
        evidence_add "$APP_NAME" "table" "$CSV_FILE" \
            "$TARGET_S3_STAGE/$APP_NAME/tabledata/$FNAME" "$FCOUNT"

    done < <(find "$EXPORT_PATH" -path "*/$APP_NAME/*.csv" -type f -print0 2>/dev/null)

    log "INFO" "[$APP_NAME] Table entries in metadata report: $TABLE_META_COUNT"

    # ── 6b. Attachment entries (sourced from attachment list CSV) ─────────────
    ATT_META_COUNT=0
    if [[ -f "$APP_ATT_LIST" ]]; then
        log "INFO" "[$APP_NAME] Scanning attachment list for metadata entries ..."
        while IFS=',' read -r ATT_DIR ATT_NAME REST; do
            ATT_DIR=$(echo "$ATT_DIR" | xargs)
            ATT_NAME=$(echo "$ATT_NAME" | xargs)
            [[ -z "$ATT_NAME" ]] && continue

            # Extracted path: S3 location where Lambda deposited the file
            S3_EXTRACTED="s3://$EXPORT_LOC/$APP_NAME/$(basename "$ATT_DIR")/$ATT_NAME"

            ((SRNO++))
            ((ATT_META_COUNT++))
            printf '%s,"%s",attachment,1,N/A,"%s","%s","%s","%s"\n' \
                "$SRNO" "$ATT_NAME" \
                "$ATT_DIR" "$S3_EXTRACTED" \
                "$REPORT_TS" "$CREATED_BY" >> "$META_REPORT"

        done < <(tail -n +2 "$APP_ATT_LIST")
        log "INFO" "[$APP_NAME] Attachment entries in metadata report: $ATT_META_COUNT"
    fi

    # ── 6c. Finalise ──────────────────────────────────────────────────────────
    chmod 766 "$META_REPORT"

    APP_TOTAL_FILES=$(( TABLE_META_COUNT + ATT_META_COUNT ))
    (( PIPELINE_FILE_COUNT += APP_TOTAL_FILES ))

    log "INFO" "[$APP_NAME] Metadata report   : $META_REPORT"
    log "INFO" "[$APP_NAME]   -> Table entries : $TABLE_META_COUNT"
    log "INFO" "[$APP_NAME]   -> Attach entries: $ATT_META_COUNT"
    log "INFO" "[$APP_NAME]   -> Total entries : $SRNO"

    audit_event "step6" "$APP_NAME" "metadata_report" "$META_REPORT" "generate" "SUCCESS" \
        "$SRNO" "$(trace_filesize "$META_REPORT")" \
        "tables=$TABLE_META_COUNT attachments=$ATT_META_COUNT"
    evidence_add "$APP_NAME" "metadata" "$META_REPORT" \
        "$TARGET_S3_STAGE/$APP_NAME/metadata/$(basename "$META_REPORT")" "$SRNO"
    ckpt_mark_done "$APP_NAME|metadata_report" "$SRNO entries"
    step_complete 6 $STEP6_START

    # =========================================================================
    # STEP 7 — Copy Application Data, Metadata & Logs to S3
    #           7a: tabledata   → s3://{TARGET_S3_STAGE}/{APP}/tabledata/
    #           7b: attachments → s3://{TARGET_S3_STAGE}/{APP}/attachements/
    #           7c: metadata    → s3://{TARGET_S3_STAGE}/{APP}/metadata/
    #           7d: app logs    → s3://{TARGET_S3_STAGE}/{APP}/logs/
    # =========================================================================
    STEP7_START=$(date +%s)
    step_banner 7 "[$APP_NAME] Copy to S3"

    APP_S3_TARGET="$TARGET_S3_STAGE/$APP_NAME"
    COPY_ERRORS=0
    log "INFO" "[$APP_NAME] S3 target: $APP_S3_TARGET"

    # ── 7a. Copy table data (local EFS → S3) ─────────────────────────────────
    log "INFO" "[$APP_NAME] [7a] Copying table data..."
    SRC_TABLE_COUNT=$(find "$EXPORT_PATH/$APP_NAME" -type f 2>/dev/null | wc -l)
    log "INFO" "[$APP_NAME] Source table files: $SRC_TABLE_COUNT"
    if [[ "$SRC_TABLE_COUNT" -gt 0 ]]; then
        if ! aws s3 cp "$EXPORT_PATH/$APP_NAME" "$APP_S3_TARGET/tabledata" --recursive; then
            warn "[$APP_NAME] Failed to copy table data to S3"
            ((COPY_ERRORS++))
        else
            TBL_S3=$(aws s3 ls "$APP_S3_TARGET/tabledata/" --recursive | grep -v ' PRE ' | wc -l)
            log "INFO" "[$APP_NAME] Table files uploaded: $TBL_S3"
        fi
    else
        log "INFO" "[$APP_NAME] No local table data found — skipping"
    fi
    log "INFO" "------------------------------------------------------------"

    # ── 7b. Copy attachments (S3 bulk-download bucket → S3 ilm-export) ───────
    log "INFO" "[$APP_NAME] [7b] Copying attachments (S3 -> S3)..."
    SRC_ATT_S3=$(aws s3 ls "$ATT_S3_BUCKET/$APP_NAME/" --recursive 2>/dev/null | grep -v ' PRE ' | wc -l || echo 0)
    log "INFO" "[$APP_NAME] Source attachment files in S3: $SRC_ATT_S3"
    if [[ "$SRC_ATT_S3" -gt 0 ]]; then
        if ! aws s3 cp "$ATT_S3_BUCKET/$APP_NAME" "$APP_S3_TARGET/attachements" --recursive; then
            warn "[$APP_NAME] Failed to copy attachments to S3"
            ((COPY_ERRORS++))
        else
            ATT_S3=$(aws s3 ls "$APP_S3_TARGET/attachements/" --recursive | grep -v ' PRE ' | wc -l)
            log "INFO" "[$APP_NAME] Attachment files copied: $ATT_S3"
        fi
    else
        log "INFO" "[$APP_NAME] No source attachments found in S3 — skipping"
    fi
    log "INFO" "------------------------------------------------------------"

    # ── 7c. Copy per-app metadata dir (reports + attachment list) ────────────
    log "INFO" "[$APP_NAME] [7c] Copying application metadata..."
    APP_META_COUNT=$(find "$APP_META_DIR" -type f 2>/dev/null | wc -l)
    log "INFO" "[$APP_NAME] Source metadata files: $APP_META_COUNT"
    if [[ "$APP_META_COUNT" -gt 0 ]]; then
        if ! aws s3 cp "$APP_META_DIR" "$APP_S3_TARGET/metadata" --recursive; then
            warn "[$APP_NAME] Failed to copy metadata to S3"
            ((COPY_ERRORS++))
        else
            META_S3=$(aws s3 ls "$APP_S3_TARGET/metadata/" --recursive | grep -v ' PRE ' | wc -l)
            log "INFO" "[$APP_NAME] Metadata files uploaded: $META_S3"
        fi
    else
        log "INFO" "[$APP_NAME] No metadata files found — skipping"
    fi
    log "INFO" "------------------------------------------------------------"

    # ── 7d. Copy per-app logs (${APP_NAME}_*.log from LOG_PATH) ──────────────
    log "INFO" "[$APP_NAME] [7d] Copying application logs..."
    APP_LOG_STAGE="$LOG_PATH/.${APP_NAME}_stage"
    mkdir -p "$APP_LOG_STAGE"
    find "$LOG_PATH" -maxdepth 1 -name "${APP_NAME}_*.log" -exec cp {} "$APP_LOG_STAGE/" \; 2>/dev/null || true
    APP_LOG_COUNT=$(find "$APP_LOG_STAGE" -type f | wc -l)
    log "INFO" "[$APP_NAME] Source log files: $APP_LOG_COUNT"
    if [[ "$APP_LOG_COUNT" -gt 0 ]]; then
        if ! aws s3 cp "$APP_LOG_STAGE" "$APP_S3_TARGET/logs" --recursive; then
            warn "[$APP_NAME] Failed to copy logs to S3"
            ((COPY_ERRORS++))
        else
            LOG_S3=$(aws s3 ls "$APP_S3_TARGET/logs/" --recursive | grep -v ' PRE ' | wc -l)
            log "INFO" "[$APP_NAME] Log files uploaded: $LOG_S3"
        fi
    else
        log "INFO" "[$APP_NAME] No application logs found — skipping"
    fi
    rm -rf "$APP_LOG_STAGE"
    log "INFO" "------------------------------------------------------------"

    if [[ $COPY_ERRORS -eq 0 ]]; then
        log "INFO" "[$APP_NAME] All data successfully copied to: $APP_S3_TARGET"
        ckpt_mark_done "$APP_NAME|s3_copy" "copied to $APP_S3_TARGET"
        audit_event "step7" "$APP_NAME" "s3_upload" "$APP_S3_TARGET" "copy" "SUCCESS" \
            "" "" "All artifacts uploaded"
    else
        warn "[$APP_NAME] S3 copy completed with $COPY_ERRORS error(s)"
        audit_event "step7" "$APP_NAME" "s3_upload" "$APP_S3_TARGET" "copy" "FAILED" \
            "" "" "$COPY_ERRORS copy error(s)"
    fi
    step_complete 7 $STEP7_START

    # =========================================================================
    # STEP 8 — Reconciliation and GxP Evidence
    #           Output: evidence/<RUN_ID>/reconciliation_<APP>.csv
    #                   evidence/<RUN_ID>/validation_summary_<APP>.txt
    # =========================================================================
    STEP8_START=$(date +%s)
    step_banner 8 "[$APP_NAME] Reconciliation & Evidence"

    if bash "$SCRIPT_DIR/reconcile.sh" "$APP_NAME" "$RUN_ID"; then
        log "INFO" "[$APP_NAME] Reconciliation PASSED"
        audit_event "step8" "$APP_NAME" "reconciliation" "$APP_NAME" "verify" "PASS" "" "" \
            "Source/extract/target counts reconciled"
    else
        warn "[$APP_NAME] Reconciliation FAILED — review evidence before release"
        audit_event "step8" "$APP_NAME" "reconciliation" "$APP_NAME" "verify" "FAIL" "" "" \
            "Discrepancies detected"
        ((RECON_FAILED++))
    fi
    step_complete 8 $STEP8_START

    # --- Application complete: checkpoint so a resume skips it --------------
    ckpt_mark_done "$APP_NAME|COMPLETE" "application finished"

    APP_LOOP_DURATION=$(( $(date +%s) - APP_LOOP_START ))
    log "INFO" "[$APP_NAME] Application total time : ${APP_LOOP_DURATION}s"
    audit_event "application" "$APP_NAME" "application" "$APP_NAME" "complete" "SUCCESS" \
        "$APP_TOTAL_FILES" "" "Duration ${APP_LOOP_DURATION}s"

    progress_step "$APP_NAME"
    log "INFO" ""

done < "$APP_LIST_FILE"

progress_finish "all applications processed"

# =============================================================================
# STEP 7G — Copy Global ILM Metadata & Pipeline Logs to S3
#            ilm_metadata  → s3://{TARGET_S3_STAGE}/ilm_metadata/
#            pipeline logs → s3://{TARGET_S3_STAGE}/pipeline_logs/
# =============================================================================
STEP7G_START=$(date +%s)
step_banner "7G" "Copy Global ILM Metadata & Pipeline Logs to S3"

GLOBAL_S3_TARGET="$TARGET_S3_STAGE"
GLOBAL_COPY_ERRORS=0

# ── Copy global ILM metadata directory (application_list + all table lists) ──
log "INFO" "Copying ILM metadata: $ILM_METADATA_PATH → $GLOBAL_S3_TARGET/ilm_metadata"
ILM_META_COUNT=$(find "$ILM_METADATA_PATH" -type f 2>/dev/null | wc -l)
log "INFO" "Source ILM metadata files: $ILM_META_COUNT"
if [[ "$ILM_META_COUNT" -gt 0 ]]; then
    if ! aws s3 cp "$ILM_METADATA_PATH" "$GLOBAL_S3_TARGET/ilm_metadata" --recursive; then
        warn "Failed to copy ILM metadata to S3"
        ((GLOBAL_COPY_ERRORS++))
    else
        GMETA_S3=$(aws s3 ls "$GLOBAL_S3_TARGET/ilm_metadata/" --recursive | grep -v ' PRE ' | wc -l)
        log "INFO" "ILM metadata files uploaded: $GMETA_S3"
    fi
else
    log "INFO" "No ILM metadata files found — skipping"
fi
log "INFO" "------------------------------------------------------------"

# ── Copy pipeline logs directory ─────────────────────────────────────────────
log "INFO" "Copying pipeline logs: $PIPELINE_LOG_DIR → $GLOBAL_S3_TARGET/pipeline_logs"
PIPE_LOG_COUNT=$(find "$PIPELINE_LOG_DIR" -type f 2>/dev/null | wc -l)
log "INFO" "Source pipeline log files: $PIPE_LOG_COUNT"
if [[ "$PIPE_LOG_COUNT" -gt 0 ]]; then
    if ! aws s3 cp "$PIPELINE_LOG_DIR" "$GLOBAL_S3_TARGET/pipeline_logs" --recursive; then
        warn "Failed to copy pipeline logs to S3"
        ((GLOBAL_COPY_ERRORS++))
    else
        PLOG_S3=$(aws s3 ls "$GLOBAL_S3_TARGET/pipeline_logs/" --recursive | grep -v ' PRE ' | wc -l)
        log "INFO" "Pipeline log files uploaded: $PLOG_S3"
    fi
else
    log "INFO" "No pipeline log files found — skipping"
fi
log "INFO" "------------------------------------------------------------"

if [[ $GLOBAL_COPY_ERRORS -eq 0 ]]; then
    log "INFO" "Global metadata and pipeline logs successfully copied to: $GLOBAL_S3_TARGET"
else
    warn "Global S3 copy completed with $GLOBAL_COPY_ERRORS error(s)"
fi
step_complete "7G" $STEP7G_START

# =============================================================================
# PIPELINE SUMMARY
# =============================================================================
PIPELINE_DURATION=$(( $(date +%s) - PIPELINE_START ))

# --- Seal the GxP evidence set (checksums + read-only) ----------------------
evidence_finalize

PIPELINE_STATUS="SUCCESS"
(( APPS_FAILED > 0 || RECON_FAILED > 0 )) && PIPELINE_STATUS="COMPLETED_WITH_ERRORS"

audit_event "pipeline" "" "run" "$RUN_ID" "complete" "$PIPELINE_STATUS" \
    "$PIPELINE_FILE_COUNT" "" \
    "apps=$APP_COUNTER skipped=$APPS_SKIPPED failed=$APPS_FAILED recon_failed=$RECON_FAILED duration=${PIPELINE_DURATION}s"

log "INFO" "################################################################"
log "INFO" "#        ILM FULL EXPORT PIPELINE — COMPLETE                  #"
log "INFO" "################################################################"
log "INFO" "  Run ID                 : $RUN_ID"
log "INFO" "  Status                 : $PIPELINE_STATUS"
log "INFO" "  Completed At           : $(date '+%Y-%m-%d %H:%M:%S')  ($(trace_utc))"
log "INFO" "  Run By                 : $CREATED_BY"
log "INFO" "  Applications Processed : $APP_COUNTER / $TOTAL_APPS"
log "INFO" "  Applications Skipped   : $APPS_SKIPPED (already complete)"
log "INFO" "  Applications Failed    : $APPS_FAILED"
log "INFO" "  Reconciliation Failures: $RECON_FAILED"
log "INFO" "  Total Files Tracked    : $PIPELINE_FILE_COUNT"
log "INFO" "  Total Duration         : ${PIPELINE_DURATION}s"
log "INFO" "----------------------------------------------------------------"
log "INFO" "  TRACEABILITY & EVIDENCE"
log "INFO" "  Pipeline Log           : $PIPELINE_LOG"
log "INFO" "  Audit Trail            : $AUDIT_FILE"
log "INFO" "  Evidence Directory     : $EVIDENCE_DIR"
log "INFO" "  Evidence Seal          : $EVIDENCE_DIR/MANIFEST.sha256"
log "INFO" "  Checkpoint File        : $CKPT_FILE"
log "INFO" "  Metadata Reports       : $ILM_METADATA_PATH/<APP>/<APP>_metadata_${LOG_TIMESTAMP}.csv"
log "INFO" "  S3 Stage Location      : $TARGET_S3_STAGE"
log "INFO" "################################################################"

# =============================================================================
# STEP 9 — Transfer Evidence, Audit Trail and Logs to S3
#           Runs AFTER the evidence set is sealed so the checksums, the
#           reconciliation reports and the audit trail are all preserved in S3
#           alongside the data they describe.
#
#           audit trail  -> s3://{TARGET_S3_STAGE}/_audit/
#           evidence set -> s3://{TARGET_S3_STAGE}/_evidence/{RUN_ID}/
#           checkpoints  -> s3://{TARGET_S3_STAGE}/_checkpoints/{RUN_ID}/
#           all logs     -> s3://{TARGET_S3_STAGE}/logs/{RUN_ID}/
# =============================================================================
STEP9_START=$(date +%s)
step_banner 9 "Transfer Evidence, Audit Trail & Logs to S3"

EVIDENCE_S3_ERRORS=0

s3_upload_dir "$AUDIT_DIR" "$TARGET_S3_STAGE/_audit" "audit trail" "" "step9"
[[ $? -eq 1 ]] && ((EVIDENCE_S3_ERRORS++))

s3_upload_dir "$EVIDENCE_DIR" "$TARGET_S3_STAGE/_evidence/$RUN_ID" "evidence set" "" "step9"
[[ $? -eq 1 ]] && ((EVIDENCE_S3_ERRORS++))

s3_upload_dir "$CKPT_DIR" "$TARGET_S3_STAGE/_checkpoints/$RUN_ID" "checkpoints" "" "step9"
[[ $? -eq 1 ]] && ((EVIDENCE_S3_ERRORS++))

s3_upload_dir "$LOG_PATH" "$TARGET_S3_STAGE/logs/$RUN_ID" "all logs" "" "step9"
[[ $? -eq 1 ]] && ((EVIDENCE_S3_ERRORS++))

if (( EVIDENCE_S3_ERRORS > 0 )); then
    warn "Evidence/log transfer completed with $EVIDENCE_S3_ERRORS error(s)"
    PIPELINE_STATUS="COMPLETED_WITH_ERRORS"
else
    log "INFO" "Evidence, audit trail and logs transferred to S3 and verified"
fi
step_complete 9 $STEP9_START

# --- Clear the resume pointer only when the whole run, including the
#     evidence transfer, completed cleanly -----------------------------------
if [[ "$PIPELINE_STATUS" == "SUCCESS" ]]; then
    ckpt_complete
fi

log "INFO" "  Evidence in S3         : $TARGET_S3_STAGE/_evidence/$RUN_ID"
log "INFO" "  Audit trail in S3      : $TARGET_S3_STAGE/_audit"
log "INFO" "  Logs in S3             : $TARGET_S3_STAGE/logs/$RUN_ID"
log "INFO" "  Final status           : $PIPELINE_STATUS"
log "INFO" "################################################################"

# --- Final action: upload this pipeline log itself (last write wins) --------
s3_upload_file "$PIPELINE_LOG" \
    "$TARGET_S3_STAGE/logs/$RUN_ID/$(basename "$PIPELINE_LOG")" \
    "pipeline log" "" "step9" >/dev/null 2>&1 || true

if [[ "$PIPELINE_STATUS" != "SUCCESS" ]]; then
    log "WARN" "Run did not complete cleanly. Resume with: bash ilm_pipeline.sh --resume"
    exit 1
fi

exit 0
