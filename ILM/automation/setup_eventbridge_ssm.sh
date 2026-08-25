#!/bin/bash
set -euo pipefail

# Create or update EventBridge Scheduler -> SSM RunCommand automation.
# This runs automation/run_pipeline_scheduled.sh on an EC2 instance by tag.

AWS_REGION="${AWS_REGION:-eu-central-1}"
SCHEDULE_EXPR="${SCHEDULE_EXPR:-cron(0 1 * * ? *)}"
SCHEDULE_TZ="${SCHEDULE_TZ:-UTC}"
SCHEDULE_NAME="${SCHEDULE_NAME:-ilm-pipeline-nightly}"
TARGET_TAG_KEY="${TARGET_TAG_KEY:-Role}"
TARGET_TAG_VALUE="${TARGET_TAG_VALUE:-ilm-runner}"
INSTANCE_USER="${INSTANCE_USER:-ec2-user}"
WORK_DIR="${WORK_DIR:-/opt/ilm/ILM}"
SSM_PREFIX="${SSM_PREFIX:-/ilm/qa}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")"
SSM_DOC_ARN="arn:aws:ssm:$AWS_REGION:$ACCOUNT_ID:document/AWS-RunShellScript"

CMD="cd $WORK_DIR && SSM_PREFIX=$SSM_PREFIX AWS_REGION=$AWS_REGION bash automation/run_pipeline_scheduled.sh"

TARGETS_JSON="[{\"Key\":\"tag:$TARGET_TAG_KEY\",\"Values\":[\"$TARGET_TAG_VALUE\"]}]"

INPUT_JSON=$(cat <<EOF
{
  \"DocumentName\": \"AWS-RunShellScript\",
  \"Targets\": $TARGETS_JSON,
  \"Parameters\": {
    \"commands\": [\"$CMD\"]
  }
}
EOF
)

if [[ -z "${SCHEDULER_ROLE_ARN:-}" ]]; then
  echo "ERROR: set SCHEDULER_ROLE_ARN before running."
  echo "Example: export SCHEDULER_ROLE_ARN=arn:aws:iam::$ACCOUNT_ID:role/ilm-scheduler-ssm-role"
  exit 1
fi

TARGET_JSON_FILE="$(mktemp)"
trap 'rm -f "$TARGET_JSON_FILE"' EXIT

cat >"$TARGET_JSON_FILE" <<EOF
{
  "Arn": "$SSM_DOC_ARN",
  "RoleArn": "$SCHEDULER_ROLE_ARN",
  "Input": "$INPUT_JSON"
}
EOF

if aws scheduler get-schedule --name "$SCHEDULE_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws scheduler update-schedule \
    --name "$SCHEDULE_NAME" \
    --group-name default \
    --schedule-expression "$SCHEDULE_EXPR" \
    --schedule-expression-timezone "$SCHEDULE_TZ" \
    --flexible-time-window '{"Mode":"OFF"}' \
    --target "file://$TARGET_JSON_FILE" \
    --region "$AWS_REGION"
  echo "Updated schedule: $SCHEDULE_NAME"
else
  aws scheduler create-schedule \
    --name "$SCHEDULE_NAME" \
    --group-name default \
    --schedule-expression "$SCHEDULE_EXPR" \
    --schedule-expression-timezone "$SCHEDULE_TZ" \
    --flexible-time-window '{"Mode":"OFF"}' \
    --target "file://$TARGET_JSON_FILE" \
    --region "$AWS_REGION"
  echo "Created schedule: $SCHEDULE_NAME"
fi

echo "Done. EventBridge Scheduler will trigger SSM RunCommand on tag $TARGET_TAG_KEY=$TARGET_TAG_VALUE"
