#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# SPDX-License-Identifier: BSD-3-Clause-Clear
#
# =============================================================================
# Installed as /usr/sbin/dtb-capsule-recovery. Sets the GRUB default boot
# entry to a kernel whose own DTB content is self-consistent, either
# automatically (--auto) or via interactive selection.
set -e

MODULES_DIR="${MODULES_DIR:-/usr/lib/modules}"
GRUB_CFG="${GRUB_CFG:-/boot/grub/grub.cfg}"
GRUB_DEFAULT_FILE="${GRUB_DEFAULT_FILE:-/etc/default/grub}"
DT_PROVENANCE_DIR="${DT_PROVENANCE_DIR:-/sys/firmware/devicetree/base/qcom-dtb-capsule-provenance}"

log() { echo "dtb-capsule-recovery: $*" >&2; logger -t dtb-capsule-recovery "$*" 2>/dev/null || true; }

dtb_provenance_sha256_for_kver() {
    _f="${MODULES_DIR}/$1/dtb-provenance-sha256"
    [ -f "$_f" ] || return 1
    cat "$_f"
}

RUNNING_DTB_SHA=""
if [ -f "${DT_PROVENANCE_DIR}/dtb-provenance-sha256" ]; then
    RUNNING_DTB_SHA="$(tr -d '\0' < "${DT_PROVENANCE_DIR}/dtb-provenance-sha256" 2>/dev/null || echo "")"
fi

# Kernels whose own dtb-provenance-sha256 equals $1.
find_matching_kernels_for_dtb() {
    _target_sha="$1"
    for _kver in $(ls "$MODULES_DIR" 2>/dev/null | sort -V); do
        _kver_sha="$(dtb_provenance_sha256_for_kver "$_kver" 2>/dev/null || echo "")"
        [ -n "$_kver_sha" ] && [ "$_kver_sha" = "$_target_sha" ] && printf '%s\n' "$_kver"
    done
}

# Points GRUB's default boot entry at $1's menu entry.
set_grub_default() {
    _target_kver="$1"
    if ! command -v grub-set-default >/dev/null 2>&1; then
        log "ERROR: grub-set-default not available"
        return 1
    fi
    if [ ! -f "$GRUB_CFG" ]; then
        log "ERROR: ${GRUB_CFG} not found"
        return 1
    fi
    _entry="$(awk -F"'" -v kver="$_target_kver" '/menuentry / && $2 ~ kver && $2 !~ /recovery/ {print $2; exit}' "$GRUB_CFG")"
    if [ -z "$_entry" ]; then
        log "ERROR: no grub menu entry found for kernel ${_target_kver}"
        return 1
    fi
    _submenu_entry="Advanced options for Ubuntu>${_entry}"
    grub-set-default "$_submenu_entry"
    if [ -f "$GRUB_DEFAULT_FILE" ]; then
        sed -i "s/^GRUB_DEFAULT=.*/GRUB_DEFAULT=\"${_submenu_entry}\"/" "$GRUB_DEFAULT_FILE" || log "WARNING: failed to update GRUB_DEFAULT in ${GRUB_DEFAULT_FILE}"
    fi
    if command -v update-grub >/dev/null 2>&1; then
        update-grub >/dev/null 2>&1 || log "WARNING: update-grub failed"
    fi
    log "set grub default to '${_submenu_entry}'"
}

list_kernels() {
    echo "Running DTB provenance sha256: ${RUNNING_DTB_SHA:-unknown}"
    echo
    _idx=0
    for _kver in $(ls "$MODULES_DIR" 2>/dev/null | sort -V); do
        _idx=$((_idx + 1))
        _kver_sha="$(dtb_provenance_sha256_for_kver "$_kver" 2>/dev/null || echo "")"
        if [ -n "$_kver_sha" ] && [ "$_kver_sha" = "$RUNNING_DTB_SHA" ]; then
            _mark="match"
        elif [ -n "$_kver_sha" ]; then
            _mark="mismatch"
        else
            _mark="unknown"
        fi
        printf '%2d) %-40s %s\n' "$_idx" "$_kver" "$_mark"
    done
}

case "$1" in
    --auto)
        [ -n "$RUNNING_DTB_SHA" ] || { log "ERROR: no DTB provenance node at ${DT_PROVENANCE_DIR}"; exit 1; }
        MATCHES="$(find_matching_kernels_for_dtb "$RUNNING_DTB_SHA")"
        [ -n "$MATCHES" ] || { log "ERROR: no installed kernel's DTB matches the running DTB"; exit 1; }
        SELECTED="$(echo "$MATCHES" | tail -1)"
        log "selected ${SELECTED} (latest of: $(echo "$MATCHES" | tr '\n' ' '))"
        set_grub_default "$SELECTED"
        ;;
    --list)
        list_kernels
        ;;
    *)
        list_kernels
        echo
        printf 'Select a kernel number to set as the GRUB default: '
        read -r _selection
        SELECTED="$(ls "$MODULES_DIR" 2>/dev/null | sort -V | sed -n "${_selection}p")"
        [ -n "$SELECTED" ] || { log "ERROR: invalid selection"; exit 1; }
        set_grub_default "$SELECTED"
        ;;
esac
