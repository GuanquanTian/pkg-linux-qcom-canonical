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
#   - capsule_state: (only meaningful when kver_match_state=ok) whether
#     firmware applied this update, and whether the applied content is correct.
#   - dtb_content_unchanged: whether the running DTB's provenance sha256 is
#     identical to the pre-update snapshot — a same-content reinstall rather
#     than an actual content change.
#   - rollback_target_kver / rollback_target_available: (only meaningful when
#     capsule_state=suspected_dtb_rollback) which old kernel version the
#     running DTB still belongs to, and whether that kernel's package is
#     still installed on this device.
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
PRE_UPDATE_DTB_FILE="${STATE_DIR}/pre-update-dtb"
VERIFY_STATE_FILE="${STATE_DIR}/last-verify-state"
DPKG_INFO_DIR="${DPKG_INFO_DIR:-/var/lib/dpkg/info}"
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

# --- Cross-build comparison inputs: kernel_origin / dtb_build_origin /
# dtb_kver_content_match / dtb_content_unchanged. Computed unconditionally,
# before kver_match_state is decided below, so every branch reports the
# same values. ---
DT_PROVENANCE_DIR="${DT_PROVENANCE_DIR:-/sys/firmware/devicetree/base/qcom-dtb-capsule-provenance}"
RUNNING_DTB_SHA=""
if [ -f "${DT_PROVENANCE_DIR}/dtb-provenance-sha256" ]; then
    RUNNING_DTB_SHA="$(tr -d '\0' < "${DT_PROVENANCE_DIR}/dtb-provenance-sha256")"
fi

EXPECTED_KVER_FILE="${PKG_SHARE}/expected-kver"
if [ -f "$EXPECTED_KVER_FILE" ]; then
    EXPECTED_KVER="$(cat "$EXPECTED_KVER_FILE" 2>/dev/null || echo "")"
else
    EXPECTED_KVER=""
fi
EXPECTED_DTB_SHA=""
[ -n "$EXPECTED_KVER" ] && EXPECTED_DTB_SHA="$(dtb_provenance_sha256_for_kver "$EXPECTED_KVER" 2>/dev/null || echo "")"

# pre-update-dtb is written once per staged capsule (dtb-capsule.postinst.in's
# stage_capsule()) and always overwritten, never appended. Snapshots that
# pre-date this field only have sha256=/name=, so kver=/dtb_provenance_sha256=
# stay empty and every "old" comparison below falls through to unknown.
PRE_KVER=""
PRE_DTB_SHA=""
if [ -f "$PRE_UPDATE_DTB_FILE" ]; then
    PRE_KVER="$(grep '^kver=' "$PRE_UPDATE_DTB_FILE" 2>/dev/null | cut -d= -f2-)"
    PRE_DTB_SHA="$(grep '^dtb_provenance_sha256=' "$PRE_UPDATE_DTB_FILE" 2>/dev/null | cut -d= -f2-)"
fi

# kernel_origin: which known build the *running kernel* belongs to.
KERNEL_ORIGIN="unknown"
if [ -n "$EXPECTED_KVER" ] && [ "$RUNNING_KVER" = "$EXPECTED_KVER" ]; then
    KERNEL_ORIGIN="new"
elif [ -n "$PRE_KVER" ] && [ "$RUNNING_KVER" = "$PRE_KVER" ]; then
    KERNEL_ORIGIN="old"
fi

# dtb_build_origin: which known build the *running DTB's* provenance sha256
# belongs to, independent of kernel_origin.
DTB_BUILD_ORIGIN="unknown"
if [ -n "$RUNNING_DTB_SHA" ] && [ -n "$EXPECTED_DTB_SHA" ] && [ "$RUNNING_DTB_SHA" = "$EXPECTED_DTB_SHA" ]; then
    DTB_BUILD_ORIGIN="new"
