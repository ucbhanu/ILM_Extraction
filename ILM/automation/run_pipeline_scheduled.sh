#!/bin/bash
set -euo pipefail

# Scheduled runner for ILM pipeline on EC2/ECS host.
# 1) renders scripts/.conf.ini from SSM
# 2) runs smoke test
# 3) runs pipeline

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/automation/logs}"
mkdir -p "$LOG_DIR"

TS="$(date '+%Y%m%d_%H%M%S')"
RUN_LOG="$LOG_DIR/runner_${TS}.log"

SSM_PREFIX="${SSM_PREFIX:-/ilm/qa}"
AWS_REGION="${AWS_REGION:-eu-central-1}"
RESUME_FLAG="${RESUME_FLAG:---resume}"

exec > >(tee -a "$RUN_LOG") 2>&1

echo "[$(date '+%F %T')] Starting ILM scheduled run"
echo "[$(date '+%F %T')] SSM_PREFIX=$SSM_PREFIX AWS_REGION=$AWS_REGION"

export AWS_REGION

bash "$SCRIPT_DIR/render_conf_from_ssm.sh" "$SSM_PREFIX"

# Preflight without touching data integrity path first.
bash "$ROOT_DIR/scripts/smoke_test.sh"

# Use resume by default for unattended operation.
bash "$ROOT_DIR/scripts/ilm_pipeline.sh" "$RESUME_FLAG"

echo "[$(date '+%F %T')] ILM scheduled run completed"
