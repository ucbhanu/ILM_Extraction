#!/bin/bash
set -euo pipefail

# Render scripts/.conf.ini from AWS Systems Manager Parameter Store.
# Expects SecureString values for secrets and String values for non-secrets.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONF_FILE="$ROOT_DIR/scripts/.conf.ini"
TMP_FILE="$CONF_FILE.tmp"

PREFIX="${1:-/ilm/qa}"
AWS_REGION="${AWS_REGION:-eu-central-1}"

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $1" >&2
        exit 1
    }
}

get_param() {
    local key="$1"
    aws ssm get-parameter \
      --name "$PREFIX/$key" \
      --with-decryption \
      --region "$AWS_REGION" \
      --query 'Parameter.Value' \
      --output text
}

require_cmd aws

IDV_HOME="$(get_param IDV_HOME)"
ADMIN_USER="$(get_param ADMIN_USER)"
ADMIN_PASS="$(get_param ADMIN_PASS)"
DB_USER="$(get_param DB_USER)"
DB_PASS="$(get_param DB_PASS)"
EXPORT_PATH="$(get_param EXPORT_PATH)"
ILM_METADATA_PATH="$(get_param ILM_METADATA_PATH)"
TMP_LOG="$(get_param TMP_LOG)"
LOG_PATH="$(get_param LOG_PATH)"
APP_PAUSE_SECONDS="$(get_param APP_PAUSE_SECONDS)"
ATT_WAIT_MAX_SECONDS="$(get_param ATT_WAIT_MAX_SECONDS)"
ENV="$(get_param ENV)"
LAMBDA_FUNC="$(get_param LAMBDA_FUNC)"
ATT_S3_BUCKET="$(get_param ATT_S3_BUCKET)"
SOURCE_PATH="$(get_param SOURCE_PATH)"
TARGET_S3_BUCKET="$(get_param TARGET_S3_BUCKET)"
TEST_APP_NAME="$(get_param TEST_APP_NAME)"
TEST_ATT_DIR="$(get_param TEST_ATT_DIR)"
TEST_ATT_NAME="$(get_param TEST_ATT_NAME)"

cat >"$TMP_FILE" <<EOF
export IDV_HOME="$IDV_HOME"
export ADMIN_USER="$ADMIN_USER"
export ADMIN_PASS="$ADMIN_PASS"
export DB_USER="$DB_USER"
export DB_PASS="$DB_PASS"

export EXPORT_PATH="$EXPORT_PATH"
export ILM_METADATA_PATH="$ILM_METADATA_PATH"
export TMP_LOG="$TMP_LOG"
export LOG_PATH="$LOG_PATH"

export APP_PAUSE_SECONDS=$APP_PAUSE_SECONDS
export ATT_WAIT_MAX_SECONDS=$ATT_WAIT_MAX_SECONDS

export AWS_REGION="$AWS_REGION"
export ENV="$ENV"
export LAMBDA_FUNC="$LAMBDA_FUNC"
export ATT_S3_BUCKET="$ATT_S3_BUCKET"
export EXPORT_LOC="${ATT_S3_BUCKET#s3://}"

export SOURCE_PATH="$SOURCE_PATH"
export TARGET_S3_BUCKET="$TARGET_S3_BUCKET"
export TARGET_S3_STAGE="$TARGET_S3_BUCKET/stage"

export TEST_APP_NAME="$TEST_APP_NAME"
export TEST_ATT_DIR="$TEST_ATT_DIR"
export TEST_ATT_NAME="$TEST_ATT_NAME"
EOF

mv "$TMP_FILE" "$CONF_FILE"
chmod 600 "$CONF_FILE"

echo "Rendered $CONF_FILE from SSM prefix $PREFIX"
