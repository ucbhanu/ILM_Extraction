#!/bin/bash

log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "[$ts] [$level] $msg" | tee -a "${LOG_FILE:-./metadata_export.log}"
}

error_exit() {
    log "ERROR" "$1"
    exit 1
}

normalize_to_unix() {
    local file_path="$1"

    [[ -f "$file_path" ]] || return 0

    awk '{ sub(/\r$/, ""); print }' "$file_path" > "${file_path}.tmp" \
        && mv "${file_path}.tmp" "$file_path"
}

sanitize_ssasql_csv() {
    local csv_file="$1"

    [[ -f "$csv_file" ]] || return 0

    awk '
        {
            sub(/\r$/, "")
        }
        /^[[:space:]]*$/ { next }
        /^Informatica Data Archive\./ { next }
        /^Data Vault Interactive SQL$/ { next }
        /^\(c\) Copyright Informatica LLC/ { next }
        /^See patents at https:\/\/www\.informatica\.com\/legal\/patents\.html$/ { next }
        /^SESSION[[:space:]]+[0-9]+:/ { next }
        /^SQL:[0-9]+>/ { next }
        /^Error state / { next }
        /^ERROR:/ { next }
        /^\047SELECT / { next }
        /^[[:space:]]*SELECT[[:space:]]/ { next }
        /^[[:space:]]*FROM[[:space:]]/ { next }
        /^[[:space:]]*WHERE[[:space:]]/ { next }
        /^[[:space:]]*ORDER[[:space:]]+BY[[:space:]]/ { next }
        /^[[:space:]]*CASE[[:space:]]+WHEN[[:space:]]/ { next }
        { print }
    ' "$csv_file" > "${csv_file}.tmp" && mv "${csv_file}.tmp" "$csv_file"
}

sanitize_ssaadmin_raw() {
    local raw_file="$1"

    [[ -f "$raw_file" ]] || return 0

    awk '
        {
            sub(/\r$/, "")
        }
        /^[[:space:]]*$/ { next }
        /^Informatica Data Archive\./ { next }
        /^Data Vault Administrator/ { next }
        /^\(c\) Copyright Informatica LLC/ { next }
        /^See patents at https:\/\/www\.informatica\.com\/legal\/patents\.html$/ { next }
        /^The admin<host:/ { next }
        { print }
    ' "$raw_file" > "${raw_file}.tmp" && mv "${raw_file}.tmp" "$raw_file"
}

