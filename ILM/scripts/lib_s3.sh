#!/bin/bash
# =============================================================================
#  lib_s3.sh  —  Verified S3 transfer helpers
#
#  Every upload is count-verified against the source and recorded in the audit
#  trail, so an EFS -> S3 transfer can be proven complete for GxP review.
#
#  Provides:
#    s3_flags                          Echo the --profile/--region flags to use
#    s3_count <s3_uri>                 Number of objects under a prefix
#    s3_upload_dir  <src_dir>  <s3_uri> <label> [app] [step]
#    s3_upload_file <src_file> <s3_uri> <label> [app] [step]
#
#  Return codes: 0 = uploaded and verified, 1 = failure or count mismatch,
#                2 = nothing to upload (treated as success by callers)
#
#  Requires logger.sh; uses lib_trace.sh (audit_event/evidence_add) when loaded.
# =============================================================================

[[ -n "${__ILM_S3_SOURCED:-}" ]] && return 0
__ILM_S3_SOURCED=1

# --- Common AWS CLI flags ----------------------------------------------------
s3_flags() {
    local flags=""
    [[ -n "${AWS_REGION:-}" ]] && flags="--region $AWS_REGION"
    [[ -n "${AWS_PROFILE:-}" && "${AWS_PROFILE}" != "<CHANGE_ME>" ]] && \
        flags="$flags --profile $AWS_PROFILE"
    printf '%s' "$flags"
}

# --- Audit shim: no-op when lib_trace.sh is not loaded -----------------------
__s3_audit() {
    declare -F audit_event >/dev/null 2>&1 && audit_event "$@"
    return 0
}

# =============================================================================
#  s3_count <s3_uri>
# =============================================================================
s3_count() {
    local uri="$1"
    local flags; flags="$(s3_flags)"
    # NOTE: use `grep -v ... | wc -l`, never `grep -vc`.
    # `grep -vc` prints 0 AND exits 1 on empty input, so a `|| echo 0` fallback
    # fires as well and the function returns "0\n0", which breaks arithmetic.
    # shellcheck disable=SC2086
    aws s3 ls "$uri" --recursive $flags 2>/dev/null | grep -v ' PRE ' | wc -l | tr -d '[:space:]'
}

