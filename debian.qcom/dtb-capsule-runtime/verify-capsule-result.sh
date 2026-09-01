#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# SPDX-License-Identifier: BSD-3-Clause-Clear
#
# =============================================================================
# Runs once after boot to confirm the staged capsule was actually applied by
# firmware.
#
# Writes fields to $STATE_DIR/last-verify-state for other tooling to
# consume (fleet agents, recovery services, /etc/update-motd.d/85-dtb-capsule):
#   - kver_match_state: whether the installed dtb-capsule package matches the
#     kernel running right now.
#   - dtb_pairing_state: (only meaningful when kver_match_state=ok) whether
#     firmware paired the running kernel with the correct DTB content.
#   - rollback_target_kver / rollback_target_available: (only meaningful when
#     dtb_pairing_state=suspected_dtb_rollback) which installed kernel the
#     running DTB's content actually belongs to, and whether that kernel's
#     package is still installed on this device.
#   - guid_conflict / esrt_dedup_skipped: side-channel flags reporting that
#     the check didn't fully run, not conclusions about this update.
#   - summary: one-line human-readable verdict distilled from the fields
#     above, always the last line so `tail -1` or a glance at the file end
#     is enough to know whether anything needs attention.
set -e

log() { echo "dtb-capsule-verify: $*"; logger -t dtb-capsule-verify "$*" 2>/dev/null || true; }

# Reads each platform's FMP_GUID from its capsule.env and checks it against
# ESRT; reports on whichever platform's GUID matches.
# Overridable for unit-testing this script without touching the real /usr,
# /sys, /var, or the host's actual kernel version.
PKG_SHARE="${PKG_SHARE:-/usr/share/dtb-capsule}"
ESRT_DIR="${ESRT_DIR:-/sys/firmware/efi/esrt/entries}"
STATE_DIR="${STATE_DIR:-/var/lib/dtb-capsule}"
RUNNING_KVER="${RUNNING_KVER:-$(uname -r)}"
BOOT_ID="${BOOT_ID:-$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "")}"
LAST_VERIFIED_KVER_FILE="${STATE_DIR}/last-verified-kver"
LAST_ESRT_CONFIRMED_FILE="${STATE_DIR}/last-esrt-confirmed"
LAST_ESRT_DETAIL_FILE="${STATE_DIR}/last-esrt-detail"
GUID_CONFLICT_FILE="${STATE_DIR}/last-guid-conflict"
VERIFY_STATE_FILE="${STATE_DIR}/last-verify-state"
REBOOT_PENDING_SINCE_FILE="${STATE_DIR}/reboot-pending-since"
MODULES_DIR="${MODULES_DIR:-/usr/lib/modules}"
CAPSULE_DIR="${CAPSULE_DIR:-/boot/efi/EFI/UpdateCapsule}"
# Directory where the packaged .dtb/.dtbo files are installed for this
# kernel version.
DEVICE_TREE_DIR="${DEVICE_TREE_DIR:-/usr/lib/firmware/${RUNNING_KVER}/device-tree/qcom}"

mkdir -p "$STATE_DIR"

# Reports whether the last install/upgrade skipped capsule staging due to an
# ambiguous ESRT FMP_GUID match across packaged platforms.
GUID_CONFLICT="false"
GUID_CONFLICT_DETAIL=""
if [ -f "$GUID_CONFLICT_FILE" ]; then
    GUID_CONFLICT="true"
    GUID_CONFLICT_DETAIL="$(cat "$GUID_CONFLICT_FILE" 2>/dev/null || echo "")"
    log "WARNING: last install/upgrade skipped capsule staging due to ambiguous ESRT FMP_GUID match: ${GUID_CONFLICT_DETAIL}"
fi

ESRT_DEDUP_SKIPPED="false"

# Returns the dtb-provenance-sha256 marker shipped in a given kver's
# linux-modules package, if that package is still installed on this device.
dtb_provenance_sha256_for_kver() {
    _f="${MODULES_DIR}/$1/dtb-provenance-sha256"
    [ -f "$_f" ] || return 1
    cat "$_f"
}