elif [ -n "$RUNNING_DTB_SHA" ] && [ -n "$PRE_DTB_SHA" ] && [ "$RUNNING_DTB_SHA" = "$PRE_DTB_SHA" ]; then
    DTB_BUILD_ORIGIN="old"
fi

# dtb_content_unchanged: whether the running DTB's provenance sha256 is the
# same as the pre-update snapshot, regardless of dtb_build_origin — flags a
# same-content reinstall distinctly from an actual content change.
DTB_CONTENT_UNCHANGED="unknown"
if [ -n "$RUNNING_DTB_SHA" ] && [ -n "$PRE_DTB_SHA" ]; then
    if [ "$RUNNING_DTB_SHA" = "$PRE_DTB_SHA" ]; then
        DTB_CONTENT_UNCHANGED="true"
    else
        DTB_CONTENT_UNCHANGED="false"
    fi
fi

# dtb_kver_content_match: whether the running DTB's provenance sha256 matches
# the linux-modules-<kver> package installed for RUNNING_KVER right now.
DTB_KVER_CONTENT_MATCH="unknown"
RUNNING_INSTALLED_DTB_SHA="$(dtb_provenance_sha256_for_kver "$RUNNING_KVER" 2>/dev/null || echo "")"
if [ -n "$RUNNING_DTB_SHA" ] && [ -n "$RUNNING_INSTALLED_DTB_SHA" ]; then
    if [ "$RUNNING_DTB_SHA" = "$RUNNING_INSTALLED_DTB_SHA" ]; then
        DTB_KVER_CONTENT_MATCH="ok"
    else
        DTB_KVER_CONTENT_MATCH="mismatch"
    fi
fi

# Distills kver_match_state/capsule_state (plus the cross-build fields) into
# one human-readable line, so a consumer only needs the last field of
# last-verify-state to know whether anything needs attention.
summary_for_state() {
    case "$1:$2" in
        package_mismatch:*)
            echo "ERROR: package targets a kernel version not installed on this device" ;;
        reboot_pending:*)
            echo "PENDING: capsule staged for a newer kernel, awaiting reboot into it" ;;
        suspected_kernel_rollback:*)
            echo "WARNING: suspected kernel rollback - bootloader may have fallen back to a previous kernel" ;;
        ok:pending)
            echo "PENDING: capsule not yet confirmed applied by firmware" ;;
        ok:apply_failed)
            echo "ERROR: firmware reported the capsule update failed" ;;
        ok:suspected_dtb_rollback)
            echo "WARNING: suspected DTB rollback - firmware kept/reverted to the previous DTB despite reporting apply success" ;;
        ok:apply_confirmed)
            if [ "$DTB_CONTENT_UNCHANGED" = "true" ]; then
                echo "OK: capsule applied and verified (content unchanged from before - same-content reinstall)"
            else
                echo "OK: capsule applied and verified"
            fi ;;
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
    _capsule_state="$2"
    _detail="$3"
    _rollback_target_kver="${4:-}"
    _rollback_target_available="${5:-}"
    _summary="$(summary_for_state "$_kver_match_state" "$_capsule_state")"
    if [ "$KERNEL_ORIGIN" = "old" ] && [ "$DTB_BUILD_ORIGIN" = "new" ]; then
        _summary="${_summary}; DANGER: running kernel is the old one but the active DTB is still from the new build - driver/hardware-description mismatch possible"
    fi
    if [ "$GUID_CONFLICT" = "true" ]; then
        _summary="${_summary}; guid_conflict: ${GUID_CONFLICT_DETAIL}"
    fi
    cat > "$VERIFY_STATE_FILE" <<EOF
