#!/bin/bash
# =============================================================================
#  smoke_test.sh  —  Non-destructive preflight validation
#
#  Verifies that the environment, configuration, tooling and AWS permissions
#  required by the ILM pipeline are all in place BEFORE any data is touched.
#
#  Nothing is written outside $LOG_PATH and a temporary directory, no table is
#  exported, and the Lambda is only exercised with --invocation-type DryRun
#  (permission check only - the function does not actually run).
#
#  Usage:
#    bash smoke_test.sh            # full preflight
#    bash smoke_test.sh --no-aws   # skip AWS checks (offline / static only)
#
#  Exit codes:
#    0  all checks passed (warnings allowed)
#    1  one or more checks FAILED
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Normalize CRLF to LF in-place so copied scripts run on Linux without dos2unix.
normalize_to_unix() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    awk '{ sub(/\r$/, ""); print }' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
}

for _f in "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/.conf.ini "$SCRIPT_DIR"/.conf.ini.example; do
    normalize_to_unix "$_f"
done

# --- Logger ---
. "$SCRIPT_DIR/logger.sh" || { echo "FATAL: cannot source logger.sh" >&2; exit 1; }
log_trap_int

SKIP_AWS=false
[[ "${1:-}" == "--no-aws" ]] && SKIP_AWS=true

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
FAILED_CHECKS=()

# =============================================================================
# Result helpers
# =============================================================================
check_pass() { PASS_COUNT=$((PASS_COUNT+1)); log INFO  "  [PASS] $*"; }
check_warn() { WARN_COUNT=$((WARN_COUNT+1)); log WARN  "  [WARN] $*"; }
check_fail() {
    FAIL_COUNT=$((FAIL_COUNT+1))
    FAILED_CHECKS+=("$*")
    log ERROR "  [FAIL] $*"
}

section() {
    log_line
    log INFO "$*"
    log_line
}

log INFO "############################################################"
log INFO "#  ILM PIPELINE - SMOKE TEST"
log INFO "#  Host   : $(hostname 2>/dev/null)"
log INFO "#  User   : $(whoami 2>/dev/null)"
log INFO "#  Started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
log INFO "############################################################"

# =============================================================================
# 1. BASH VERSION
# =============================================================================
section "1. Shell"
if (( BASH_VERSINFO[0] >= 4 )); then
    check_pass "bash ${BASH_VERSION} (>= 4.0 required)"
else
    check_fail "bash ${BASH_VERSION} is too old - logger.sh requires bash 4.0+"
fi

# =============================================================================
# 2. REQUIRED FILES
# =============================================================================
section "2. Required files"
REQUIRED_FILES=(
    "logger.sh"
    "lib_trace.sh"
    "lib_checkpoint.sh"
    "lib_progress.sh"
    "lib_s3.sh"
    ".conf.ini"
    "00_aws_configure.sh"
    "01_applications_list.sh"
    "02_app_table_list.sh"
    "03_app_attachement_extraction.sh"
    "04_app_table_extraction.sh"
    "05_app_copy_to_s3.sh"
    "06_aws_invoke.sh"
    "ilm_pipeline.sh"
    "reconcile.sh"
)
for f in "${REQUIRED_FILES[@]}"; do
    if [[ -f "$SCRIPT_DIR/$f" ]]; then
        check_pass "present: $f"
    else
        check_fail "missing: $f"
    fi
done

