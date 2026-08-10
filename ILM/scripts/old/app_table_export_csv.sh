#!/bin/bash

# --- Configuration ---
. ./conf.ini
source "$IDV_HOME/ssaenv.sh"

# 1. Input Parameter
TABLE_LIST=$1

if [[ -z "$TABLE_LIST" || ! -f "$TABLE_LIST" ]]; then
    echo "Usage: $0 <table_list.csv>"
    exit 1
fi

echo -e "Starting Batch Export into DB-specific folders...\n"

# 2. Iterate through the CSV (skipping header)
tail -n +2 "$TABLE_LIST" | while IFS=',' read -r DB_NAME TID TABLE_NAME TYPE || [[ -n "$DB_NAME" ]]; do
    
    # Clean variables
    DB_NAME=$(echo "$DB_NAME" | xargs)
    TABLE_NAME=$(echo "$TABLE_NAME" | xargs | tr -d '"')

    # 3. Create the DB folder inside your Export Path
    # mkdir -p ensures the script doesn't fail if the folder exists
    TARGET_DIR="$EXPORT_PATH/$DB_NAME"
    mkdir -p $TARGET_DIR
	chmod 766 $TARGET_DIR

    echo "--------------------------------------------------"
    echo "DB: $DB_NAME | Table: $TABLE_NAME"
    echo "Saving to: $TARGET_DIR"

	# 4. Clean the table name
	# Example: Converts DBO.MY_TABLE to "DBO"."MY_TABLE"
	# Strip the DB prefix from the table name for the SELECT statement
	#TABLE_ONLY=$(echo "$TABLE_NAME" | sed "s/^${DB_NAME}\.//" | tr -d '"')
	#CLEAN_TABLE=$(echo "$TABLE_NAME" | xargs | tr -d '"' | sed 's/\./"."/g')
	quoted_table=$(echo "$TABLE_NAME" | sed 's/\./"."/g' | sed 's/^/"/;s/$/"/')
	echo "Exporting table: $quoted_table"
	
	# 5. Run ssasql with explicit schema setting
ssasql fas "$DB_NAME" "$DB_USER/$DB_PASS" <<EOF 
alter session set systemcatalog=0;

.export {SELECT * FROM $quoted_table} into '$TARGET_DIR/${TABLE_NAME}.csv' CSV;
.exit;
EOF

	# 6. Real Error Check (Looking at the captured log)
	#if grep -i "Error|not found|Failure" "$TMP_LOG/temp.log" > /dev/null; then
	#	echo "FAILED: $TABLE_NAME (Check $TMP_LOG for details)"
	#else
	#	echo "SUCCESS: $TABLE_NAME exported to $TARGET_DIR"
	#fi
sleep 1
done

echo "Batch processing complete."

