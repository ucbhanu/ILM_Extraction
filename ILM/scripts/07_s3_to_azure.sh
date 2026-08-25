#!/bin/bash
# =============================================================================
#  07_s3_to_azure.sh  —  Transfer ILM export data from AWS S3 to Azure Storage
#
#  ⚠  FUTURE SCOPE — NOT ACTIVE
#     The S3 -> Azure movement is planned for a later phase and is deliberately
#     NOT called by ilm_pipeline.sh. The Azure configuration block in .conf.ini
#     is commented out, so this script will refuse to run until it is enabled.
#
#     To activate later:
#       1. Uncomment the AZURE_* block in .conf.ini and fill in the values
#       2. Set AZURE_TRANSFER_ENABLED="true"
#       3. Install azcopy (and optionally the az CLI for verification)
#
#  Copies the staged ILM export (data, metadata, evidence, audit trail and
#  logs) from the S3 stage prefix into an Azure Blob Storage container, then
#  reconciles the object counts and records the transfer in the audit trail.
#
#  Transfer modes (AZURE_TRANSFER_MODE in .conf.ini):
#    direct  azcopy streams S3 -> Azure server side (fastest, needs AWS keys
#            exported for azcopy: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY)
#    staged  aws s3 sync -> local staging dir -> azcopy/az upload -> cleanup
#            (works with IAM roles and restricted egress)
#
#  Authentication to Azure (AZURE_AUTH_MODE in .conf.ini):
#    sas   Shared Access Signature. Token read from $AZURE_SAS_TOKEN or from
#          the file named by $AZURE_SAS_FILE. NEVER hard-code it in .conf.ini.
#    spn   Service principal via azcopy login (AZURE_TENANT_ID,
#          AZURE_CLIENT_ID and AZURE_CLIENT_SECRET from the environment).
#    msi   Managed identity via azcopy login --identity.
#
#  SECURITY: SAS tokens and client secrets are never written to the log. All
#            URLs are redacted before being logged.
#
#  Usage:
#    bash 07_s3_to_azure.sh                       # transfer the whole stage
#    bash 07_s3_to_azure.sh --prefix LIFEDOC_QA   # one application only
#    bash 07_s3_to_azure.sh --dry-run             # plan only, no data moved
#
#  Exit codes:
#    0 transfer completed and reconciled
#    1 transfer failed or reconciliation mismatch
#    2 usage / configuration error
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Libraries ---
. "$SCRIPT_DIR/logger.sh"    || { echo "FATAL: cannot source logger.sh" >&2; exit 2; }
. "$SCRIPT_DIR/lib_trace.sh" || { echo "FATAL: cannot source lib_trace.sh" >&2; exit 2; }
. "$SCRIPT_DIR/lib_s3.sh"    || { echo "FATAL: cannot source lib_s3.sh" >&2; exit 2; }
log_trap_int

# --- Configuration ---
if ! . "$SCRIPT_DIR/.conf.ini"; then
    error_exit "Failed to source .conf.ini" 2
fi

TRACE_SCRIPT="07_s3_to_azure.sh"

# =============================================================================
# FEATURE FLAG — this capability is future scope and disabled by default
# =============================================================================
if [[ "${AZURE_TRANSFER_ENABLED:-false}" != "true" ]]; then
    echo ""
    echo "  07_s3_to_azure.sh is FUTURE SCOPE and is currently disabled."
    echo ""
    echo "  The S3 -> Azure movement is not part of the active pipeline."
    echo "  To enable it:"
    echo "    1. Uncomment the AZURE_* block in .conf.ini and fill in the values"
    echo "    2. Set AZURE_TRANSFER_ENABLED=\"true\""
    echo ""
    exit 0
fi

# =============================================================================
# ARGUMENTS
# =============================================================================
SOURCE_PREFIX=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)  SOURCE_PREFIX="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help)
            echo "Usage: bash 07_s3_to_azure.sh [--prefix <APP_NAME>] [--dry-run]"
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