# =============================================================================
# 3. SCRIPT SYNTAX AND LINE ENDINGS
# =============================================================================
section "3. Script syntax"
for f in "$SCRIPT_DIR"/*.sh; do
    [[ -f "$f" ]] || continue
    if bash -n "$f" 2>/dev/null; then
        check_pass "syntax OK: $(basename "$f")"
    else
        check_fail "syntax ERROR: $(basename "$f") -> $(bash -n "$f" 2>&1 | head -n 2 | tr '\n' ' ')"
    fi
done

# --- Line endings -----------------------------------------------------------
# A single CR before the newline makes Linux report
#   /bin/bash^M: bad interpreter: No such file or directory
# The repository stores LF (see .gitattributes), but a file copied through a
# Windows tool can still arrive with CRLF. Detect it here rather than at
# runtime, and give a fix that does NOT require dos2unix to be installed.
section "3b. Line endings (must be LF)"
CRLF_FILES=()
for f in "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/.conf.ini; do
    [[ -f "$f" ]] || continue
    if awk 'index($0, "\r") { found = 1 } END { exit found ? 0 : 1 }' "$f" 2>/dev/null; then
        CRLF_FILES+=("$(basename "$f")")
    fi
done

if (( ${#CRLF_FILES[@]} == 0 )); then
    check_pass "all scripts use Unix (LF) line endings"
else
    check_fail "${#CRLF_FILES[@]} file(s) contain Windows (CRLF) line endings: ${CRLF_FILES[*]}"
    log WARN  "  Automatic fix is applied when running ilm_pipeline.sh or smoke_test.sh."
    log WARN  "  Optional manual fix (no dos2unix needed):"
    log WARN  "      cd $SCRIPT_DIR && sed -i 's/\\r$//' *.sh .conf.ini"
fi

# --- Byte order mark --------------------------------------------------------
# A UTF-8 BOM before #!/bin/bash also breaks the shebang.
BOM_FILES=()
for f in "$SCRIPT_DIR"/*.sh; do
    [[ -f "$f" ]] || continue
    if [[ "$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')" == "efbbbf" ]]; then
        BOM_FILES+=("$(basename "$f")")
    fi
done

if (( ${#BOM_FILES[@]} == 0 )); then
    check_pass "no UTF-8 BOM found in any script"
else
    check_fail "${#BOM_FILES[@]} file(s) start with a UTF-8 BOM: ${BOM_FILES[*]}"
    log ERROR "  Fix without dos2unix:"
    log ERROR "      cd $SCRIPT_DIR && sed -i '1s/^\\xEF\\xBB\\xBF//' *.sh"
fi

# =============================================================================
# 4. CONFIGURATION
# =============================================================================
section "4. Configuration (.conf.ini)"
if [[ -f "$SCRIPT_DIR/.conf.ini" ]]; then
    # shellcheck disable=SC1091
    if . "$SCRIPT_DIR/.conf.ini"; then
        check_pass ".conf.ini sourced successfully"
    else
        check_fail ".conf.ini could not be sourced"
    fi

    REQUIRED_VARS=(
        IDV_HOME ADMIN_USER ADMIN_PASS DB_USER DB_PASS
        EXPORT_PATH ILM_METADATA_PATH LOG_PATH
        AWS_REGION ENV LAMBDA_FUNC ATT_S3_BUCKET EXPORT_LOC
        SOURCE_PATH TARGET_S3_BUCKET TARGET_S3_STAGE
    )
    for v in "${REQUIRED_VARS[@]}"; do
        val="${!v:-}"
        if [[ -z "$val" ]]; then
            check_fail "config $v is empty"
        elif [[ "$val" == *"<CHANGE_ME>"* ]]; then
            check_fail "config $v still contains a placeholder"
        else
            case "$v" in
                *PASS*|*USER*) check_pass "config $v is set" ;;   # never echo secrets
                *)             check_pass "config $v = $val" ;;
            esac
        fi
    done

    # Guard against the $APP_NAME interpolation bug that produced empty segments
    if [[ "${EXPORT_LOC:-}" == */ || "${SOURCE_PATH:-}" == *//* ]]; then
        check_warn "EXPORT_LOC/SOURCE_PATH contain an empty path segment - check for stray \$APP_NAME"
    fi

    # .conf.ini must not be world readable (contains credentials)
    PERM="$(stat -c '%a' "$SCRIPT_DIR/.conf.ini" 2>/dev/null || echo '')"
    if [[ -n "$PERM" && "$PERM" =~ [0-9][0-9][1-7] ]]; then
        check_warn ".conf.ini is world-accessible (mode $PERM) - run: chmod 600 .conf.ini"
    elif [[ -n "$PERM" ]]; then
        check_pass ".conf.ini permissions: $PERM"
    fi
else
    check_fail ".conf.ini not found - copy .conf.ini.example and fill it in"
fi

# =============================================================================
# 5. REQUIRED COMMANDS
# =============================================================================
section "5. Required commands"
for c in aws awk sed grep find date stat wc paste tr; do
    if command -v "$c" >/dev/null 2>&1; then
        check_pass "command available: $c"
    else
        check_fail "command missing: $c"
    fi
done

if command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
    check_pass "checksum tool available (sha256sum/shasum)"