# dpkg's Status field for linux-modules-<kver>, or empty if there's no
# record at all (never installed, or cleaned up by autoremove).
linux_modules_status_for_kver() {
    dpkg-query -W -f='${Status}' "linux-modules-$1" 2>/dev/null
}

# Distinguishes reboot_pending (mismatch just seen, no reboot yet) from
# reboot_stalled (mismatch has survived a reboot) via boot_id, not a boot
# counter, so clock skew can't distort it.
check_reboot_stall() {
    _tracked_kver=""
    _tracked_boot_id=""
    if [ -f "$REBOOT_PENDING_SINCE_FILE" ]; then
        _tracked_kver="$(grep '^expected_kver=' "$REBOOT_PENDING_SINCE_FILE" 2>/dev/null | cut -d= -f2-)"
        _tracked_boot_id="$(grep '^first_boot_id=' "$REBOOT_PENDING_SINCE_FILE" 2>/dev/null | cut -d= -f2-)"
    fi

    if [ "$_tracked_kver" != "$DTB_CAPSULE_EXPECTED_KVER" ]; then
        printf 'expected_kver=%s\nfirst_boot_id=%s\n' "$DTB_CAPSULE_EXPECTED_KVER" "$BOOT_ID" > "$REBOOT_PENDING_SINCE_FILE"
        echo "reboot_pending"
    elif [ "$_tracked_boot_id" = "$BOOT_ID" ]; then
        echo "reboot_pending"
    else
        echo "reboot_stalled"
    fi
}

# --- Cross-build comparison input: dtb_kver_content_match. Computed
# unconditionally so every branch below reports the same value. ---
DT_PROVENANCE_DIR="${DT_PROVENANCE_DIR:-/sys/firmware/devicetree/base/qcom-dtb-capsule-provenance}"
RUNNING_DTB_SHA=""
if [ -f "${DT_PROVENANCE_DIR}/dtb-provenance-sha256" ]; then
    RUNNING_DTB_SHA="$(tr -d '\0' < "${DT_PROVENANCE_DIR}/dtb-provenance-sha256")"
fi

DTB_CAPSULE_EXPECTED_KVER_FILE="${PKG_SHARE}/expected-kver"
if [ -f "$DTB_CAPSULE_EXPECTED_KVER_FILE" ]; then
    DTB_CAPSULE_EXPECTED_KVER="$(cat "$DTB_CAPSULE_EXPECTED_KVER_FILE" 2>/dev/null || echo "")"
else
    DTB_CAPSULE_EXPECTED_KVER=""
fi
DTB_CAPSULE_EXPECTED_SHA=""
[ -n "$DTB_CAPSULE_EXPECTED_KVER" ] && DTB_CAPSULE_EXPECTED_SHA="$(dtb_provenance_sha256_for_kver "$DTB_CAPSULE_EXPECTED_KVER" 2>/dev/null || echo "")"

# dtb_kver_content_match: whether the running DTB's provenance sha256 matches
# the linux-modules-<kver> package installed for RUNNING_KVER right now.
RUNNING_DTB_MATCHES_INSTALLED_MODULES="unknown"
RUNNING_INSTALLED_DTB_SHA="$(dtb_provenance_sha256_for_kver "$RUNNING_KVER" 2>/dev/null || echo "")"
if [ -n "$RUNNING_DTB_SHA" ] && [ -n "$RUNNING_INSTALLED_DTB_SHA" ]; then
    if [ "$RUNNING_DTB_SHA" = "$RUNNING_INSTALLED_DTB_SHA" ]; then
        RUNNING_DTB_MATCHES_INSTALLED_MODULES="ok"
    else
        RUNNING_DTB_MATCHES_INSTALLED_MODULES="mismatch"
    fi
fi

