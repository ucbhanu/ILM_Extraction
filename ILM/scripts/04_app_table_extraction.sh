#!/bin/bash

# --- Logger Function ---
log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "[$ts] [$level] $msg" | tee -a "${LOG_FILE:-./batch_export.log}"
}

# --- Error Handler ---
error_exit() {
    log "ERROR" "$1"
    exit 1
}

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! . "$SCRIPT_DIR/conf.ini"; then
    error_exit "Failed to source conf.ini"
fi
if ! source "$IDV_HOME/ssaenv.sh"; then
    error_exit "Failed to source $IDV_HOME/ssaenv.sh"
fi

# --- Start timer ---
SCRIPT_START_TIME=$(date +%s)

# 1. Input Parameter
TABLE_LIST=$1

# Variables
COUNTER=0
APP_NAME=$(basename "$TABLE_LIST" | sed 's/_table_list.csv//')

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
LOG_FILE="$LOG_DIR/${APP_NAME}_${LOG_TIMESTAMP}.log"

log "INFO" "Application Name: $APP_NAME"

if [[ -z "$TABLE_LIST" || ! -f "$TABLE_LIST" ]]; then
    log "ERROR" "Usage: $0 <table_list.csv>"
    exit 1
fi
log "INFO" "**************************************************************************************************************************************"
log "INFO" "        				Starting Batch Export into DB-specific folders..."
log "INFO" "        				Application Name: $APP_NAME"
log "INFO" "**************************************************************************************************************************************"
# 2. Iterate through the CSV (skipping header)
tail -n +2 "$TABLE_LIST" | while IFS=',' read -r DB_NAME TID TABLE_NAME TYPE || [[ -n "$DB_NAME" ]]; do
    
    # Clean variables
	((COUNTER++))
    DB_NAME=$(echo -e "$DB_NAME" | xargs)
    TABLE_NAME=$(echo -e "$TABLE_NAME" | xargs | tr -d '"')
	SCHEMA_PART=$(echo -e $TABLE_NAME | cut -d. -f1)
    TABLE_PART=$(echo -e $TABLE_NAME | cut -d. -f2)
    #FILE_NAME="${SCHEMA_PART}_${TABLE_PART}.csv"

    # 3. Create the DB folder inside your Export Path
    # mkdir -p ensures the script doesn't fail if the folder exists
    TARGET_DIR="$EXPORT_PATH/$DB_NAME"
    if ! mkdir -p "$TARGET_DIR"; then
        log "ERROR" "Failed to create directory $TARGET_DIR"
        continue
    fi
    if ! chmod 766 "$TARGET_DIR"; then
        log "ERROR" "Failed to set permissions on $TARGET_DIR"
        continue
    fi
	

    log "INFO" "----------------------------------------------------------------------------------------------------"
    log "INFO" "     [$COUNTER]  DB: $DB_NAME | Table: $TABLE_NAME"
	log "INFO" "----------------------------------------------------------------------------------------------------"
    log "INFO" "Saving to: $TARGET_DIR"

	# 4. Clean the table name
	# Example: Converts DBO.MY_TABLE to "DBO"."MY_TABLE"
	quoted_table=$(echo -e "$TABLE_NAME" | sed 's/\./"."/g' | sed 's/^/"/;s/$/"/')
	log "INFO" "Exporting table: $quoted_table"
	
	# 5. Get Column Headers
    if ! ssasql fas "$DB_NAME" "$DB_USER/$DB_PASS" <<EOF >"$TARGET_DIR/${TABLE_NAME}_header.raw"
alter session set systemcatalog=1;
.set width 1048576;
.set long 1048576;

SELECT c.NAME 
FROM cat_databases d, cat_tables t, cat_schemas s, cat_columns c
WHERE t.name='$TABLE_PART' 
  AND s.name='$SCHEMA_PART'
  AND d.NAME='$DB_NAME'
  AND d.DBID = s.DBID
  AND t.schid = s.schid 
  AND c.tid = t.tid
  -- EXCLUDE ILM INTERNAL COLUMNS --
  AND c.NAME NOT LIKE 'APPLIMATION_%'
  AND c.NAME NOT LIKE 'ILM_%'
  AND c.NAME NOT LIKE '$%$'
ORDER BY c.colno;
.exit;
EOF
    then
        log "ERROR" "Failed to get column headers for $TABLE_NAME"
        continue
    fi

	# 6. convert to csv header
	log "INFO" "Header generation..."
	columns=$(sed -n '26,$p' "$TARGET_DIR/${TABLE_NAME}_header.raw" | head -n -2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | paste -s -d ',' -)
    if [[ -z "$columns" ]]; then
        log "ERROR" "No columns found for $TABLE_NAME"
        rm -f "$TARGET_DIR/${TABLE_NAME}_header.raw"
        continue
    fi
	#echo -e "$columns" > "$TARGET_DIR/${TABLE_NAME}.csv"

	
	# 7. Remove the raw/temp file
	log "INFO" "Remove the raw/temp file..."
    if ! rm "$TARGET_DIR/${TABLE_NAME}_header.raw"; then
        log "ERROR" "Failed to remove temp file $TARGET_DIR/${TABLE_NAME}_header.raw"
    fi
	
	# 8. Run ssasql with explicit schema setting
	log "INFO" "Table Data extraction started..."
    if ! ssasql fas "$DB_NAME" "$DB_USER/$DB_PASS" <<EOF 
alter session set systemcatalog=0;
.set width 1048576;
.set long 1048576;

.export bulk {SELECT $columns FROM $quoted_table} into '$TARGET_DIR/${TABLE_NAME}.csv' CSV;
.exit;
EOF
    then
        log "ERROR" "Failed to export data for $TABLE_NAME"
        continue
    fi

	# 9. merge column with data
	log "INFO" "Merging Header with Table Data..."
    if ! sed -i "1i $columns" "$TARGET_DIR/${TABLE_NAME}.csv"; then
        log "ERROR" "Failed to prepend header to $TARGET_DIR/${TABLE_NAME}.csv"
        continue
    fi
	
	# 10. Count exported rows (excluding header)
    export_count=$(($(wc -l < "$TARGET_DIR/${TABLE_NAME}.csv") - 1))
    log "INFO" "Exported row count for $TABLE_NAME: $export_count"
	
	log "INFO" "Table ${TABLE_NAME} exported."
	log "INFO" "----------------------------------------------------------------------------------------------------"
    sleep 1
done

# --- End timer and print total time taken ---
SCRIPT_END_TIME=$(date +%s)
TOTAL_TIME=$((SCRIPT_END_TIME - SCRIPT_START_TIME))

log "INFO" "**************************************************************************************************************************************"
log "INFO" "						Batch processing complete."
log "INFO" "						Total time taken by script: ${TOTAL_TIME} seconds"
log "INFO" "**************************************************************************************************************************************"