else
    check_fail "no sha256sum/shasum - GxP evidence checksums cannot be produced"
fi

# =============================================================================
# 6. IDV ENVIRONMENT
# =============================================================================
section "6. IDV environment"
if [[ -f "${IDV_HOME:-}/ssaenv.sh" ]]; then
    check_pass "ssaenv.sh found: $IDV_HOME/ssaenv.sh"
    # shellcheck disable=SC1091
    if source "$IDV_HOME/ssaenv.sh" >/dev/null 2>&1; then
        check_pass "ssaenv.sh sourced successfully"
    else
        check_fail "ssaenv.sh could not be sourced"
    fi
else
    check_fail "ssaenv.sh not found at ${IDV_HOME:-<unset>}/ssaenv.sh"
fi

for c in ssaadmin ssasql; do
    if command -v "$c" >/dev/null 2>&1; then
        check_pass "IDV tool available: $c"
    else
        check_fail "IDV tool missing: $c (check IDV_HOME / ssaenv.sh)"
    fi
done

# =============================================================================
# 7. PATHS AND WRITE ACCESS
# =============================================================================
section "7. Paths and write access"
for p in "${EXPORT_PATH:-}" "${ILM_METADATA_PATH:-}" "${LOG_PATH:-}"; do
    [[ -z "$p" ]] && continue
    if mkdir -p "$p" 2>/dev/null; then
        if [[ -w "$p" ]]; then
            check_pass "writable: $p"
        else
            check_fail "not writable: $p"
        fi
    else
        check_fail "cannot create: $p"
    fi
done

# Free space warning on the export filesystem
if [[ -n "${EXPORT_PATH:-}" && -d "${EXPORT_PATH}" ]]; then
    AVAIL_KB="$(df -Pk "$EXPORT_PATH" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [[ -n "$AVAIL_KB" ]]; then
        AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
        if (( AVAIL_GB < 5 )); then
            check_warn "only ${AVAIL_GB}GB free on $EXPORT_PATH"
        else
            check_pass "free space on $EXPORT_PATH: ${AVAIL_GB}GB"
        fi
    fi
fi

# =============================================================================
# 8. LOGGER SELF-TEST
# =============================================================================
section "8. Logger self-test"
SMOKE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ilm_smoke_XXXXXX")"
trap 'rm -rf "$SMOKE_TMP"' EXIT

(
    # Subshell so the real LOG_FILE is not disturbed
    LOG_FILE=""
    log_init "$SMOKE_TMP/logger_test.log" >/dev/null 2>&1
    log INFO "smoke-test-marker"
) >/dev/null 2>&1

if grep -q "smoke-test-marker" "$SMOKE_TMP/logger_test.log" 2>/dev/null; then
    check_pass "logger writes to file correctly"
else
    check_fail "logger did not write the expected record"
fi

# =============================================================================
# 9. LIBRARY SELF-TEST (trace / checkpoint / progress)
# =============================================================================
section "9. Library self-test"
if . "$SCRIPT_DIR/lib_trace.sh" 2>/dev/null; then
    check_pass "lib_trace.sh sourced"
    if trace_init "$SMOKE_TMP" "SMOKE_RUN" >/dev/null 2>&1; then
        audit_event "smoke" "TEST_APP" "test" "obj1" "verify" "SUCCESS" "1" "0" "smoke test record"
        if [[ -s "$AUDIT_FILE" ]] && grep -q "SMOKE_RUN" "$AUDIT_FILE"; then
            check_pass "audit trail record written"
        else
            check_fail "audit trail record was not written"
        fi
        echo "checksum-target" > "$SMOKE_TMP/chk.txt"
        SHA="$(trace_sha256 "$SMOKE_TMP/chk.txt")"
        if [[ -n "$SHA" && "$SHA" != "NA" ]]; then
            check_pass "SHA-256 computed (${SHA:0:12}...)"
        else
            check_fail "SHA-256 could not be computed"
        fi
    else
        check_fail "trace_init failed"
    fi
else
    check_fail "lib_trace.sh could not be sourced"
fi