# =============================================================================
# LOGGING AND TRACEABILITY
# =============================================================================
LOG_TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
log_init "$LOG_PATH/S3_TO_AZURE_${LOG_TIMESTAMP}.log" \
    || error_exit "Cannot initialise log file in $LOG_PATH"

trace_init "$ILM_METADATA_PATH" "" \
    || error_exit "Cannot initialise traceability context"

# =============================================================================
# VALIDATE AZURE CONFIGURATION
# =============================================================================
MISSING=()
[[ -z "${AZURE_STORAGE_ACCOUNT:-}" || "${AZURE_STORAGE_ACCOUNT}" == "<CHANGE_ME>" ]] && MISSING+=("AZURE_STORAGE_ACCOUNT")
[[ -z "${AZURE_CONTAINER:-}"       || "${AZURE_CONTAINER}"       == "<CHANGE_ME>" ]] && MISSING+=("AZURE_CONTAINER")
[[ -z "${AZURE_AUTH_MODE:-}"       || "${AZURE_AUTH_MODE}"       == "<CHANGE_ME>" ]] && MISSING+=("AZURE_AUTH_MODE")
[[ -z "${AZURE_TRANSFER_MODE:-}"   || "${AZURE_TRANSFER_MODE}"   == "<CHANGE_ME>" ]] && MISSING+=("AZURE_TRANSFER_MODE")