export_ssasql_csv() {
    local sql_query="$1"
    local out_file="$2"
    local raw_file="${out_file}.raw"

    rm -f "$out_file" "$raw_file"

    if ! ssasql fas ADM "$DB_USER/$DB_PASS" <<EOF >"$raw_file" 2>&1
alter session set systemcatalog=1;
.set width 1048576;
.set long 1048576;
.export {$sql_query} into '$out_file' CSV;
.exit;
EOF
    then
        normalize_to_unix "$raw_file"
        log "ERROR" "ssasql failed while exporting $(basename "$out_file")"
        log "ERROR" "ssasql output: $(tail -n 12 "$raw_file" 2>/dev/null | tr '\n' ' ')"
        return 1
    fi

    normalize_to_unix "$raw_file"

    if grep -qiE 'Error state|ERROR:|parse error' "$raw_file"; then
        log "ERROR" "SQL parse/runtime error while exporting $(basename "$out_file")"
        log "ERROR" "ssasql output: $(tail -n 12 "$raw_file" 2>/dev/null | tr '\n' ' ')"
        return 1
    fi

    if [[ ! -f "$out_file" ]]; then
        if grep -qiE '0 rows fetched|no rows selected' "$raw_file"; then
            : > "$out_file"
        else
            log "ERROR" "ssasql did not create $(basename "$out_file") and no empty-result marker was found"
            log "ERROR" "ssasql output: $(tail -n 12 "$raw_file" 2>/dev/null | tr '\n' ' ')"
            return 1
        fi
    fi

    normalize_to_unix "$out_file"
    sanitize_ssasql_csv "$out_file"

    if grep -qiE '^[[:space:]]*(SELECT|FROM|WHERE|ORDER[[:space:]]+BY|CASE[[:space:]]+WHEN)[[:space:]]' "$out_file"; then
        log "ERROR" "Detected SQL text leakage into $(basename "$out_file")"
        return 1
    fi

    rm -f "$raw_file"
    return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! . "$SCRIPT_DIR/.conf.ini"; then
    error_exit "Failed to source conf.ini"
fi
if ! source "$IDV_HOME/ssaenv.sh"; then
    error_exit "Failed to source $IDV_HOME/ssaenv.sh"
fi

if [[ -z "${ADMIN_USER:-}" || -z "${ADMIN_PASS:-}" ]]; then
    error_exit "ADMIN_USER/ADMIN_PASS are not set in .conf.ini"
fi

OUTPUT_DIR=$ILM_METADATA_PATH
mkdir -p "$OUTPUT_DIR" || error_exit "Failed to create $OUTPUT_DIR"
chmod 777 "$OUTPUT_DIR"

SCRIPT_START_TIME=$(date +%s)
log "INFO" "Starting ILM Metadata Export to $OUTPUT_DIR ..."

ADM_EQ_COND="UPPER(TRIM(d.NAME)) = 'ADM'"
ADM_NE_COND="UPPER(TRIM(d.NAME)) <> 'ADM'"

# ------------------------------------------------------------------
# 0. Discover catalog layout (for compatibility across environments)
# ------------------------------------------------------------------
log "INFO" "[0/6] Discovering system catalog tables/columns ..."

if ! export_ssasql_csv "SELECT s.NAME, t.NAME, t.TID FROM cat_databases d, cat_schemas s, cat_tables t WHERE d.DBID = s.DBID AND s.schid = t.schid AND $ADM_EQ_COND ORDER BY s.NAME, t.NAME" "$OUTPUT_DIR/catalog_tables_list.csv"; then
    error_exit "Failed to export catalog_tables_list.csv"
fi
sed -i '/^SCHEMA_NAME,TABLE_NAME,TID$/d' "$OUTPUT_DIR/catalog_tables_list.csv"
sed -i '1i SCHEMA_NAME,TABLE_NAME,TID' "$OUTPUT_DIR/catalog_tables_list.csv"

# Fallback: some environments do not expose ADM exactly as expected.
if [[ $(tail -n +2 "$OUTPUT_DIR/catalog_tables_list.csv" | wc -l) -eq 0 ]]; then
    log "WARN" "catalog_tables_list.csv is empty with ADM filter - retrying without DB-name filter"
    if ! export_ssasql_csv "SELECT s.NAME, t.NAME, t.TID FROM cat_databases d, cat_schemas s, cat_tables t WHERE d.DBID = s.DBID AND s.schid = t.schid ORDER BY s.NAME, t.NAME" "$OUTPUT_DIR/catalog_tables_list.csv"; then
        error_exit "Failed fallback export for catalog_tables_list.csv"
    fi
    sed -i '/^SCHEMA_NAME,TABLE_NAME,TID$/d' "$OUTPUT_DIR/catalog_tables_list.csv"
    sed -i '1i SCHEMA_NAME,TABLE_NAME,TID' "$OUTPUT_DIR/catalog_tables_list.csv"
fi

if ! export_ssasql_csv "SELECT s.NAME, t.NAME, c.NAME, c.COLNO FROM cat_databases d, cat_schemas s, cat_tables t, cat_columns c WHERE d.DBID = s.DBID AND s.schid = t.schid AND c.TID = t.TID AND $ADM_EQ_COND AND UPPER(TRIM(t.NAME)) = 'CAT_TABLES' ORDER BY s.NAME, t.NAME, c.COLNO" "$OUTPUT_DIR/cat_tables_columns.csv"; then
    error_exit "Failed to export cat_tables_columns.csv"
fi
sed -i '/^SCHEMA_NAME,TABLE_NAME,COLUMN_NAME,COLUMN_ORDER$/d' "$OUTPUT_DIR/cat_tables_columns.csv"
sed -i '1i SCHEMA_NAME,TABLE_NAME,COLUMN_NAME,COLUMN_ORDER' "$OUTPUT_DIR/cat_tables_columns.csv"

if [[ $(tail -n +2 "$OUTPUT_DIR/cat_tables_columns.csv" | wc -l) -eq 0 ]]; then
    log "WARN" "cat_tables_columns.csv is empty with ADM filter - retrying without DB-name filter"
    if ! export_ssasql_csv "SELECT s.NAME, t.NAME, c.NAME, c.COLNO FROM cat_databases d, cat_schemas s, cat_tables t, cat_columns c WHERE d.DBID = s.DBID AND s.schid = t.schid AND c.TID = t.TID AND UPPER(TRIM(t.NAME)) = 'CAT_TABLES' ORDER BY s.NAME, t.NAME, c.COLNO" "$OUTPUT_DIR/cat_tables_columns.csv"; then
        error_exit "Failed fallback export for cat_tables_columns.csv"
    fi
    sed -i '/^SCHEMA_NAME,TABLE_NAME,COLUMN_NAME,COLUMN_ORDER$/d' "$OUTPUT_DIR/cat_tables_columns.csv"
    sed -i '1i SCHEMA_NAME,TABLE_NAME,COLUMN_NAME,COLUMN_ORDER' "$OUTPUT_DIR/cat_tables_columns.csv"
fi

HAS_CAT_TABLES_TYPE=0
HAS_CAT_TABLES_CREATOR=0

if awk -F',' 'NR>1 {gsub(/\r/,"",$3); if (toupper($3)=="TYPE") found=1} END{exit(found?0:1)}' "$OUTPUT_DIR/cat_tables_columns.csv"; then
    HAS_CAT_TABLES_TYPE=1
fi

if awk -F',' 'NR>1 {gsub(/\r/,"",$3); if (toupper($3)=="CREATOR") found=1} END{exit(found?0:1)}' "$OUTPUT_DIR/cat_tables_columns.csv"; then
    HAS_CAT_TABLES_CREATOR=1
fi

TABLE_TYPE_EXPR="''"
TABLE_CREATOR_EXPR="''"

if [[ "$HAS_CAT_TABLES_TYPE" -eq 1 ]]; then
    TABLE_TYPE_EXPR="t.TYPE"
fi
if [[ "$HAS_CAT_TABLES_CREATOR" -eq 1 ]]; then
    TABLE_CREATOR_EXPR="t.CREATOR"
fi

log "INFO" "[0/6] Catalog discovery complete (CAT_TABLES.TYPE=$HAS_CAT_TABLES_TYPE, CAT_TABLES.CREATOR=$HAS_CAT_TABLES_CREATOR)"

# ------------------------------------------------------------------
# 1. Export ALL Databases (Applications)
# ------------------------------------------------------------------
log "INFO" "[1/6] Extracting all databases ..."

if ! ssaadmin "$ADMIN_USER/$ADMIN_PASS" <<'EOF' > "$OUTPUT_DIR/all_databases.raw" 2>&1
maxlen 0
dbs
exit
EOF
then
    error_exit "Failed to export all_databases.raw via ssaadmin"
fi

normalize_to_unix "$OUTPUT_DIR/all_databases.raw"
if grep -qiE 'Invalid user name|Login incorrect|Authentication failed' "$OUTPUT_DIR/all_databases.raw"; then
    error_exit "ssaadmin login failed while exporting all_databases.raw"
fi
sanitize_ssaadmin_raw "$OUTPUT_DIR/all_databases.raw"

# Also query via ssasql for structured output
if ! export_ssasql_csv "SELECT d.DBID, d.NAME, d.CREATOR FROM cat_databases d ORDER BY d.NAME" "$OUTPUT_DIR/all_databases.csv"; then
    error_exit "Failed to export all_databases.csv"
fi

sed -i '/^DBID,DB_NAME,CREATOR$/d' "$OUTPUT_DIR/all_databases.csv"
sed -i '1i DBID,DB_NAME,CREATOR' "$OUTPUT_DIR/all_databases.csv"
rm -f "$OUTPUT_DIR/all_databases.raw"
log "INFO" "[1/6] Done: $OUTPUT_DIR/all_databases.csv"

# ------------------------------------------------------------------
# 2. Export ALL System Tables (ADM catalog tables)
# ------------------------------------------------------------------
log "INFO" "[2/6] Extracting all system tables ..."

if ! export_ssasql_csv "SELECT d.NAME, s.NAME, t.NAME, t.TID, $TABLE_TYPE_EXPR, $TABLE_CREATOR_EXPR FROM cat_databases d, cat_schemas s, cat_tables t WHERE d.DBID = s.DBID AND s.schid = t.schid AND $ADM_EQ_COND ORDER BY s.NAME, t.NAME" "$OUTPUT_DIR/all_system_tables.csv"; then
    error_exit "Failed to export all_system_tables.csv"
fi

sed -i '/^DB_NAME,SCHEMA_NAME,TABLE_NAME,TID,TYPE,CREATOR$/d' "$OUTPUT_DIR/all_system_tables.csv"
sed -i '1i DB_NAME,SCHEMA_NAME,TABLE_NAME,TID,TYPE,CREATOR' "$OUTPUT_DIR/all_system_tables.csv"
log "INFO" "[2/6] Done: $OUTPUT_DIR/all_system_tables.csv"

# ------------------------------------------------------------------
# 3. Export ALL User Tables (non-ADM databases)
# ------------------------------------------------------------------
log "INFO" "[3/6] Extracting all user tables ..."

if ! export_ssasql_csv "SELECT d.NAME, s.NAME, t.NAME, t.TID, $TABLE_TYPE_EXPR, $TABLE_CREATOR_EXPR FROM cat_databases d, cat_schemas s, cat_tables t WHERE d.DBID = s.DBID AND s.schid = t.schid AND $ADM_NE_COND ORDER BY d.NAME, s.NAME, t.NAME" "$OUTPUT_DIR/all_user_tables.csv"; then
    error_exit "Failed to export all_user_tables.csv"
fi

sed -i '/^DB_NAME,SCHEMA_NAME,TABLE_NAME,TID,TYPE,CREATOR$/d' "$OUTPUT_DIR/all_user_tables.csv"
sed -i '1i DB_NAME,SCHEMA_NAME,TABLE_NAME,TID,TYPE,CREATOR' "$OUTPUT_DIR/all_user_tables.csv"
log "INFO" "[3/6] Done: $OUTPUT_DIR/all_user_tables.csv"

# ------------------------------------------------------------------
# 4. Export ALL Tables (combined, with category)
# ------------------------------------------------------------------
log "INFO" "[4/6] Extracting all tables (combined) ..."

if ! export_ssasql_csv "SELECT d.NAME, s.NAME, t.NAME, t.TID, $TABLE_TYPE_EXPR, CASE WHEN $ADM_EQ_COND THEN 'SYSTEM' ELSE 'USER' END FROM cat_databases d, cat_schemas s, cat_tables t WHERE d.DBID = s.DBID AND s.schid = t.schid ORDER BY d.NAME, s.NAME, t.NAME" "$OUTPUT_DIR/all_tables_combined.csv"; then
    error_exit "Failed to export all_tables_combined.csv"
fi

sed -i '/^DB_NAME,SCHEMA_NAME,TABLE_NAME,TID,TYPE,TABLE_CATEGORY$/d' "$OUTPUT_DIR/all_tables_combined.csv"
sed -i '1i DB_NAME,SCHEMA_NAME,TABLE_NAME,TID,TYPE,TABLE_CATEGORY' "$OUTPUT_DIR/all_tables_combined.csv"
log "INFO" "[4/6] Done: $OUTPUT_DIR/all_tables_combined.csv"

# Dedicated table list export (DB, schema, table) for downstream consumers.
if ! export_ssasql_csv "SELECT d.NAME AS DB_NAME, s.NAME AS SCHEMA_NAME, t.NAME AS TABLE_NAME FROM cat_tables t JOIN cat_schemas s ON t.SCHID = s.SCHID AND t.DBID = s.DBID JOIN cat_databases d ON t.DBID = d.DBID ORDER BY d.NAME, s.NAME, t.NAME" "$OUTPUT_DIR/all_table_list.csv"; then
    error_exit "Failed to export all_table_list.csv"
fi

sed -i '/^DB_NAME,SCHEMA_NAME,TABLE_NAME$/d' "$OUTPUT_DIR/all_table_list.csv"
sed -i '1i DB_NAME,SCHEMA_NAME,TABLE_NAME' "$OUTPUT_DIR/all_table_list.csv"
log "INFO" "[4/6] Done: $OUTPUT_DIR/all_table_list.csv"

# ------------------------------------------------------------------
# 5. Export Users (via ssaadmin)
# ------------------------------------------------------------------
log "INFO" "[5/6] Extracting users ..."

if ! ssaadmin "$ADMIN_USER/$ADMIN_PASS" <<'EOF' > "$OUTPUT_DIR/all_users.raw" 2>&1
maxlen 0
users
exit
EOF
then
    error_exit "Failed to export all_users.raw via ssaadmin"
fi

normalize_to_unix "$OUTPUT_DIR/all_users.raw"
if grep -qiE 'Invalid user name|Login incorrect|Authentication failed' "$OUTPUT_DIR/all_users.raw"; then
    error_exit "ssaadmin login failed while exporting all_users.raw"
fi
sanitize_ssaadmin_raw "$OUTPUT_DIR/all_users.raw"

awk '
BEGIN { OFS=","; print "ID,NAME,DEFAULT_DB,DEFAULT_SCHEMA,CREATOR,DBA" }
{
    sub(/\r$/, "")
}
/^[[:space:]]*[0-9]+[[:space:]]+/ {
    id=$1; name=$2; ddb=$3; dsch=$4; creator=$5; dba=$6;
    if (dba=="") dba="";
    print id,name,ddb,dsch,creator,dba
}
' "$OUTPUT_DIR/all_users.raw" > "$OUTPUT_DIR/all_users.csv"
normalize_to_unix "$OUTPUT_DIR/all_users.csv"
sed -i '/^ID,NAME,DEFAULT_DB,DEFAULT_SCHEMA,CREATOR,DBA$/d' "$OUTPUT_DIR/all_users.csv"
sed -i '1i ID,NAME,DEFAULT_DB,DEFAULT_SCHEMA,CREATOR,DBA' "$OUTPUT_DIR/all_users.csv"
rm -f "$OUTPUT_DIR/all_users.raw"

log "INFO" "[5/6] Done: $OUTPUT_DIR/all_users.csv"

# ------------------------------------------------------------------
# 6. Export Catalog Table Listing (what system tables exist)
# ------------------------------------------------------------------
log "INFO" "[6/6] Extracting catalog table listing ..."

# Already exported during [0/6] discovery; keep this step for backwards-compatible logging.
log "INFO" "[6/6] Done: $OUTPUT_DIR/catalog_tables_list.csv"

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
TOTAL_DBS=$(tail -n +2 "$OUTPUT_DIR/all_databases.csv" | wc -l)
TOTAL_SYS_TABLES=$(tail -n +2 "$OUTPUT_DIR/all_system_tables.csv" | wc -l)
TOTAL_USER_TABLES=$(tail -n +2 "$OUTPUT_DIR/all_user_tables.csv" | wc -l)
TOTAL_TABLE_LIST=$(tail -n +2 "$OUTPUT_DIR/all_table_list.csv" | wc -l)
TOTAL_USERS=$(tail -n +2 "$OUTPUT_DIR/all_users.csv" | wc -l)
TOTAL_CATALOG_TABLES=$(tail -n +2 "$OUTPUT_DIR/catalog_tables_list.csv" | wc -l)
TOTAL_CAT_TABLES_COLUMNS=$(tail -n +2 "$OUTPUT_DIR/cat_tables_columns.csv" | wc -l)

SCRIPT_END_TIME=$(date +%s)
TOTAL_TIME=$((SCRIPT_END_TIME - SCRIPT_START_TIME))

log "INFO" "******************************************************************"
log "INFO" "                ILM Metadata Export Complete"
log "INFO" "******************************************************************"
log "INFO" "  Databases (Applications) : $TOTAL_DBS"
log "INFO" "  System Tables (ADM)      : $TOTAL_SYS_TABLES"
log "INFO" "  User Tables (App Data)   : $TOTAL_USER_TABLES"
log "INFO" "  Table List (All DBs)     : $TOTAL_TABLE_LIST"
log "INFO" "  Users                    : $TOTAL_USERS"
log "INFO" "  Catalog Tables Available : $TOTAL_CATALOG_TABLES"
log "INFO" "  CAT_TABLES Columns Found : $TOTAL_CAT_TABLES_COLUMNS"
log "INFO" "  Output Directory         : $OUTPUT_DIR"
log "INFO" "  Total Time               : ${TOTAL_TIME} seconds"
log "INFO" "******************************************************************"
log "INFO" "  Output Files:"
log "INFO" "    all_databases.csv"
log "INFO" "    all_system_tables.csv"
log "INFO" "    all_user_tables.csv"
log "INFO" "    all_tables_combined.csv"
log "INFO" "    all_table_list.csv"
log "INFO" "    all_users.csv"
log "INFO" "    catalog_tables_list.csv"
log "INFO" "    cat_tables_columns.csv"
log "INFO" "******************************************************************"