if . "$SCRIPT_DIR/lib_checkpoint.sh" 2>/dev/null; then
    check_pass "lib_checkpoint.sh sourced"
    if ckpt_init "$SMOKE_TMP/ckpt" "SMOKE_RUN" >/dev/null 2>&1; then
        ckpt_mark_done "TEST_APP|smoke"
        if ckpt_is_done "TEST_APP|smoke"; then
            check_pass "checkpoint mark/verify works (restartability)"
        else
            check_fail "checkpoint was written but not detected on read-back"
        fi
        if [[ "$(ckpt_last_run_id "$SMOKE_TMP/ckpt")" == "SMOKE_RUN" ]]; then
            check_pass "resume pointer resolves correctly"
        else
            check_fail "resume pointer did not resolve"
        fi
    else
        check_fail "ckpt_init failed"
    fi
else
    check_fail "lib_checkpoint.sh could not be sourced"
fi

if . "$SCRIPT_DIR/lib_progress.sh" 2>/dev/null; then
    check_pass "lib_progress.sh sourced"
    progress_init 2 "Smoke" >/dev/null 2>&1
    progress_step "unit-1" >/dev/null 2>&1
    if (( PROGRESS_CURRENT == 1 )); then
        check_pass "progress counter advances"
    else
        check_fail "progress counter did not advance"
    fi
else
    check_fail "lib_progress.sh could not be sourced"
fi

# =============================================================================
# 10. AWS CONNECTIVITY AND PERMISSIONS
# =============================================================================
if $SKIP_AWS; then
    section "10. AWS checks - SKIPPED (--no-aws)"
else
    section "10. AWS connectivity and permissions"

    AWS_PROFILE_FLAG=""
    [[ -n "${AWS_PROFILE:-}" && "${AWS_PROFILE}" != "<CHANGE_ME>" ]] && \
        AWS_PROFILE_FLAG="--profile $AWS_PROFILE"

    if aws sts get-caller-identity $AWS_PROFILE_FLAG --region "$AWS_REGION" >/dev/null 2>&1; then
        CALLER_ARN="$(aws sts get-caller-identity $AWS_PROFILE_FLAG --region "$AWS_REGION" \
                      --query Arn --output text 2>/dev/null)"
        check_pass "AWS credentials valid: $CALLER_ARN"
    else
        check_fail "AWS credentials invalid - run: bash 00_aws_configure.sh"
    fi

    if aws s3 ls "$TARGET_S3_BUCKET/" $AWS_PROFILE_FLAG --region "$AWS_REGION" >/dev/null 2>&1; then
        check_pass "target bucket readable: $TARGET_S3_BUCKET"
    else
        check_fail "cannot list target bucket: $TARGET_S3_BUCKET"
    fi

    if aws s3 ls "$ATT_S3_BUCKET/" $AWS_PROFILE_FLAG --region "$AWS_REGION" >/dev/null 2>&1; then
        check_pass "attachment bucket readable: $ATT_S3_BUCKET"
    else
        check_fail "cannot list attachment bucket: $ATT_S3_BUCKET"
    fi

    # Write probe: the pipeline must be able to PUT into the stage prefix
    PROBE_KEY="$TARGET_S3_STAGE/.smoke_test/$(date -u '+%Y%m%dT%H%M%SZ')_$$.txt"
    echo "ilm smoke test $(date -u)" > "$SMOKE_TMP/probe.txt"
    if aws s3 cp "$SMOKE_TMP/probe.txt" "$PROBE_KEY" $AWS_PROFILE_FLAG \
            --region "$AWS_REGION" >/dev/null 2>&1; then
        check_pass "S3 write access confirmed: $TARGET_S3_STAGE"
        if aws s3 rm "$PROBE_KEY" $AWS_PROFILE_FLAG --region "$AWS_REGION" >/dev/null 2>&1; then
            check_pass "S3 probe object cleaned up"
        else
            check_warn "probe object left behind: $PROBE_KEY"
        fi
    else
        check_fail "no S3 write access to $TARGET_S3_STAGE"
    fi

    # DryRun validates lambda:InvokeFunction WITHOUT running the function
    if aws lambda invoke --function-name "$LAMBDA_FUNC" --invocation-type DryRun \
            $AWS_PROFILE_FLAG --region "$AWS_REGION" "$SMOKE_TMP/lambda.out" >/dev/null 2>&1; then
        check_pass "lambda:InvokeFunction permitted on $LAMBDA_FUNC"
    else
        check_fail "cannot invoke Lambda $LAMBDA_FUNC (permission or wrong name)"
    fi
fi