if (( ${#MISSING[@]} > 0 )); then
    log ERROR "Missing Azure configuration in .conf.ini:"
    for v in "${MISSING[@]}"; do log ERROR "  - $v"; done
    error_exit "Fill in the Azure section of .conf.ini before running." 2
fi

# --- Resolve the SAS token without ever logging it --------------------------
SAS_TOKEN=""
if [[ "$AZURE_AUTH_MODE" == "sas" ]]; then
    if [[ -n "${AZURE_SAS_TOKEN:-}" ]]; then
        SAS_TOKEN="$AZURE_SAS_TOKEN"
    elif [[ -n "${AZURE_SAS_FILE:-}" && -f "${AZURE_SAS_FILE}" ]]; then
        SAS_TOKEN="$(head -n 1 "$AZURE_SAS_FILE")"
    fi
    [[ -z "$SAS_TOKEN" ]] && error_exit \
        "AZURE_AUTH_MODE=sas but no token found in \$AZURE_SAS_TOKEN or \$AZURE_SAS_FILE" 2
    SAS_TOKEN="${SAS_TOKEN#\?}"   # tolerate a leading '?'
fi

# --- Redact secrets from anything we print ----------------------------------
redact() {
    sed -e 's/\(sig=\)[^&"[:space:]]*/\1***REDACTED***/g' \
        -e 's/\(se=\)[^&"[:space:]]*/\1***/g' \
        -e 's/?sv=[^"[:space:]]*/?***SAS-REDACTED***/g'
}

# =============================================================================
# TOOLING
# =============================================================================
AZCOPY_BIN="${AZCOPY_BIN:-azcopy}"
if ! command -v "$AZCOPY_BIN" >/dev/null 2>&1; then
    error_exit "azcopy not found. Install it or set AZCOPY_BIN in .conf.ini" 2
fi
log INFO "azcopy: $("$AZCOPY_BIN" --version 2>&1 | head -n 1)"

command -v aws >/dev/null 2>&1 || error_exit "AWS CLI not found" 2

# =============================================================================
# SOURCE AND TARGET
# =============================================================================
S3_SOURCE="$TARGET_S3_STAGE"
AZ_PREFIX="${AZURE_DEST_PREFIX:-ilm-export}"

if [[ -n "$SOURCE_PREFIX" ]]; then
    S3_SOURCE="$TARGET_S3_STAGE/$SOURCE_PREFIX"
    AZ_PREFIX="$AZ_PREFIX/$SOURCE_PREFIX"
fi

# s3://bucket/key -> bucket + key
S3_NO_SCHEME="${S3_SOURCE#s3://}"
S3_BUCKET="${S3_NO_SCHEME%%/*}"
S3_KEY="${S3_NO_SCHEME#*/}"
[[ "$S3_KEY" == "$S3_BUCKET" ]] && S3_KEY=""

AZ_BASE_URL="https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_CONTAINER}/${AZ_PREFIX}"

log INFO "############################################################"
log INFO "#  S3 -> AZURE TRANSFER"
log INFO "############################################################"
log INFO "  Run ID          : $RUN_ID"
log INFO "  Source (S3)     : $S3_SOURCE"
log INFO "  Target (Azure)  : $AZ_BASE_URL"
log INFO "  Transfer mode   : $AZURE_TRANSFER_MODE"
log INFO "  Auth mode       : $AZURE_AUTH_MODE"
log INFO "  Dry run         : $DRY_RUN"
log INFO "  Started (UTC)   : $(trace_utc)"
log INFO "############################################################"

audit_event "s3_to_azure" "${SOURCE_PREFIX:-ALL}" "transfer" "$S3_SOURCE" "start" \
    "IN_PROGRESS" "" "" "Target $AZ_BASE_URL mode=$AZURE_TRANSFER_MODE"

# =============================================================================
# SOURCE INVENTORY
# =============================================================================
log INFO "Counting source objects..."
S3_OBJECT_COUNT="$(s3_count "$S3_SOURCE/")"
S3_TOTAL_BYTES="$(aws s3 ls "$S3_SOURCE/" --recursive $(s3_flags) 2>/dev/null \
                  | awk '{s+=$3} END {print s+0}')"
log INFO "  Source objects  : $S3_OBJECT_COUNT"
log INFO "  Source bytes    : $S3_TOTAL_BYTES"

if (( S3_OBJECT_COUNT == 0 )); then
    log WARN "No objects found at $S3_SOURCE - nothing to transfer"
    audit_event "s3_to_azure" "${SOURCE_PREFIX:-ALL}" "transfer" "$S3_SOURCE" "complete" \
        "SKIPPED" "0" "0" "Source empty"
    exit 0
fi

if $DRY_RUN; then
    log INFO "DRY RUN - would transfer $S3_OBJECT_COUNT object(s) to $AZ_BASE_URL"
    audit_event "s3_to_azure" "${SOURCE_PREFIX:-ALL}" "transfer" "$S3_SOURCE" "plan" \
        "DRY_RUN" "$S3_OBJECT_COUNT" "$S3_TOTAL_BYTES" "No data moved"
    exit 0
fi

# =============================================================================
# AZURE AUTHENTICATION
# =============================================================================
AZ_DEST_URL="$AZ_BASE_URL"

case "$AZURE_AUTH_MODE" in
    sas)
        AZ_DEST_URL="${AZ_BASE_URL}?${SAS_TOKEN}"
        log INFO "Azure auth: SAS token (redacted)"
        ;;
    spn)
        [[ -z "${AZURE_TENANT_ID:-}" || -z "${AZURE_CLIENT_ID:-}" || -z "${AZURE_CLIENT_SECRET:-}" ]] && \
            error_exit "AZURE_AUTH_MODE=spn requires AZURE_TENANT_ID, AZURE_CLIENT_ID and AZURE_CLIENT_SECRET" 2
        log INFO "Azure auth: service principal ($AZURE_CLIENT_ID)"
        if ! AZCOPY_SPA_CLIENT_SECRET="$AZURE_CLIENT_SECRET" \
             "$AZCOPY_BIN" login --service-principal \
                --application-id "$AZURE_CLIENT_ID" \
                --tenant-id "$AZURE_TENANT_ID" >/dev/null 2>&1; then
            error_exit "azcopy service principal login failed"
        fi
        ;;
    msi)
        log INFO "Azure auth: managed identity"
        "$AZCOPY_BIN" login --identity >/dev/null 2>&1 \
            || error_exit "azcopy managed identity login failed"
        ;;
    *)
        error_exit "Unsupported AZURE_AUTH_MODE: $AZURE_AUTH_MODE (use sas|spn|msi)" 2
        ;;
