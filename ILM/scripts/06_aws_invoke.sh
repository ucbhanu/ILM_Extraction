#!/bin/bash
# =============================================================================
#  06_aws_invoke.sh  —  Lambda Smoke Test
#
#  Invokes the attachment-download Lambda once, using values from .conf.ini
#  (TEST_APP_NAME / TEST_ATT_DIR / TEST_ATT_NAME).
#
#  Usage:
#    bash 06_aws_invoke.sh                                  # values from .conf.ini
#    bash 06_aws_invoke.sh <APP_NAME> <ATT_DIR> <ATT_NAME>   # override at runtime
# =============================================================================

# --- Logger ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/logger.sh" || { echo "FATAL: cannot source logger.sh" >&2; exit 1; }
log_trap_int

# --- Configuration ---
if ! . "$SCRIPT_DIR/.conf.ini"; then
    error_exit "Failed to source .conf.ini"
fi

# =============================================================================
# VALUES — from .conf.ini, optionally overridden by CLI arguments
# =============================================================================
APP_NAME="${1:-$TEST_APP_NAME}"
DIR="${2:-$TEST_ATT_DIR}"
NAME="${3:-$TEST_ATT_NAME}"

# --- Validate ---
MISSING=()
[[ -z "$APP_NAME"    || "$APP_NAME"    == "<CHANGE_ME>" ]] && MISSING+=("TEST_APP_NAME")
[[ -z "$DIR"         || "$DIR"         == "<CHANGE_ME>" ]] && MISSING+=("TEST_ATT_DIR")
[[ -z "$NAME"        || "$NAME"        == "<CHANGE_ME>" ]] && MISSING+=("TEST_ATT_NAME")
[[ -z "$LAMBDA_FUNC" || "$LAMBDA_FUNC" == "<CHANGE_ME>" ]] && MISSING+=("LAMBDA_FUNC")
if [[ ${#MISSING[@]} -gt 0 ]]; then
    log ERROR "The following values are not set in .conf.ini:"
    for v in "${MISSING[@]}"; do log ERROR "  - $v"; done
    error_exit "Or pass them as arguments: $0 <APP_NAME> <ATT_DIR> <ATT_NAME>"
fi

log INFO "Lambda      : $LAMBDA_FUNC"
log INFO "Region      : $AWS_REGION"
log INFO "Application : $APP_NAME"
log INFO "Directory   : $DIR"
log INFO "Filename    : $NAME"
log_line

# 1. Add automatic startdate
STARTDATE=$(date '+%Y-%m-%dT%H:%M:%S')

# 2. Ensure AWS credentials are set and valid
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  log ERROR "AWS credentials are not set or are invalid."
  error_exit "To configure, run: bash 00_aws_configure.sh"
fi

# --- Response file (cleaned up on exit) ---
RESPONSE_FILE="$(mktemp "${TMPDIR:-/tmp}/lambda_response_XXXXXX.json")"
trap 'rm -f "$RESPONSE_FILE"' EXIT

# 3. PayLoad
PAYLOAD=$(printf '{
      "subpath": "",
      "connect_string": "%s",
      "startdate": "%s",
      "ATTACHMENT_DIRECTORY": "%s",
      "ATTACHMENT_NAME": "%s",
      "status": "QUEUED"
    }' "$APP_NAME" "$APP_NAME/$STARTDATE" "$DIR" "$NAME")

log INFO "PAYLOAD: $PAYLOAD"

# 4. Invoke Lambda
if ! aws lambda invoke \
--function-name "$LAMBDA_FUNC" \
--payload "$PAYLOAD" \
--cli-binary-format raw-in-base64-out \
--region "$AWS_REGION" \
"$RESPONSE_FILE"; then
    error_exit "Lambda invocation failed for $LAMBDA_FUNC"
fi

log INFO "Raw response: $(cat "$RESPONSE_FILE")"

# 1. Clean the string: remove outer quotes and convert \" to "
clean_data=$(sed 's/^"//; s/"$//; s/\\"/"/g' "$RESPONSE_FILE")

# 2. Extract values using specific delimiters
status=$(echo "$clean_data" | sed -n 's/.*"status" : "\([^"]*\)".*/\1/p')
bucket=$(echo "$clean_data" | sed -n 's/.*"s3bucketname" : "\([^"]*\)".*/\1/p')
key=$(echo "$clean_data" | sed -n 's/.*"key" : "\([^"]*\)".*/\1/p')

# 3. Output the results
log INFO "Status:     $status"
log INFO "S3 Bucket:  $bucket"
log INFO "Export Loc: $key"