# Distills kver_match_state/dtb_pairing_state (plus the cross-build fields)
# into one human-readable line, so a consumer only needs the last field of
# last-verify-state to know whether anything needs attention.
summary_for_state() {
    case "$1:$2" in
        package_mismatch:*)
            echo "ERROR: package targets a kernel version not installed on this device" ;;
        reboot_pending:*)
            echo "PENDING: capsule staged for the expected kernel, awaiting reboot into it" ;;
        reboot_stalled:*)
            echo "WARNING: rebooted at least once but device still isn't running the expected kernel - reboot may have stalled" ;;
        no_capsule_for_running_kernel:*)
            echo "WARNING: no capsule targets the running kernel, but its own DTB content is self-consistent" ;;
        kernel_dtb_mismatch:*)
            echo "ERROR: running kernel's own DTB content does not match its installed package" ;;
        ok:pending)
            echo "PENDING: capsule not yet confirmed applied by firmware" ;;
        ok:apply_failed)
            echo "ERROR: firmware reported the capsule update failed" ;;
        ok:suspected_dtb_rollback)
            echo "WARNING: suspected DTB rollback - firmware kept/reverted to a previous DTB despite reporting apply success" ;;
        ok:apply_confirmed)
            echo "OK: capsule applied and verified" ;;
        ok:content_mismatch_localized)
            echo "ERROR: applied DTB content does not match the installed kernel package" ;;
        *)
            echo "UNKNOWN: cannot confirm capsule result (see detail)" ;;
    esac
}

# Persists the fields below as key=value, sourceable by any POSIX-sh tool
# (MOTD script, recovery service). rollback_target_kver/rollback_target_available
# are always emitted (even empty) so downstream consumers can safely
# `. last-verify-state` and test `-n "$rollback_target_kver"`.
write_state() {
    _kver_match_state="$1"
    _dtb_pairing_state="$2"
    _detail="$3"
    _rollback_target_kver="${4:-}"
    _rollback_target_available="${5:-}"
    _summary="$(summary_for_state "$_kver_match_state" "$_dtb_pairing_state")"
    if [ "$GUID_CONFLICT" = "true" ]; then
        _summary="${_summary}; guid_conflict: ${GUID_CONFLICT_DETAIL}"
    fi
    cat > "$VERIFY_STATE_FILE" <<EOF
timestamp=$(date -u +%FT%TZ)
boot_id=${BOOT_ID}
kver=${RUNNING_KVER}
kver_match_state=${_kver_match_state}
dtb_pairing_state=${_dtb_pairing_state}
guid_conflict=${GUID_CONFLICT}
guid_conflict_detail="${GUID_CONFLICT_DETAIL}"
esrt_dedup_skipped=${ESRT_DEDUP_SKIPPED}
rollback_target_kver=${_rollback_target_kver}
rollback_target_available=${_rollback_target_available}
dtb_kver_content_match=${RUNNING_DTB_MATCHES_INSTALLED_MODULES}
detail="${_detail}"
summary="${_summary}"
EOF
}