esac

TRANSFER_START=$(date +%s)
TRANSFER_OK=true

# =============================================================================
# TRANSFER
# =============================================================================
case "$AZURE_TRANSFER_MODE" in

    direct)
        # azcopy reads the S3 source using these environment variables.
        if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
            AWS_ACCESS_KEY_ID="$(aws configure get aws_access_key_id 2>/dev/null)"
            AWS_SECRET_ACCESS_KEY="$(aws configure get aws_secret_access_key 2>/dev/null)"
            AWS_SESSION_TOKEN="$(aws configure get aws_session_token 2>/dev/null)"
        fi
        if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
            error_exit "direct mode needs AWS access keys for azcopy. Use AZURE_TRANSFER_MODE=staged with IAM roles." 2
        fi
        export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

        S3_URL="https://s3.${AWS_REGION}.amazonaws.com/${S3_BUCKET}/${S3_KEY}"
        log INFO "Transferring directly: $S3_URL -> (azure)"

        if ! "$AZCOPY_BIN" copy "$S3_URL" "$AZ_DEST_URL" \
                --recursive=true --overwrite=ifSourceNewer 2>&1 | redact | tee -a "$LOG_FILE"; then
            TRANSFER_OK=false
        fi
        unset AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
        ;;

    staged)
        STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ilm_azure_XXXXXX")"
        trap 'rm -rf "$STAGE_DIR"' EXIT
        log INFO "Staging locally: $S3_SOURCE -> $STAGE_DIR"

        if ! aws s3 sync "$S3_SOURCE" "$STAGE_DIR" $(s3_flags) >/dev/null 2>&1; then
            error_exit "Failed to stage data from $S3_SOURCE"
        fi

        STAGED_COUNT="$(find "$STAGE_DIR" -type f | wc -l)"
        log INFO "Staged objects  : $STAGED_COUNT"

        if (( STAGED_COUNT != S3_OBJECT_COUNT )); then
            log WARN "Staged count ($STAGED_COUNT) differs from S3 count ($S3_OBJECT_COUNT)"
        fi

        log INFO "Uploading staged data to Azure..."
        if ! "$AZCOPY_BIN" copy "$STAGE_DIR/*" "$AZ_DEST_URL" \
                --recursive=true --overwrite=ifSourceNewer 2>&1 | redact | tee -a "$LOG_FILE"; then
            TRANSFER_OK=false
        fi
        ;;

    *)
        error_exit "Unsupported AZURE_TRANSFER_MODE: $AZURE_TRANSFER_MODE (use direct|staged)" 2
        ;;
esac

TRANSFER_DURATION=$(( $(date +%s) - TRANSFER_START ))

if ! $TRANSFER_OK; then
    audit_event "s3_to_azure" "${SOURCE_PREFIX:-ALL}" "transfer" "$S3_SOURCE" "copy" \
        "FAILED" "$S3_OBJECT_COUNT" "$S3_TOTAL_BYTES" "azcopy reported errors"
    error_exit "Transfer to Azure FAILED - see log: $LOG_FILE"
fi

log INFO "Transfer completed in ${TRANSFER_DURATION}s"

# =============================================================================
# RECONCILIATION  (S3 object count vs Azure blob count)
# =============================================================================
log_line
log INFO "Reconciliation"
log_line