# =============================================================================
#  s3_mirror <src> <dest> <label> [app] [step]
#    Makes <dest> an EXACT mirror of <src> using `aws s3 sync --delete`:
#      - new and changed files are uploaded (overwriting the target)
#      - objects in the target that no longer exist in the source are removed
#    so a reconciliation of source vs target must match exactly.
#
#    <src> may be a local directory or an s3:// URI.
#
#    Do NOT use this for the audit trail, evidence or logs: those accumulate
#    across runs and must never be deleted. Use s3_upload_dir for those.
# =============================================================================
s3_mirror() {
    local src="$1" dest="$2" label="$3" app="${4-}" step="${5:-s3_transfer}"
    local flags; flags="$(s3_flags)"
    local src_count

    if [[ "$src" == s3://* ]]; then
        src_count="$(s3_count "$src/")"
    else
        if [[ ! -d "$src" ]]; then
            log INFO "  [$label] source directory not present - skipping ($src)"
            __s3_audit "$step" "$app" "s3_mirror" "$dest" "sync" "SKIPPED" "0" "" \
                "Source directory missing: $src"
            return 2
        fi
        src_count="$(find "$src" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
    fi

    if (( src_count == 0 )); then
        log INFO "  [$label] nothing to mirror - skipping"
        __s3_audit "$step" "$app" "s3_mirror" "$dest" "sync" "SKIPPED" "0" "" \
            "Source empty: $src"
        return 2
    fi

    log INFO "  [$label] mirroring $src_count object(s): $src -> $dest"

    # shellcheck disable=SC2086
    if ! aws s3 sync "$src" "$dest" --delete $flags >/dev/null 2>&1; then
        log ERROR "  [$label] mirror FAILED: $src -> $dest"
        __s3_audit "$step" "$app" "s3_mirror" "$dest" "sync" "FAILED" "$src_count" "" \
            "aws s3 sync returned non-zero"
        return 1
    fi

    local dest_count
    dest_count="$(s3_count "$dest/")"

    if (( dest_count != src_count )); then
        log ERROR "  [$label] mirror verification FAILED: source=$src_count target=$dest_count"
        __s3_audit "$step" "$app" "s3_mirror" "$dest" "verify" "FAILED" "$dest_count" "" \
            "Count mismatch source=$src_count target=$dest_count"
        return 1
    fi

    log INFO "  [$label] mirror verified: source=$src_count target=$dest_count (exact match)"
    __s3_audit "$step" "$app" "s3_mirror" "$dest" "sync" "SUCCESS" "$dest_count" "" \
        "Exact mirror source=$src_count target=$dest_count"
    return 0
}

# =============================================================================
#  s3_sync_additive <src> <dest> <label> [app] [step]
#    Copies new and changed objects WITHOUT deleting anything in the target.
#    <src> may be a local directory or an s3:// URI.
#
#    Use this whenever the source is transient - for example the Lambda
#    bulk-download bucket, which may have a lifecycle policy that expires
#    objects. Mirroring with --delete from such a source would delete already
#    archived data in the target.
# =============================================================================
s3_sync_additive() {
    local src="$1" dest="$2" label="$3" app="${4-}" step="${5:-s3_transfer}"
    local flags; flags="$(s3_flags)"
    local src_count

    if [[ "$src" == s3://* ]]; then
        src_count="$(s3_count "$src/")"
    else
        if [[ ! -d "$src" ]]; then
            log INFO "  [$label] source directory not present - skipping ($src)"
            __s3_audit "$step" "$app" "s3_upload" "$dest" "copy" "SKIPPED" "0" "" \
                "Source directory missing: $src"
            return 2
        fi
        src_count="$(find "$src" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
    fi

    if (( src_count == 0 )); then
        log INFO "  [$label] nothing to copy - skipping"
        __s3_audit "$step" "$app" "s3_upload" "$dest" "copy" "SKIPPED" "0" "" \
            "Source empty: $src"
        return 2
    fi

    log INFO "  [$label] copying $src_count object(s): $src -> $dest"

    # shellcheck disable=SC2086
    if ! aws s3 sync "$src" "$dest" $flags >/dev/null 2>&1; then
        log ERROR "  [$label] copy FAILED: $src -> $dest"
        __s3_audit "$step" "$app" "s3_upload" "$dest" "copy" "FAILED" "$src_count" "" \
            "aws s3 sync returned non-zero"
        return 1
    fi

    local dest_count
    dest_count="$(s3_count "$dest/")"

    if (( dest_count < src_count )); then
        log ERROR "  [$label] verification FAILED: source=$src_count target=$dest_count"
        __s3_audit "$step" "$app" "s3_upload" "$dest" "verify" "FAILED" "$dest_count" "" \
            "Count mismatch source=$src_count target=$dest_count"
        return 1
    fi

    log INFO "  [$label] verified: source=$src_count target=$dest_count"
    __s3_audit "$step" "$app" "s3_upload" "$dest" "copy" "SUCCESS" "$dest_count" "" \
        "Copied source=$src_count target=$dest_count"
    return 0
}

# =============================================================================
#  s3_upload_dir <src_dir> <s3_uri> <label> [app] [step]
#    Additive upload (no deletion). Use for audit trail, evidence and logs.
# =============================================================================
s3_upload_dir() {
    local src="$1" dest="$2" label="$3" app="${4-}" step="${5:-s3_transfer}"
    local flags; flags="$(s3_flags)"

    if [[ ! -d "$src" ]]; then
        log INFO "  [$label] source directory not present - skipping ($src)"
        __s3_audit "$step" "$app" "s3_upload" "$dest" "copy" "SKIPPED" "0" "" \
            "Source directory missing: $src"
        return 2
    fi

    local src_count
    src_count="$(find "$src" -type f 2>/dev/null | wc -l)"

    if (( src_count == 0 )); then
        log INFO "  [$label] no files to upload - skipping"
        __s3_audit "$step" "$app" "s3_upload" "$dest" "copy" "SKIPPED" "0" "" \
            "No files in $src"
        return 2
    fi

    log INFO "  [$label] uploading $src_count file(s): $src -> $dest"

    # shellcheck disable=SC2086
    if ! aws s3 cp "$src" "$dest" --recursive $flags >/dev/null 2>&1; then
        log ERROR "  [$label] upload FAILED: $src -> $dest"
        __s3_audit "$step" "$app" "s3_upload" "$dest" "copy" "FAILED" "$src_count" "" \
            "aws s3 cp returned non-zero"
        return 1
    fi

    local dest_count
    dest_count="$(s3_count "$dest/")"

    if (( dest_count < src_count )); then
        log ERROR "  [$label] verification FAILED: source=$src_count target=$dest_count"
        __s3_audit "$step" "$app" "s3_upload" "$dest" "verify" "FAILED" "$dest_count" "" \
            "Count mismatch source=$src_count target=$dest_count"
        return 1
    fi

    log INFO "  [$label] verified OK: source=$src_count target=$dest_count"
    __s3_audit "$step" "$app" "s3_upload" "$dest" "copy" "SUCCESS" "$dest_count" "" \
        "Verified source=$src_count target=$dest_count"
    return 0
}

# =============================================================================
#  s3_upload_file <src_file> <s3_uri> <label> [app] [step]
# =============================================================================
s3_upload_file() {
    local src="$1" dest="$2" label="$3" app="${4-}" step="${5:-s3_transfer}"
    local flags; flags="$(s3_flags)"

    if [[ ! -f "$src" ]]; then
        log INFO "  [$label] file not present - skipping ($src)"
        __s3_audit "$step" "$app" "s3_upload" "$dest" "copy" "SKIPPED" "0" "" \
            "Source file missing: $src"
        return 2
    fi

    local size=0
    if declare -F trace_filesize >/dev/null 2>&1; then
        size="$(trace_filesize "$src")"
    fi

    log INFO "  [$label] uploading $(basename "$src") -> $dest"

    # shellcheck disable=SC2086
    if ! aws s3 cp "$src" "$dest" $flags >/dev/null 2>&1; then
        log ERROR "  [$label] upload FAILED: $src -> $dest"
        __s3_audit "$step" "$app" "s3_upload" "$dest" "copy" "FAILED" "1" "$size" \
            "aws s3 cp returned non-zero"
        return 1
    fi

    log INFO "  [$label] uploaded OK ($size bytes)"
    __s3_audit "$step" "$app" "s3_upload" "$dest" "copy" "SUCCESS" "1" "$size" \
        "File uploaded"
    return 0
}
