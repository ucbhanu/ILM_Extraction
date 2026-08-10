#!/bin/bash

# --- Logger ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/logger.sh" || { echo "FATAL: cannot source logger.sh" >&2; exit 1; }
log_trap_int

# --- Configuration ---
. "$SCRIPT_DIR/.conf.ini" || error_exit "Failed to source .conf.ini"
OUTPUT_DIR=$ILM_METADATA_PATH
#APP_NAME=$1
SLEEP_TIME=1

# Load IDV Environment
source "$IDV_HOME/ssaenv.sh"

log_init "$LOG_PATH/app_table_list_$(date '+%Y%m%d_%H%M%S').log"

log INFO "Reading Application list..."

APP_LIST=$(cat "$OUTPUT_DIR/application_list.txt")

# 2. Loop through each App and save tables to $APP_table_list.txt
for APP in $APP_LIST; do
    log INFO "Processing Application: \t$APP"
    RAW_FILE="${OUTPUT_DIR}/${APP}_table_list.raw"
	FINAL_FILE="${OUTPUT_DIR}/${APP}_table_list.csv"
    # Run ssaadmin, filter for table names, and redirect to file
ssaadmin "$ADMIN_USER/$ADMIN_PASS" <<EOF > $RAW_FILE
set db $APP
maxlen 0
tables
exit
EOF

	# 1. ALWAYS create/overwrite with the Header first
        echo "DB Name,TID,Name,Type" > "$FINAL_FILE"
		
	# 1. Filter for lines starting with the App name
	# 2. Use awk to format as CSV: DB,TID,TableName,Type
	# 3. Use tr to remove double quotes
	grep "^${APP}" "$RAW_FILE" | awk -v OFS=',' '{print $1,$2,$3,$4}' | tr -d '"' >> "$FINAL_FILE"
	
	chmod 766 $FINAL_FILE
	log INFO "Output generated $FINAL_FILE"
	
	log_line
	TOTAL_COUNT=$(( $(wc -l < "$FINAL_FILE") - 1 ))
	log INFO "Table Count: $TOTAL_COUNT"
	log_line
	
	#Removing Temp File
	rm "$RAW_FILE"
	log INFO "Temp file removed: $RAW_FILE"
	sleep $SLEEP_TIME
done



