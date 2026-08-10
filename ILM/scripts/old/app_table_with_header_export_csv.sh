#!/bin/bash

# --- Configuration ---
. ./conf.ini
source "$IDV_HOME/ssaenv.sh"

# 1. Input Parameter
TABLE_LIST=$1
COUNTER=1

if [[ -z "$TABLE_LIST" || ! -f "$TABLE_LIST" ]]; then
    echo -e "Usage: $0 <table_list.csv>"
    exit 1
fi
echo -e "**************************************************************************************************************************************"
echo -e "        				Starting Batch Export into DB-specific folders..."
echo -e "**************************************************************************************************************************************"
# 2. Iterate through the CSV (skipping header)
tail -n +2 "$TABLE_LIST" | while IFS=',' read -r DB_NAME TID TABLE_NAME TYPE || [[ -n "$DB_NAME" ]]; do
    
    # Clean variables
    DB_NAME=$(echo -e "$DB_NAME" | xargs)
    TABLE_NAME=$(echo -e "$TABLE_NAME" | xargs | tr -d '"')
	SCHEMA_PART=$(echo -e $TABLE_NAME | cut -d. -f1)
    TABLE_PART=$(echo -e $TABLE_NAME | cut -d. -f2)
    #FILE_NAME="${SCHEMA_PART}_${TABLE_PART}.csv"


    # 3. Create the DB folder inside your Export Path
    # mkdir -p ensures the script doesn't fail if the folder exists
    TARGET_DIR="$EXPORT_PATH/$DB_NAME"
    mkdir -p $TARGET_DIR
	chmod 766 $TARGET_DIR

    echo -e "\n----------------------------------------------------------------------------------------------------"
    echo -e "     [$COUNTER]  DB: $DB_NAME | Table: $TABLE_NAME"
	echo -e "----------------------------------------------------------------------------------------------------\n"
    echo -e "Saving to: $TARGET_DIR"

	# 4. Clean the table name
	# Example: Converts DBO.MY_TABLE to "DBO"."MY_TABLE"
	quoted_table=$(echo -e "$TABLE_NAME" | sed 's/\./"."/g' | sed 's/^/"/;s/$/"/')
	echo -e "Exporting table: $quoted_table"
	
	# 5. Get Column Headers
ssasql fas "$DB_NAME" "$DB_USER/$DB_PASS" <<EOF >$TARGET_DIR/${TABLE_NAME}_header.raw
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

	# 6. convert to csv header
	echo -e "Header generation..."
	columns=$(sed -n '26,$p' "$TARGET_DIR/${TABLE_NAME}_header.raw" | head -n -2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | paste -s -d ',' -)
	#echo -e "$columns" > "$TARGET_DIR/${TABLE_NAME}.csv"

	
	# 7. Remove the raw/temp file
	echo -e "Remove the raw/temp file..."
	rm "$TARGET_DIR/${TABLE_NAME}_header.raw"
	
	# 8. Run ssasql with explicit schema setting
	echo -e "Table Data extraction started..."
ssasql fas "$DB_NAME" "$DB_USER/$DB_PASS" <<EOF 
alter session set systemcatalog=0;
.set width 1048576;
.set long 1048576;

.export bulk {SELECT $columns FROM $quoted_table} into '$TARGET_DIR/${TABLE_NAME}.csv' CSV;
.exit;
EOF

	# 9. merge column with data
	echo -e "Merging Header with Table Data..."
	sed -i "1i $columns" "$TARGET_DIR/${TABLE_NAME}.csv"
	
	echo -e "Table ${TABLE_NAME} exported."
	echo -e "----------------------------------------------------------------------------------------------------"
	((COUNTER++))
sleep 1
done
echo -e "**************************************************************************************************************************************"
echo -e "						Batch processing complete."
echo -e "**************************************************************************************************************************************"