# --- Phase 1: kver_match_state — whether the installed package matches the
# kernel running right now. Direction-agnostic: DTB_CAPSULE_EXPECTED_KVER may
# name a newer or older kernel than RUNNING_KVER. ---
if [ -n "$DTB_CAPSULE_EXPECTED_KVER" ] && [ "$RUNNING_KVER" != "$DTB_CAPSULE_EXPECTED_KVER" ]; then
    EXPECTED_MODULES_STATUS="$(linux_modules_status_for_kver "$DTB_CAPSULE_EXPECTED_KVER")"
    # An absent record (never installed, or autoremoved) falls through to
    # the self-consistency checks below rather than erroring here.
    if [ -n "$EXPECTED_MODULES_STATUS" ] && [ "$EXPECTED_MODULES_STATUS" != "install ok installed" ]; then
        log "ERROR: package targets kernel ${DTB_CAPSULE_EXPECTED_KVER} but linux-modules-${DTB_CAPSULE_EXPECTED_KVER} is in an abnormal dpkg state (${EXPECTED_MODULES_STATUS}) — package/device mismatch"
        write_state "package_mismatch" "unknown" "expected-kver=${DTB_CAPSULE_EXPECTED_KVER} dpkg status abnormal on this device"
        exit 0
    fi

    # Unconsumed capsule, or staging skipped because content already
    # matched EXPECTED: either way just awaiting reboot.
    if [ -d "$CAPSULE_DIR" ] && [ -n "$(ls -A "$CAPSULE_DIR" 2>/dev/null)" ]; then
        STALL_STATE="$(check_reboot_stall)"
        log "running kernel ${RUNNING_KVER} does not match capsule's expected kernel ${DTB_CAPSULE_EXPECTED_KVER}; ${CAPSULE_DIR} still holds an unconsumed capsule — ${STALL_STATE}"
        write_state "$STALL_STATE" "unknown" "expected-kver=${DTB_CAPSULE_EXPECTED_KVER} installed, capsule still unconsumed in ${CAPSULE_DIR}"
        exit 0
    fi

    if [ -n "$DTB_CAPSULE_EXPECTED_SHA" ] && [ "$DTB_CAPSULE_EXPECTED_SHA" = "$RUNNING_DTB_SHA" ]; then
        STALL_STATE="$(check_reboot_stall)"
        log "running kernel ${RUNNING_KVER} does not match capsule's expected kernel ${DTB_CAPSULE_EXPECTED_KVER}, but running DTB content already matches it (staging was skipped) — ${STALL_STATE}"
        write_state "$STALL_STATE" "unknown" "expected-kver=${DTB_CAPSULE_EXPECTED_KVER}, capsule staging was skipped (content already matched)"
        exit 0
    fi

    # No unconsumed capsule and content isn't the expected one: whether
    # this is benign depends on the running kernel's own DTB.
    case "$RUNNING_DTB_MATCHES_INSTALLED_MODULES" in
        ok)
            log "running kernel ${RUNNING_KVER} has no capsule targeting it, but its own DTB content is self-consistent — likely a kernel-only install with no matching dtb-capsule package"
            write_state "no_capsule_for_running_kernel" "unknown" "expected-kver=${DTB_CAPSULE_EXPECTED_KVER}, running kver=${RUNNING_KVER} has no unconsumed capsule; own DTB content is self-consistent"
            exit 0
            ;;
        mismatch)
            log "ERROR: running kernel ${RUNNING_KVER}'s own DTB content does not match its installed linux-modules package — kernel and DTB are paired incorrectly"
            write_state "kernel_dtb_mismatch" "unknown" "expected-kver=${DTB_CAPSULE_EXPECTED_KVER}, running kver=${RUNNING_KVER}'s own DTB content mismatches its installed package"
            exit 0
            ;;
        *)
            rm -f "$REBOOT_PENDING_SINCE_FILE"
            log "cannot determine whether running kernel ${RUNNING_KVER}'s own DTB content is self-consistent — no provenance data available"
            write_state "unknown" "unknown" "expected-kver=${DTB_CAPSULE_EXPECTED_KVER}, running kver=${RUNNING_KVER}'s own DTB content self-consistency unknown"
            exit 0
            ;;
    esac
else
    rm -f "$REBOOT_PENDING_SINCE_FILE"
fi

# --- Phase 2: dtb_pairing_state — whether firmware paired the running kernel
# with the correct DTB content. Only reached when kver_match_state=ok.
# Content self-consistency short-circuits to apply_confirmed regardless of
# ESRT; ESRT is consulted only to diagnose a mismatch. ---
if [ "$RUNNING_DTB_MATCHES_INSTALLED_MODULES" = "ok" ]; then
    log "CONFIRMED: DTB's provenance sha256 matches the linux-modules-${RUNNING_KVER} package actually installed on this device"
    write_state "ok" "apply_confirmed" "provenance sha256 match"
    exit 0
fi

