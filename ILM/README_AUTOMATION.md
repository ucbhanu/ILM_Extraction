# ILM AWS Automation (EC2 + EventBridge + SSM)

This folder automates unattended execution of the ILM pipeline without putting secrets in git.

## What this gives you

1. `render_conf_from_ssm.sh`: builds `scripts/.conf.ini` from SSM Parameter Store.
2. `run_pipeline_scheduled.sh`: renders config, runs `smoke_test.sh`, then runs `ilm_pipeline.sh`.
3. `setup_eventbridge_ssm.sh`: creates/updates EventBridge Scheduler to trigger SSM RunCommand.

## Architecture

EventBridge Scheduler -> SSM RunCommand -> EC2 instance (tagged) -> ILM scripts

## Prerequisites

1. EC2 host with:
- AWS CLI v2
- bash
- ILM repo checked out at `/opt/ilm/ILM` (or set `WORK_DIR`)
- IDV tools and connectivity needed by your existing scripts

2. EC2 IAM role permissions:
- `ssm:GetParameter` on your SSM prefix
- `kms:Decrypt` for SecureString parameters
- S3/Lambda permissions already required by your pipeline
- SSM managed instance permissions for RunCommand

3. Scheduler role (`SCHEDULER_ROLE_ARN`) permissions:
- trust policy for `scheduler.amazonaws.com`
- `ssm:SendCommand` on `AWS-RunShellScript`
- `ssm:SendCommand` on targeted instances

## SSM parameters to create

Create under a prefix, for example `/ilm/qa`:

- `/ilm/qa/IDV_HOME`
- `/ilm/qa/ADMIN_USER` (SecureString)
- `/ilm/qa/ADMIN_PASS` (SecureString)
- `/ilm/qa/DB_USER` (SecureString)
- `/ilm/qa/DB_PASS` (SecureString)
- `/ilm/qa/EXPORT_PATH`
- `/ilm/qa/ILM_METADATA_PATH`
- `/ilm/qa/TMP_LOG`
- `/ilm/qa/LOG_PATH`
- `/ilm/qa/APP_PAUSE_SECONDS`
- `/ilm/qa/ATT_WAIT_MAX_SECONDS`
- `/ilm/qa/ENV`
- `/ilm/qa/LAMBDA_FUNC`
- `/ilm/qa/ATT_S3_BUCKET`
- `/ilm/qa/SOURCE_PATH`
- `/ilm/qa/TARGET_S3_BUCKET`
- `/ilm/qa/TEST_APP_NAME`
- `/ilm/qa/TEST_ATT_DIR`
- `/ilm/qa/TEST_ATT_NAME`

## One-time setup

From repo root:

```bash
chmod +x automation/*.sh
```

Run once manually on the EC2 host:

```bash
export AWS_REGION=eu-central-1
export SSM_PREFIX=/ilm/qa
bash automation/run_pipeline_scheduled.sh
```

If successful, create schedule:

```bash
export AWS_REGION=eu-central-1
export SSM_PREFIX=/ilm/qa
export WORK_DIR=/opt/ilm/ILM
export TARGET_TAG_KEY=Role
export TARGET_TAG_VALUE=ilm-runner
export SCHEDULER_ROLE_ARN=arn:aws:iam::<account-id>:role/ilm-scheduler-ssm-role
export SCHEDULE_NAME=ilm-pipeline-nightly
export SCHEDULE_EXPR='cron(0 1 * * ? *)'
export SCHEDULE_TZ=UTC

bash automation/setup_eventbridge_ssm.sh
```

## Notes

- Default runner behavior uses `--resume` for resilience in unattended jobs.
- Runner logs are written to `automation/logs/`.
- Keep `scripts/.conf.ini` git-ignored as it is generated locally at runtime.
