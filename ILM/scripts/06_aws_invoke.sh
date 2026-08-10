#!/bin/bash

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! . "$SCRIPT_DIR/conf.ini"; then
    echo "ERROR: Failed to source conf.ini" >&2; exit 1
fi
if ! . "$SCRIPT_DIR/aws_conf.ini"; then
    echo "ERROR: Failed to source aws_conf.ini" >&2; exit 1
fi

# =============================================================================
# TEST VARIABLES — fill in values before running
# =============================================================================
APP_NAME="<CHANGE_ME>"    # e.g. LIFEDOC_QA
DIR="<CHANGE_ME>"         # e.g. /ilmstage/LifeDoc/QA/Native/Batch1
NAME="<CHANGE_ME>"        # e.g. 0902bc3b8080585e.doc
# =============================================================================

# 1. Add automatic startdate
STARTDATE=$(date '+%Y-%m-%dT%H:%M:%S')

# 2. Ensure AWS credentials are set and valid
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "ERROR: AWS credentials are not set or are invalid. Please configure your AWS CLI with valid credentials."
  echo "To configure, run: aws configure"
  exit 1
fi


# 3. PayLoad
PAYLOAD=$(printf '{
      "subpath": "",
      "connect_string": "%s",
      "startdate": "%s",
      "ATTACHMENT_DIRECTORY": "%s",
      "ATTACHMENT_NAME": "%s",
      "status": "QUEUED"
    }' "$APP_NAME" "$APP_NAME/$STARTDATE" "$DIR" "$NAME")

echo "PAYLOAD: $PAYLOAD"

# 4. Invoke Lambda
aws lambda invoke \
--function-name "$LAMBDA_FUNC" \
--payload "$PAYLOAD" \
--cli-binary-format raw-in-base64-out \
response.json

#sleep 1

cat response.json

# 1. Clean the string: remove outer quotes and convert \" to "
clean_data=$(sed 's/^"//; s/"$//; s/\\"/"/g' response.json)

# 2. Extract values using specific delimiters
status=$(echo "$clean_data" | sed -n 's/.*"status" : "\([^"]*\)".*/\1/p')
bucket=$(echo "$clean_data" | sed -n 's/.*"s3bucketname" : "\([^"]*\)".*/\1/p')
key=$(echo "$clean_data" | sed -n 's/.*"key" : "\([^"]*\)".*/\1/p')

# 3. Output the results
echo "Status:     $status"
echo "S3 Bucket:  $bucket"
echo "Export Loc: $key"
