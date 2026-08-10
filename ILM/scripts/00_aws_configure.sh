#!/bin/bash
# =============================================================================
#  00_aws_configure.sh  —  AWS CLI Configuration & Verification
#
#  Description:
#    Configures the AWS CLI with credentials and region, then verifies
#    connectivity. Supports both named profile and default credential modes.
#
#    ⚠  Credentials (Access Key / Secret) are entered interactively and are
#       NEVER written to any log file.
#
#  Usage:
#    bash 00_aws_configure.sh
#
#  Prerequisites:
#    - AWS CLI v2 installed
#    - aws_conf.ini filled in (AWS_REGION, AWS_PROFILE if applicable)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# LOGGER  (no log file — credentials must not be captured)
# =============================================================================
log() {
    local level="$1"; shift
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
}
error_exit() { log "ERROR" "$1"; exit 1; }
trap 'log "ERROR" "Script interrupted (Ctrl+C). Exiting."; exit 130' INT

# =============================================================================
# 1. SOURCE aws_conf.ini
# =============================================================================
log "INFO" "============================================================"
log "INFO" "  AWS CLI Configuration & Verification"
log "INFO" "============================================================"

if ! . "$SCRIPT_DIR/aws_conf.ini"; then
    error_exit "Failed to source aws_conf.ini"
fi

# =============================================================================
# 2. VALIDATE aws_conf.ini IS FILLED IN
# =============================================================================
log "INFO" "Validating aws_conf.ini..."

MISSING=()
[[ "$AWS_REGION"      == "<CHANGE_ME>" || -z "$AWS_REGION"      ]] && MISSING+=("AWS_REGION")
[[ "$ENV"             == "<CHANGE_ME>" || -z "$ENV"              ]] && MISSING+=("ENV")
[[ "$LAMBDA_FUNC"     == "<CHANGE_ME>" || -z "$LAMBDA_FUNC"      ]] && MISSING+=("LAMBDA_FUNC")
[[ "$ATT_S3_BUCKET"   == "<CHANGE_ME>" || -z "$ATT_S3_BUCKET"    ]] && MISSING+=("ATT_S3_BUCKET")
[[ "$EXPORT_LOC"      == "<CHANGE_ME>" || -z "$EXPORT_LOC"       ]] && MISSING+=("EXPORT_LOC")
[[ "$SOURCE_PATH"     == "<CHANGE_ME>" || -z "$SOURCE_PATH"      ]] && MISSING+=("SOURCE_PATH")
[[ "$TARGET_S3_BUCKET" == "<CHANGE_ME>" || -z "$TARGET_S3_BUCKET" ]] && MISSING+=("TARGET_S3_BUCKET")

