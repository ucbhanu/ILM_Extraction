#!/bin/bash

# --- Logger ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/logger.sh" || { echo "FATAL: cannot source logger.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib_s3.sh" || { echo "FATAL: cannot source lib_s3.sh" >&2; exit 1; }
log_trap_int

# --- Configuration ---
if ! . "$SCRIPT_DIR/.conf.ini"; then
    error_exit "Failed to source .conf.ini"
fi

# logging path
LOG_DIR=$LOG_PATH
if ! mkdir -p "$LOG_DIR"; then
    error_exit "Failed to create directory $LOG_DIR"
fi

if ! chmod 766 "$LOG_DIR"; then
    error_exit "Failed to set permissions on $LOG_DIR"
fi

#Variables
# APP_NAME is passed as the first argument
APP_NAME=$1
if [[ -z "$APP_NAME" ]]; then
    error_exit "Usage: $0 <APP_NAME>"
fi
# Paths resolved from .conf.ini (EXPORT_PATH, ATT_S3_BUCKET, TARGET_S3_STAGE)
ATT_SOURCE_PATH="$ATT_S3_BUCKET"
TARGET_PATH="$TARGET_S3_STAGE/$APP_NAME"

# --- Set log file for this table export ---
LOG_TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
log_init "$LOG_DIR/${APP_NAME}_COPY_TO_S3_${LOG_TIMESTAMP}.log" \
    || error_exit "Failed to initialise log file in $LOG_DIR"




# --- Start timer ---
SCRIPT_START_TIME=$(date +%s)


#copy to S3 location for Archivist

log "INFO" "**************************************************************************************************************************************"
log "INFO" "        				Starting Copy to S3..."
log "INFO" "        				Application Name: $APP_NAME"
log "INFO" "**************************************************************************************************************************************"

# copy metadata
log "INFO" "Copy Metadata"
SRC_META_COUNT=$(find "$ILM_METADATA_PATH" -type f | wc -l)
log "INFO" "Source metadata file count: $SRC_META_COUNT"
if ! aws s3 cp "$ILM_METADATA_PATH" "$TARGET_PATH/metadata" --recursive; then
    error_exit "Failed to copy metadata from $ILM_METADATA_PATH to $TARGET_PATH/metadata"
fi
META_COUNT=$(aws s3 ls "$TARGET_PATH/metadata/" --recursive | grep -v ' PRE ' | wc -l)
log "INFO" "Target metadata file count: $META_COUNT"
log "INFO" "Total files copied to metadata: $META_COUNT"
sleep 1
log "INFO" "-----------------------------------------------------------------------------"

# copy table data
log "INFO" "Copy Table CSV"
SRC_TABLE_COUNT=$(find "$EXPORT_PATH/$APP_NAME" -type f | wc -l)
log "INFO" "Source tabledata file count: $SRC_TABLE_COUNT"
if ! aws s3 cp "$EXPORT_PATH/$APP_NAME" "$TARGET_PATH/tabledata" --recursive; then
    error_exit "Failed to copy table data from $EXPORT_PATH/$APP_NAME to $TARGET_PATH/tabledata"
fi
TABLE_COUNT=$(aws s3 ls "$TARGET_PATH/tabledata/" --recursive | grep -v ' PRE ' | wc -l)
log "INFO" "Target tabledata file count: $TABLE_COUNT"
log "INFO" "Total files copied to tabledata: $TABLE_COUNT"
sleep 1
log "INFO" "-----------------------------------------------------------------------------"

# copy attachments
log "INFO" "Copy Attachement"
SRC_ATT_COUNT=$(aws s3 ls "$ATT_SOURCE_PATH/$APP_NAME/" --recursive | grep -v ' PRE ' | wc -l)
log "INFO" "Source attachements file count: $SRC_ATT_COUNT"
if ! aws s3 cp "$ATT_SOURCE_PATH/$APP_NAME" "$TARGET_PATH/attachements" --recursive; then
    error_exit "Failed to copy attachments from $ATT_SOURCE_PATH/$APP_NAME to $TARGET_PATH/attachements"
fi
ATTACH_COUNT=$(aws s3 ls "$TARGET_PATH/attachements/" --recursive | grep -v ' PRE ' | wc -l)
log "INFO" "Target attachements file count: $ATTACH_COUNT"
log "INFO" "Total files copied to attachements: $ATTACH_COUNT"
sleep 1
log "INFO" "-----------------------------------------------------------------------------"

log "INFO" "All Data has been copied to below location"
log "INFO" "Taget Location: $TARGET_PATH"
log "INFO" "-----------------------------------------------------------------------------"

# =============================================================================
# Copy evidence, audit trail and logs so the transfer is self-documenting
# =============================================================================
log "INFO" "Copy Evidence, Audit Trail & Logs"

s3_upload_dir "$ILM_METADATA_PATH/audit" "$TARGET_S3_STAGE/_audit" \
    "audit trail" "$APP_NAME" "copy_to_s3"

s3_upload_dir "$ILM_METADATA_PATH/evidence" "$TARGET_S3_STAGE/_evidence" \
    "evidence set" "$APP_NAME" "copy_to_s3"

# Application specific logs
APP_LOG_STAGE="$LOG_DIR/.${APP_NAME}_stage_$$"
mkdir -p "$APP_LOG_STAGE"
find "$LOG_DIR" -maxdepth 1 -name "${APP_NAME}_*.log" -exec cp {} "$APP_LOG_STAGE/" \; 2>/dev/null || true
s3_upload_dir "$APP_LOG_STAGE" "$TARGET_PATH/logs" \
    "application logs" "$APP_NAME" "copy_to_s3"
rm -rf "$APP_LOG_STAGE"

log "INFO" "-----------------------------------------------------------------------------"

SCRIPT_END_TIME=$(date +%s)
TOTAL_TIME=$((SCRIPT_END_TIME - SCRIPT_START_TIME))

log "INFO" "**************************************************************************************************************************************"
log "INFO" "        				Copy data completed for APP: $APP_NAME"
log "INFO" "        				Total time taken by script: ${TOTAL_TIME} seconds"
log "INFO" "**************************************************************************************************************************************"

# Final action: upload this script's own log
s3_upload_file "$LOG_FILE" "$TARGET_PATH/logs/$(basename "$LOG_FILE")" \
    "copy log" "$APP_NAME" "copy_to_s3" >/dev/null 2>&1 || true
