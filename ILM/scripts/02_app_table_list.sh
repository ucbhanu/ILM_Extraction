#!/bin/bash

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/.conf.ini"
OUTPUT_DIR=$ILM_METADATA_PATH
#APP_NAME=$1
SLEEP_TIME=1

# Load IDV Environment
source "$IDV_HOME/ssaenv.sh"

echo -e "Reading Application list...\n"

APP_LIST=$(cat "$OUTPUT_DIR/application_list.txt")

# 2. Loop through each App and save tables to $APP_table_list.txt
for APP in $APP_LIST; do
    echo -e "Processing Application: \t$APP"
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
	echo -e "Output generated $FINAL_FILE\n"
	
	echo -e "------------------------------------------------------------"
	TOTAL_COUNT=$(( $(wc -l < "$FINAL_FILE") - 1 ))
	echo -e "Table Count: $TOTAL_COUNT"
	echo -e "------------------------------------------------------------\n"
	
	#Removing Temp File
	rm "$RAW_FILE"
	echo -e "Temp file removed: $RAW_FILE\n\n"
	sleep $SLEEP_TIME
done