# Whether firmware has finished draining the staged capsule from UpdateCapsule.
CAPSULE_DIR_EMPTY=1
if [ -d "$CAPSULE_DIR" ] && [ -n "$(ls -A "$CAPSULE_DIR" 2>/dev/null)" ]; then
    CAPSULE_DIR_EMPTY=0
    log "WARNING: ${CAPSULE_DIR} still contains capsule files after boot — firmware may not have consumed them"
else
    log "UpdateCapsule directory empty/absent — consistent with firmware having consumed and cleared the capsule"
fi

# --- dtb_pairing_state, step 1: whether firmware actually applied the capsule (ESRT) ---
#
# Cache is cleared and rewritten on every ESRT scan, ensuring stale results
# from prior kernel versions or device configs are not reused.
MATCHED_ANY=0
ESRT_CONFIRMED=0
ESRT_STATUS_LINE=""
if [ -f "$LAST_VERIFIED_KVER_FILE" ] && [ "$(cat "$LAST_VERIFIED_KVER_FILE" 2>/dev/null || echo "")" = "$RUNNING_KVER" ]; then
    ESRT_DEDUP_SKIPPED="true"
    MATCHED_ANY=1
    ESRT_CONFIRMED="$(cat "$LAST_ESRT_CONFIRMED_FILE" 2>/dev/null || echo "0")"
    ESRT_STATUS_LINE="$(cat "$LAST_ESRT_DETAIL_FILE" 2>/dev/null || echo "")"
    log "already verified ESRT capsule result for kernel ${RUNNING_KVER}, skipping ESRT check (recalling esrt_confirmed=${ESRT_CONFIRMED} from last check${ESRT_STATUS_LINE:+; detail: ${ESRT_STATUS_LINE}})"
