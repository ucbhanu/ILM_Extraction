#!/bin/bash

# --- Logger ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/logger.sh" || { echo "FATAL: cannot source logger.sh" >&2; exit 1; }
log_trap_int

# --- Configuration ---
if ! . "$SCRIPT_DIR/.conf.ini"; then
    error_exit "Failed to source .conf.ini"
fi
if ! source "$IDV_HOME/ssaenv.sh"; then
    error_exit "Failed to source $IDV_HOME/ssaenv.sh"
fi

# 1. Input Parameter
TABLE_LIST=$1

###    Variables   

# --- Start timer ---
SCRIPT_START_TIME=$(date +%s)

# Add automatic startdate
STARTDATE=$(date '+%Y-%m-%dT%H:%M:%S')

# COUNTER
COUNTER=0

# AWS Lambda Function and export location are loaded from .conf.ini
# (LAMBDA_FUNC and EXPORT_LOC)

# Extract APP_NAME from the directory (eg returns: LIFEDOC_QA)
APP_NAME=$(basename "$(dirname "$TABLE_LIST")")

# logging path
LOG_DIR=$LOG_PATH
if ! mkdir -p "$LOG_DIR"; then
    error_exit "Failed to create directory $LOG_DIR"
fi

if ! chmod 766 "$LOG_DIR"; then
    error_exit "Failed to set permissions on $LOG_DIR"
fi

# --- Set log file for this table export ---
LOG_TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
log_init "$LOG_DIR/${APP_NAME}_ATTACHMENTS_${LOG_TIMESTAMP}.log" \
    || error_exit "Failed to initialise log file in $LOG_DIR"

# --- Per-run Lambda response file (avoids clobbering a shared response.json) ---
RESPONSE_FILE="$LOG_DIR/.${APP_NAME}_lambda_response_$$.json"
trap 'rm -f "$RESPONSE_FILE"' EXIT

if [[ -z "$TABLE_LIST" || ! -f "$TABLE_LIST" ]]; then
    log "ERROR" "Usage: $0 <table_list.csv>"
    exit 1
fi
log "INFO" "**************************************************************************************************************************************"
log "INFO" "        				Starting Attachement Export..."
log "INFO" "        				Application Name: $APP_NAME"
log "INFO" "**************************************************************************************************************************************"
# 2. Iterate through the CSV (skipping header)
tail -n +2 "$TABLE_LIST" | while IFS=',' read -r DIR NAME REST; do
    
	((COUNTER++))
    # Trim potential whitespace or carriage returns
    DIR=$(echo "$DIR" | xargs)
    NAME=$(echo "$NAME" | xargs)
	
	log "INFO" "-----------------------------------------------------------------------------"
    log "INFO" "[$COUNTER] Processing Directory: $DIR, Filename: $NAME"
	log "INFO" "-----------------------------------------------------------------------------"
	# 3. Create JSON Payload
	# Use printf to safely inject variables into the JSON template
    PAYLOAD=$(printf '{
      "subpath": "",
      "connect_string": "%s",
      "startdate": "%s",
      "ATTACHMENT_DIRECTORY": "%s",
      "ATTACHMENT_NAME": "%s",
      "status": "QUEUED"
    }' "$APP_NAME" "$APP_NAME/${DIR#/ilmstage/}" "$DIR" "$NAME")
	
	# 4. Invoke Lambda
    if ! aws lambda invoke \
		--function-name "$LAMBDA_FUNC" \
		--payload "$PAYLOAD" \
		--cli-binary-format raw-in-base64-out \
		"$RESPONSE_FILE"; then
        log "ERROR" "Lambda invocation failed for $APP_NAME with file $NAME"
        continue
    fi

    log "INFO" "Lambda invoked for $APP_NAME with file $NAME"

    # 1. Clean the string: remove outer quotes and convert \" to "
	clean_data=$(sed 's/^"//; s/"$//; s/\\"/"/g' "$RESPONSE_FILE")

	# 2. Extract values using specific delimiters
	status=$(echo "$clean_data" | sed -n 's/.*"status" : "\([^"]*\)".*/\1/p')
	bucket=$(echo "$clean_data" | sed -n 's/.*"s3bucketname" : "\([^"]*\)".*/\1/p')
	key=$(echo "$clean_data" | sed -n 's/.*"key" : "\([^"]*\)".*/\1/p')

	# 3. Output the results
	log "INFO" "Status:     $status"
	log "INFO" "S3 Bucket:  $bucket"
	log "INFO" "Export Location: $key"
	log "INFO" "-----------------------------------------------------------------------------\n"
    sleep 1
done
log "INFO" "All Attachement has been exported to below S3 path:"
log "INFO" "Export location: $EXPORT_LOC/$APP_NAME"
SCRIPT_END_TIME=$(date +%s)
TOTAL_TIME=$((SCRIPT_END_TIME - SCRIPT_START_TIME))

log "INFO" "**************************************************************************************************************************************"
log "INFO" "        				Attachement Extraction completed for APP: $APP_NAME"
log "INFO" "        				Total time taken by script: ${TOTAL_TIME} seconds"
log "INFO" "**************************************************************************************************************************************"