AZ_COUNT="UNKNOWN"
if command -v az >/dev/null 2>&1; then
    if [[ "$AZURE_AUTH_MODE" == "sas" ]]; then
        AZ_COUNT="$(az storage blob list \
            --account-name "$AZURE_STORAGE_ACCOUNT" \
            --container-name "$AZURE_CONTAINER" \
            --prefix "$AZ_PREFIX" \
            --sas-token "$SAS_TOKEN" \
            --query "length(@)" -o tsv 2>/dev/null || echo UNKNOWN)"
    else
        AZ_COUNT="$(az storage blob list \
            --account-name "$AZURE_STORAGE_ACCOUNT" \
            --container-name "$AZURE_CONTAINER" \
            --prefix "$AZ_PREFIX" \
            --auth-mode login \
            --query "length(@)" -o tsv 2>/dev/null || echo UNKNOWN)"
    fi
else
    log WARN "Azure CLI (az) not installed - blob count cannot be verified independently"
fi

log INFO "  S3 objects      : $S3_OBJECT_COUNT"
log INFO "  Azure blobs     : $AZ_COUNT"

RECON_STATUS="PASS"
if [[ "$AZ_COUNT" == "UNKNOWN" ]]; then
    RECON_STATUS="UNVERIFIED"
    log WARN "  Result          : UNVERIFIED (install az CLI to enable verification)"
elif (( AZ_COUNT < S3_OBJECT_COUNT )); then
    RECON_STATUS="FAIL"
    log ERROR "  Result          : FAIL - $(( S3_OBJECT_COUNT - AZ_COUNT )) object(s) missing"
else
    log INFO "  Result          : PASS"
fi

# =============================================================================
# EVIDENCE
# =============================================================================
AZ_RECON_FILE="$EVIDENCE_DIR/azure_transfer_${SOURCE_PREFIX:-ALL}_${LOG_TIMESTAMP}.csv"
{
    printf 'run_id,source_s3,target_azure,object_count_s3,blob_count_azure,bytes_s3,transfer_mode,auth_mode,duration_seconds,status,transferred_utc,transferred_by\n'
    printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
        "$RUN_ID" "$S3_SOURCE" "$AZ_BASE_URL" "$S3_OBJECT_COUNT" "$AZ_COUNT" \
        "$S3_TOTAL_BYTES" "$AZURE_TRANSFER_MODE" "$AZURE_AUTH_MODE" \
        "$TRANSFER_DURATION" "$RECON_STATUS" "$(trace_utc)" "$TRACE_ACTOR"
} > "$AZ_RECON_FILE"

log INFO "Transfer evidence: $AZ_RECON_FILE"

audit_event "s3_to_azure" "${SOURCE_PREFIX:-ALL}" "transfer" "$AZ_BASE_URL" "complete" \
    "$RECON_STATUS" "$S3_OBJECT_COUNT" "$S3_TOTAL_BYTES" \
    "azure_blobs=$AZ_COUNT duration=${TRANSFER_DURATION}s"

# Push the transfer evidence and this log back to S3 for the audit record
s3_upload_file "$AZ_RECON_FILE" \
    "$TARGET_S3_STAGE/_evidence/$RUN_ID/$(basename "$AZ_RECON_FILE")" \
    "azure transfer evidence" "${SOURCE_PREFIX:-ALL}" "s3_to_azure" >/dev/null 2>&1 || true

s3_upload_file "$LOG_FILE" \
    "$TARGET_S3_STAGE/logs/$RUN_ID/$(basename "$LOG_FILE")" \
    "azure transfer log" "${SOURCE_PREFIX:-ALL}" "s3_to_azure" >/dev/null 2>&1 || true

log INFO "############################################################"
log INFO "#  S3 -> AZURE TRANSFER COMPLETE"
log INFO "#  Status : $RECON_STATUS"
log INFO "#  Objects: $S3_OBJECT_COUNT -> $AZ_COUNT"
log INFO "#  Target : $AZ_BASE_URL"
log INFO "############################################################"

[[ "$RECON_STATUS" == "FAIL" ]] && exit 1
exit 0