else
    for ENV_FILE in "${PKG_SHARE}"/*/capsule.env; do
        [ -f "$ENV_FILE" ] || continue
        MACHINE="$(basename "$(dirname "$ENV_FILE")")"
        FMP_GUID=""
        # shellcheck disable=SC1090
        . "$ENV_FILE"
        if [ -z "$FMP_GUID" ]; then
            log "WARNING: FMP_GUID not set in ${ENV_FILE}, skipping"
            continue
        fi
        FMP_GUID="$(echo "$FMP_GUID" | tr 'A-Z' 'a-z')"

        # last_attempt_status/_version record the outcome of the last capsule
        # attempt for this GUID, regardless of whether fwupd or
        # Capsule-on-Disk delivered it.
        ESRT_MATCH=""
        if [ -d "$ESRT_DIR" ]; then
            for entry in "$ESRT_DIR"/entry*; do
                [ -d "$entry" ] || continue
                FW_CLASS="$(cat "${entry}/fw_class" 2>/dev/null | tr 'A-Z' 'a-z')"
                if [ "$FW_CLASS" = "$FMP_GUID" ]; then
                    ESRT_MATCH="$entry"
                    break
                fi
            done
        fi

        [ -n "$ESRT_MATCH" ] || continue
        MATCHED_ANY=1

        STATUS="$(cat "${ESRT_MATCH}/last_attempt_status" 2>/dev/null || echo "")"
        LAST_VER="$(cat "${ESRT_MATCH}/last_attempt_version" 2>/dev/null || echo "")"
        FW_VER="$(cat "${ESRT_MATCH}/fw_version" 2>/dev/null || echo "")"
        log "platform=${MACHINE} ESRT entry ${ESRT_MATCH}: last_attempt_status=${STATUS} last_attempt_version=${LAST_VER} fw_version=${FW_VER}"
        if [ "$STATUS" = "0" ] && [ -n "$FW_VER" ] && [ "$FW_VER" = "$LAST_VER" ]; then
            log "capsule update confirmed successful via ESRT (platform=${MACHINE})"
            ESRT_CONFIRMED=1
        else
            case "$STATUS" in
                1) DESC="ErrorUnsuccessful" ;;
                2) DESC="ErrorInsufficientResources" ;;
                3) DESC="ErrorIncorrectVersion" ;;
                4) DESC="ErrorInvalidFormat" ;;
                5) DESC="ErrorAuthError (signature verification failed)" ;;
                6) DESC="ErrorPwrEvtAC" ;;
                7) DESC="ErrorPwrEvtBatt" ;;
                8) DESC="ErrorUnsatisfiedDependencies" ;;
                *) DESC="unknown" ;;
            esac
            ESRT_STATUS_LINE="platform=${MACHINE} status=${STATUS} [${DESC}] fw_version=${FW_VER} vs last_attempt_version=${LAST_VER}"
            log "WARNING: ESRT does not confirm a successful update (${ESRT_STATUS_LINE})"
        fi

        if command -v fwupdmgr >/dev/null 2>&1; then
            RESULT="$(fwupdmgr get-history 2>/dev/null | grep -A5 -i "qcom.*dtb\|${FMP_GUID}" || true)"
            if [ -n "$RESULT" ]; then
                log "fwupdmgr history (platform=${MACHINE}): $RESULT"
            else
                log "no matching entry in fwupdmgr get-history (platform=${MACHINE}) — capsule may not have been processed by fwupd"
            fi
        fi
    done

    if [ "$MATCHED_ANY" -eq 0 ]; then
        log "WARNING: no ESRT entry found matching any packaged platform's FMP_GUID — cannot confirm capsule result via ESRT"
    elif [ "$CAPSULE_DIR_EMPTY" -eq 1 ]; then
        rm -f "$LAST_VERIFIED_KVER_FILE" "$LAST_ESRT_CONFIRMED_FILE" "$LAST_ESRT_DETAIL_FILE"
        echo "$RUNNING_KVER" > "$LAST_VERIFIED_KVER_FILE"
        echo "$ESRT_CONFIRMED" > "$LAST_ESRT_CONFIRMED_FILE"
        echo "$ESRT_STATUS_LINE" > "$LAST_ESRT_DETAIL_FILE"
    else
        log "WARNING: ${CAPSULE_DIR} still has an unconsumed capsule — not caching this ESRT result, will re-check on the next boot"
    fi
fi

if [ "$MATCHED_ANY" -eq 0 ] || [ "$CAPSULE_DIR_EMPTY" -eq 0 ]; then
    write_state "ok" "pending" "no ESRT match yet or capsule still staged in ${CAPSULE_DIR}"
    exit 0
fi

if [ -z "$RUNNING_DTB_SHA" ]; then
    log "WARNING: no DTB provenance node at ${DT_PROVENANCE_DIR} — cannot verify DTB content provenance"
    write_state "ok" "unknown" "ESRT confirmed apply, but no DTB provenance node at ${DT_PROVENANCE_DIR}"
    exit 0
fi

DTB_PROVENANCE_MARKER="${MODULES_DIR}/${RUNNING_KVER}/dtb-provenance-sha256"
if [ "$RUNNING_DTB_MATCHES_INSTALLED_MODULES" = "unknown" ]; then
    log "WARNING: cannot cross-check provenance sha256 (${DTB_PROVENANCE_MARKER} missing)"
    write_state "ok" "unknown" "cannot cross-check provenance sha256 (${DTB_PROVENANCE_MARKER} missing)"
    exit 0
fi

log "WARNING: DTB's provenance sha256=${RUNNING_DTB_SHA} does not match installed linux-modules-${RUNNING_KVER} (${RUNNING_INSTALLED_DTB_SHA}) — this capsule's DTB was NOT built from the kernel package currently installed on this device"

# --- dtb_pairing_state, step 2: name a rollback target before blaming
# firmware. Scans every OTHER installed kernel's dtb-provenance-sha256 for a
# match against the running DTB; ties resolve to the highest-versioned
# match. ---
ROLLBACK_TARGET_KVER=""
for CANDIDATE_KVER in $(ls "$MODULES_DIR" 2>/dev/null | sort -V); do
    [ "$CANDIDATE_KVER" != "$RUNNING_KVER" ] || continue
    CANDIDATE_DTB_SHA="$(dtb_provenance_sha256_for_kver "$CANDIDATE_KVER" 2>/dev/null || echo "")"
    [ -n "$CANDIDATE_DTB_SHA" ] || continue
    [ "$CANDIDATE_DTB_SHA" = "$RUNNING_DTB_SHA" ] && ROLLBACK_TARGET_KVER="$CANDIDATE_KVER"
done

if [ -n "$ROLLBACK_TARGET_KVER" ]; then
    ROLLBACK_TARGET_AVAILABLE="false"
    if [ "$(linux_modules_status_for_kver "$ROLLBACK_TARGET_KVER")" = "install ok installed" ]; then
        ROLLBACK_TARGET_AVAILABLE="true"
    fi
    log "WARNING: running DTB's provenance sha256 matches installed linux-modules-${ROLLBACK_TARGET_KVER} — firmware appears to have kept/reverted to that kernel's DTB despite ESRT reporting success for ${RUNNING_KVER}"
    write_state "ok" "suspected_dtb_rollback" "running DTB's provenance sha256 matches linux-modules-${ROLLBACK_TARGET_KVER}" "$ROLLBACK_TARGET_KVER" "$ROLLBACK_TARGET_AVAILABLE"
    exit 0
fi

if [ "$ESRT_CONFIRMED" -eq 0 ]; then
    write_state "ok" "apply_failed" "$ESRT_STATUS_LINE"
    exit 0
fi

# Localizes the mismatch to specific files: sha256 each packaged .dtb/.dtbo
# file installed under DEVICE_TREE_DIR and diff against the manifest's
# per-file sha256 lines.
CONTENT_SHA256SUMS_MANIFEST="${PKG_SHARE}/dtb-provenance-content-sha256sums.txt"
DIFF_FILES=""
if [ -f "$CONTENT_SHA256SUMS_MANIFEST" ]; then
    if [ -d "$DEVICE_TREE_DIR" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            BUILD_SHA256="$(printf '%s\n' "$line" | awk '{print $1}')"
            FILE_PATH="$(printf '%s\n' "$line" | cut -f2- -d' ' | sed 's/^ *//')"
            INSTALLED_FILE="${DEVICE_TREE_DIR}/${FILE_PATH}"
            if [ ! -f "$INSTALLED_FILE" ]; then
                DIFF_FILES="${DIFF_FILES}${DIFF_FILES:+, }${FILE_PATH} (missing on device)"
                continue
            fi
            INSTALLED_SHA256="$(sha256sum "$INSTALLED_FILE" | awk '{print $1}')"
            if [ "$BUILD_SHA256" != "$INSTALLED_SHA256" ]; then
                DIFF_FILES="${DIFF_FILES}${DIFF_FILES:+, }${FILE_PATH}"
            fi
        done < "$CONTENT_SHA256SUMS_MANIFEST"

        if [ -n "$DIFF_FILES" ]; then
            log "WARNING: provenance sha256 mismatch localized to: ${DIFF_FILES}"
        else
            log "WARNING: provenance sha256 mismatch is not localized to any packaged .dtb/.dtbo under ${DEVICE_TREE_DIR} — the differing file is some other package member"
            DIFF_FILES="(not localized to any packaged .dtb/.dtbo)"
        fi
    else
        log "WARNING: cannot localize provenance sha256 mismatch — no ${DEVICE_TREE_DIR}"
        DIFF_FILES="(no ${DEVICE_TREE_DIR} to localize against)"
    fi
else
    log "WARNING: cannot localize provenance sha256 mismatch — no ${CONTENT_SHA256SUMS_MANIFEST}"
    DIFF_FILES="(no ${CONTENT_SHA256SUMS_MANIFEST} to localize against)"
fi

write_state "ok" "content_mismatch_localized" "provenance sha256 mismatch: ${DIFF_FILES}"

exit 0
