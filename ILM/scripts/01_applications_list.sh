#!/bin/bash

# --- Logger ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/logger.sh" || { echo "FATAL: cannot source logger.sh" >&2; exit 1; }
log_trap_int

# --- Configuration ---
. "$SCRIPT_DIR/.conf.ini" || error_exit "Failed to source .conf.ini"
OUTPUT_DIR=$ILM_METADATA_PATH


# Load IDV Environment
source "$IDV_HOME/ssaenv.sh"
mkdir -p "$OUTPUT_DIR"
chmod 766 $OUTPUT_DIR

log_init "$LOG_PATH/applications_list_$(date '+%Y%m%d_%H%M%S').log"

log INFO "Extracting metadata to $OUTPUT_DIR..."

# 1. Get the list of all Archive Folders (Applications)
ssaadmin "$ADMIN_USER/$ADMIN_PASS" <<EOF > $OUTPUT_DIR/all_dbs.raw
dbs
exit
EOF

grep -E '^[[:space:]]+[0-9]+' $OUTPUT_DIR/all_dbs.raw | awk '{print $2}' > $OUTPUT_DIR/application_list.txt
chmod 766 $OUTPUT_DIR/application_list.txt

TOTAL_APP=$(wc -l < $OUTPUT_DIR/application_list.txt)

# Cleanup
rm $OUTPUT_DIR/all_dbs.raw 
log INFO "Complete. All application list are in $OUTPUT_DIR"

log INFO "Total Application $TOTAL_APP"