timestamp=$(date -u +%FT%TZ)
boot_id=${BOOT_ID}
kver=${RUNNING_KVER}
kver_match_state=${_kver_match_state}
capsule_state=${_capsule_state}
guid_conflict=${GUID_CONFLICT}
guid_conflict_detail="${GUID_CONFLICT_DETAIL}"
esrt_dedup_skipped=${ESRT_DEDUP_SKIPPED}
rollback_target_kver=${_rollback_target_kver}
rollback_target_available=${_rollback_target_available}
dtb_kver_content_match=${DTB_KVER_CONTENT_MATCH}
dtb_build_origin=${DTB_BUILD_ORIGIN}
dtb_content_unchanged=${DTB_CONTENT_UNCHANGED}
kernel_origin=${KERNEL_ORIGIN}
detail="${_detail}"
summary="${_summary}"
EOF
}

# --- Field 1: kver_match_state — whether the installed package matches the
# kernel running right now. ---
if [ -n "$EXPECTED_KVER" ] && [ "$RUNNING_KVER" != "$EXPECTED_KVER" ]; then
    EXPECTED_MODULES_STATUS="$(dpkg-query -W -f='${Status}' "linux-modules-${EXPECTED_KVER}" 2>/dev/null || echo "")"
    if ! printf '%s' "$EXPECTED_MODULES_STATUS" | grep -q "^install ok installed$"; then
        log "ERROR: package targets kernel ${EXPECTED_KVER} but linux-modules-${EXPECTED_KVER} is not installed on this device — package/device mismatch"
        write_state "package_mismatch" "unknown" "expected-kver=${EXPECTED_KVER} not installed on this device"
        exit 0
    fi

    if [ -d "$CAPSULE_DIR" ] && [ -n "$(ls -A "$CAPSULE_DIR" 2>/dev/null)" ]; then
        log "WARNING: running kernel ${RUNNING_KVER} does not match capsule's expected kernel ${EXPECTED_KVER}, but ${CAPSULE_DIR} still holds an unconsumed capsule — awaiting reboot into it, skipping"
        write_state "reboot_pending" "unknown" "expected-kver=${EXPECTED_KVER} installed, capsule still unconsumed in ${CAPSULE_DIR}, awaiting reboot into it"
        exit 0
    fi

    log "WARNING: running kernel ${RUNNING_KVER} does not match capsule's expected kernel ${EXPECTED_KVER}, and ${CAPSULE_DIR} is already empty/consumed — possible bootloader fallback (check bootloader boot-counting/health-check state)"
    write_state "suspected_kernel_rollback" "unknown" "expected-kver=${EXPECTED_KVER} installed, capsule already consumed, but running kver=${RUNNING_KVER}"
    exit 0
fi

# --- Field 2: capsule_state — whether firmware applied this update, and
# whether the applied content is correct. Only reached when kver_match_state=ok. ---

# Whether firmware has finished draining the staged capsule from UpdateCapsule.
CAPSULE_DIR_EMPTY=1
if [ -d "$CAPSULE_DIR" ] && [ -n "$(ls -A "$CAPSULE_DIR" 2>/dev/null)" ]; then
    CAPSULE_DIR_EMPTY=0
    log "WARNING: ${CAPSULE_DIR} still contains capsule files after boot — firmware may not have consumed them"
else
    log "UpdateCapsule directory empty/absent — consistent with firmware having consumed and cleared the capsule"
fi

# --- capsule_state, step 1: whether firmware actually applied the capsule (ESRT) ---
#
# Deduped per running kernel version. Dedup only skips the sysfs scan/log
# lines below, not the content-provenance check further down. The dedup
# cache is written only when CAPSULE_DIR_EMPTY is 1.
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

if [ "$ESRT_CONFIRMED" -eq 0 ]; then
    write_state "ok" "apply_failed" "$ESRT_STATUS_LINE"
    exit 0
fi

# --- capsule_state, step 2: whether the applied content is actually
# correct. ---
CONTENT_SHA256SUMS_MANIFEST="${PKG_SHARE}/dtb-provenance-content-sha256sums.txt"

if [ -z "$RUNNING_DTB_SHA" ]; then
    log "WARNING: no DTB provenance node at ${DT_PROVENANCE_DIR} — cannot verify DTB content provenance"
    write_state "ok" "unknown" "ESRT confirmed apply, but no DTB provenance node at ${DT_PROVENANCE_DIR}"
    exit 0