if [[ ${#MISSING[@]} -gt 0 ]]; then
    log "ERROR" "The following variables in aws_conf.ini still have placeholder values:"
    for v in "${MISSING[@]}"; do
        log "ERROR" "  - $v"
    done
    error_exit "Please fill in aws_conf.ini before running this script."
fi
log "INFO" "aws_conf.ini values OK"
log "INFO" "------------------------------------------------------------"

# =============================================================================
# 3. CHECK AWS CLI IS INSTALLED
# =============================================================================
log "INFO" "Checking AWS CLI installation..."
if ! command -v aws &>/dev/null; then
    error_exit "AWS CLI not found. Install it from https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
fi
AWS_VERSION=$(aws --version 2>&1)
log "INFO" "AWS CLI: $AWS_VERSION"
log "INFO" "------------------------------------------------------------"

# =============================================================================
# 4. DETERMINE PROFILE MODE
# =============================================================================
if [[ -n "${AWS_PROFILE:-}" && "$AWS_PROFILE" != "<CHANGE_ME>" ]]; then
    PROFILE_FLAG="--profile $AWS_PROFILE"
    PROFILE_LABEL="$AWS_PROFILE"
    log "INFO" "Mode       : Named profile  ($AWS_PROFILE)"
else
    PROFILE_FLAG=""
    PROFILE_LABEL="default"
    log "INFO" "Mode       : Default credentials"
fi
log "INFO" "Region     : $AWS_REGION"
log "INFO" "Environment: $ENV"
log "INFO" "------------------------------------------------------------"

# =============================================================================
# 5. CHECK IF VALID CREDENTIALS ALREADY EXIST
# =============================================================================
log "INFO" "Checking existing AWS credentials..."
if aws sts get-caller-identity $PROFILE_FLAG --region "$AWS_REGION" >/dev/null 2>&1; then
    CALLER=$(aws sts get-caller-identity $PROFILE_FLAG --region "$AWS_REGION" 2>/dev/null)
    ACCOUNT=$(echo "$CALLER" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)
    ARN=$(echo     "$CALLER" | grep -o '"Arn": "[^"]*"'     | cut -d'"' -f4)
    log "INFO" "Valid credentials already configured."
    log "INFO" "  Account : $ACCOUNT"
    log "INFO" "  Identity: $ARN"
    log "INFO" "------------------------------------------------------------"

    read -r -p "Credentials are already valid. Re-configure anyway? [y/N]: " RECONFIGURE
    if [[ ! "$RECONFIGURE" =~ ^[Yy]$ ]]; then
        log "INFO" "Skipping credential configuration."
        SKIP_CONFIG=true
    fi
fi

# =============================================================================
# 6. CONFIGURE CREDENTIALS  (interactive — not logged)
# =============================================================================
if [[ "${SKIP_CONFIG:-false}" != "true" ]]; then
    log "INFO" "Configuring AWS credentials..."
    log "INFO" "You will be prompted for:"
    log "INFO" "  - AWS Access Key ID"
    log "INFO" "  - AWS Secret Access Key"
    log "INFO" "  (Output session token field: press Enter to skip if not needed)"
    log "INFO" "------------------------------------------------------------"

    if [[ -n "$PROFILE_FLAG" ]]; then
        aws configure $PROFILE_FLAG
    else
        aws configure
    fi

    # Set region explicitly (aws configure may prompt a different value)
    aws configure set region "$AWS_REGION" $PROFILE_FLAG
    log "INFO" "Region set to: $AWS_REGION"
fi

# =============================================================================
# 7. VERIFY CONNECTIVITY
# =============================================================================
log "INFO" "============================================================"
log "INFO" "  Verifying AWS connectivity..."
log "INFO" "============================================================"

if ! aws sts get-caller-identity $PROFILE_FLAG --region "$AWS_REGION" >/dev/null 2>&1; then
    error_exit "AWS credential verification failed. Check your Access Key / Secret and try again."
fi

CALLER=$(aws sts get-caller-identity $PROFILE_FLAG --region "$AWS_REGION" 2>/dev/null)
ACCOUNT=$(echo "$CALLER" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)
ARN=$(echo     "$CALLER" | grep -o '"Arn": "[^"]*"'     | cut -d'"' -f4)
USERID=$(echo  "$CALLER" | grep -o '"UserId": "[^"]*"'  | cut -d'"' -f4)

log "INFO" "  [OK] Credentials verified"
log "INFO" "  Account   : $ACCOUNT"
log "INFO" "  User/Role : $ARN"
log "INFO" "  UserId    : $USERID"
log "INFO" "------------------------------------------------------------"

# =============================================================================
# 8. VERIFY S3 TARGET BUCKET ACCESS
# =============================================================================
log "INFO" "Verifying S3 target bucket access: $TARGET_S3_BUCKET"
if ! aws s3 ls "$TARGET_S3_BUCKET/" $PROFILE_FLAG --region "$AWS_REGION" >/dev/null 2>&1; then
    log "WARN" "Cannot list $TARGET_S3_BUCKET — bucket may not exist or access denied."
    log "WARN" "Pipeline S3 uploads will fail unless this is resolved."
else
    log "INFO" "  [OK] $TARGET_S3_BUCKET is accessible"
fi
log "INFO" "------------------------------------------------------------"

# =============================================================================
# 9. VERIFY LAMBDA FUNCTION ACCESS
# =============================================================================
log "INFO" "Verifying Lambda function access: $LAMBDA_FUNC"
if ! aws lambda get-function --function-name "$LAMBDA_FUNC" $PROFILE_FLAG --region "$AWS_REGION" >/dev/null 2>&1; then
    log "WARN" "Cannot access Lambda function '$LAMBDA_FUNC' — check function name or IAM permissions."
    log "WARN" "Attachment extraction will fail unless this is resolved."
else
    log "INFO" "  [OK] Lambda function '$LAMBDA_FUNC' is accessible"
fi
log "INFO" "------------------------------------------------------------"

# =============================================================================
# 10. SUMMARY
# =============================================================================
log "INFO" "============================================================"
log "INFO" "  AWS Configuration Complete"
log "INFO" "  Profile    : $PROFILE_LABEL"
log "INFO" "  Region     : $AWS_REGION"
log "INFO" "  Account    : $ACCOUNT"
log "INFO" "  Identity   : $ARN"
log "INFO" "  S3 Bucket  : $TARGET_S3_BUCKET"
log "INFO" "  Lambda     : $LAMBDA_FUNC"
log "INFO" "  Environment: $ENV"
log "INFO" "============================================================"
log "INFO" "Run the pipeline with: bash ilm_pipeline.sh"