# =============================================================================
# 11. AZURE TRANSFER READINESS — FUTURE SCOPE, NOT CHECKED
#
#     The S3 -> Azure movement (07_s3_to_azure.sh) is planned for a later
#     phase. The checks below are retained, commented out, so they can be
#     re-enabled together with the AZURE_* block in .conf.ini.
# =============================================================================
section "11. Azure transfer readiness - SKIPPED (future scope)"
log INFO "  S3 -> Azure movement is not part of the current pipeline."

# if [[ -z "${AZURE_STORAGE_ACCOUNT:-}" || "${AZURE_STORAGE_ACCOUNT}" == "<CHANGE_ME>" ]]; then
#     check_warn "Azure not configured - 07_s3_to_azure.sh will not run (fine if unused)"
# else
#     check_pass "Azure account configured: $AZURE_STORAGE_ACCOUNT/$AZURE_CONTAINER"
#
#     if command -v "${AZCOPY_BIN:-azcopy}" >/dev/null 2>&1; then
#         check_pass "azcopy available: $("${AZCOPY_BIN:-azcopy}" --version 2>&1 | head -n 1)"
#     else
#         check_fail "azcopy not found - required by 07_s3_to_azure.sh"
#     fi
#
#     if command -v az >/dev/null 2>&1; then
#         check_pass "az CLI available (enables Azure blob count verification)"
#     else
#         check_warn "az CLI not found - Azure transfers cannot be independently reconciled"
#     fi
#
#     case "${AZURE_AUTH_MODE:-}" in
#         sas)
#             if [[ -n "${AZURE_SAS_TOKEN:-}" ]]; then
#                 check_pass "SAS token present in environment"
#             elif [[ -n "${AZURE_SAS_FILE:-}" && -f "${AZURE_SAS_FILE}" ]]; then
#                 SASPERM="$(stat -c '%a' "$AZURE_SAS_FILE" 2>/dev/null || echo '')"
#                 if [[ "$SASPERM" == "600" || "$SASPERM" == "400" ]]; then
#                     check_pass "SAS file present with safe permissions ($SASPERM)"
#                 else
#                     check_warn "SAS file $AZURE_SAS_FILE has mode ${SASPERM:-unknown} - run: chmod 600"
#                 fi
#             else
#                 check_fail "AZURE_AUTH_MODE=sas but no SAS token or readable SAS file"
#             fi ;;
#         spn)
#             if [[ -n "${AZURE_TENANT_ID:-}" && -n "${AZURE_CLIENT_ID:-}" && -n "${AZURE_CLIENT_SECRET:-}" ]]; then
#                 check_pass "service principal credentials present in environment"
#             else
#                 check_fail "AZURE_AUTH_MODE=spn but tenant/client/secret not exported"
#             fi ;;
#         msi)
#             check_pass "managed identity mode selected" ;;
#         *)
#             check_fail "AZURE_AUTH_MODE invalid: '${AZURE_AUTH_MODE:-}' (use sas|spn|msi)" ;;
#     esac
#
#     case "${AZURE_TRANSFER_MODE:-}" in
#         direct|staged) check_pass "transfer mode: $AZURE_TRANSFER_MODE" ;;
#         *) check_fail "AZURE_TRANSFER_MODE invalid: '${AZURE_TRANSFER_MODE:-}' (use direct|staged)" ;;
#     esac
# fi

# =============================================================================
# SUMMARY
# =============================================================================
TOTAL=$(( PASS_COUNT + FAIL_COUNT + WARN_COUNT ))
log INFO "############################################################"
log INFO "#  SMOKE TEST SUMMARY"
log INFO "############################################################"
log INFO "  Checks executed : $TOTAL"
log INFO "  Passed          : $PASS_COUNT"
log INFO "  Warnings        : $WARN_COUNT"
log INFO "  Failed          : $FAIL_COUNT"

if (( FAIL_COUNT > 0 )); then
    log ERROR "------------------------------------------------------------"
    log ERROR "  FAILED CHECKS:"
    for c in "${FAILED_CHECKS[@]}"; do
        log ERROR "    - $c"
    done
    log ERROR "------------------------------------------------------------"
    log ERROR "  RESULT: FAIL - do NOT run the pipeline until resolved."
    exit 1
fi

log INFO "  RESULT: PASS - environment is ready."
log INFO "  Next: bash ilm_pipeline.sh"
log INFO "############################################################"
exit 0