fi

# dtb_build_origin=old means the running DTB's provenance sha256 still equals
# the pre-update snapshot, and differs from the currently-installed package's
# expected sha256 — firmware kept/reverted to the previous DTB despite ESRT
# reporting success.
if [ "$DTB_BUILD_ORIGIN" = "old" ]; then
    log "WARNING: running DTB's provenance sha256=${RUNNING_DTB_SHA} matches the pre-update snapshot (kver=${PRE_KVER}) and differs from the currently-installed package's expected sha256=${EXPECTED_DTB_SHA} — firmware appears to have kept/reverted to the previous DTB despite ESRT reporting success"

    ROLLBACK_TARGET_AVAILABLE="false"
    if [ -n "$PRE_KVER" ]; then
        PRE_INSTALLED_DTB_SHA="$(dtb_provenance_sha256_for_kver "$PRE_KVER" 2>/dev/null || echo "")"
        if [ -n "$PRE_INSTALLED_DTB_SHA" ]; then
            if [ "$PRE_INSTALLED_DTB_SHA" = "$PRE_DTB_SHA" ]; then
                ROLLBACK_TARGET_AVAILABLE="true"
                log "rollback target linux-modules-${PRE_KVER} is still installed and content-matches the pre-update snapshot"
            else
                log "WARNING: linux-modules-${PRE_KVER} is installed but its content (${PRE_INSTALLED_DTB_SHA}) no longer matches the pre-update snapshot (${PRE_DTB_SHA}) — not a safe rollback target"
            fi
        else
            log "WARNING: rollback target linux-modules-${PRE_KVER} is no longer installed — not available as a rollback target"
        fi
    fi

    write_state "ok" "suspected_dtb_rollback" "running DTB's provenance sha256 matches pre-update snapshot kver=${PRE_KVER} dtb_provenance_sha256=${PRE_DTB_SHA}, expected sha256=${EXPECTED_DTB_SHA}" "$PRE_KVER" "$ROLLBACK_TARGET_AVAILABLE"
    exit 0
fi

# Cross-checks the provenance sha256 baked into this DTB against the
# linux-modules-<kver> package actually installed right now.
DTB_PROVENANCE_MARKER="${MODULES_DIR}/${RUNNING_KVER}/dtb-provenance-sha256"
if [ "$DTB_KVER_CONTENT_MATCH" = "unknown" ]; then
    log "WARNING: cannot cross-check provenance sha256 (${DTB_PROVENANCE_MARKER} missing)"
    write_state "ok" "unknown" "cannot cross-check provenance sha256 (${DTB_PROVENANCE_MARKER} missing)"
    exit 0
fi

if [ "$DTB_KVER_CONTENT_MATCH" = "ok" ]; then
    if [ "$DTB_CONTENT_UNCHANGED" = "true" ]; then
        log "CONFIRMED: DTB's provenance sha256 matches the linux-modules-${RUNNING_KVER} package actually installed on this device; content is identical to the pre-update snapshot (same-content reinstall)"
        write_state "ok" "apply_confirmed" "ESRT success, provenance sha256 match; content unchanged from pre-update snapshot (same-content reinstall)"
    else
        log "CONFIRMED: DTB's provenance sha256 matches the linux-modules-${RUNNING_KVER} package actually installed on this device — same build event"
        write_state "ok" "apply_confirmed" "ESRT success, provenance sha256 match"
    fi
    exit 0
fi

log "WARNING: DTB's provenance sha256=${RUNNING_DTB_SHA} does not match installed linux-modules-${RUNNING_KVER} (${RUNNING_INSTALLED_DTB_SHA}) — this capsule's DTB was NOT built from the kernel package currently installed on this device"

# Localizes the mismatch to specific files: sha256 each packaged .dtb/.dtbo
# file installed under DEVICE_TREE_DIR and diff against the manifest's
# per-file sha256 lines.
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
