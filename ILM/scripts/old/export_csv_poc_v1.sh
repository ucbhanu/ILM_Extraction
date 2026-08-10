#!/bin/bash

# --- CONFIGURATION ---
# Path to your IDV installation
. ./conf.ini

# 1. Source Environment
if [ -f "$IDV_HOME/ssaenv.sh" ]; then
    source "$IDV_HOME/ssaenv.sh"
else
    echo "Error: ssaenv.sh not found in $IDV_HOME"
    exit 1
fi

# 2. Run ssasql and pass commands
# We use '<<-EOF' to feed commands into the interactive tool
ssasql fas "$DB_NAME" "$DB_USER/$DB_PASS" <<-EOF
    -- Metadata Exploration
    alter session set systemcatalog=on;
    SELECT name FROM cat_databases;
    SELECT d.name, s.name, t.name 
    FROM cat_databases d, cat_schemas s, cat_tables t 
    WHERE d.dbid = s.dbid AND s.schid = t.schid;
    alter session set systemcatalog=0;

    -- Data Preview
    select * from "DBO"."AM_ATTACHMENTS" limit 10;

    -- Data Export
    .export {SELECT ATTACHMENT_DIRECTORY,ATTACHMENT_NAME FROM "DBO"."AM_ATTACHMENTS"} into '$EXPORT_PATH/AM_ATTACHMENTS.csv' CSV;
    .export {SELECT * FROM "LIFEDOC_QA"."DM_RELATION_QA"} into '$EXPORT_PATH/DM_RELATION_QA.csv' CSV;

    .exit;
EOF

echo "Export process completed at $(date)"

