#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
#
# SPDX-License-Identifier: BSD-3-Clause-Clear
#
# =============================================================================
# Installed as /etc/update-motd.d/85-dtb-capsule. Run by pam_motd on every
# interactive login; prints nothing when the last verify-capsule-result.sh
# run recorded a fully healthy state, so admins only see this when something
# needs attention.
STATE_DIR="${STATE_DIR:-/var/lib/dtb-capsule}"
VERIFY_STATE_FILE="${STATE_DIR}/last-verify-state"
BOOT_ID_NODE="${BOOT_ID_NODE:-/proc/sys/kernel/random/boot_id}"

[ -f "$VERIFY_STATE_FILE" ] || exit 0

boot_id=""
kver_match_state=""
capsule_state=""
guid_conflict=""
guid_conflict_detail=""
dtb_kver_content_match=""
dtb_build_origin=""
dtb_content_unchanged=""
kernel_origin=""
detail=""
summary=""
# shellcheck disable=SC1090
. "$VERIFY_STATE_FILE"

# Stale boot_id means this boot's check hasn't run/finished yet.
CURRENT_BOOT_ID="$(cat "$BOOT_ID_NODE" 2>/dev/null || echo "")"
if [ -n "$CURRENT_BOOT_ID" ] && [ "$boot_id" != "$CURRENT_BOOT_ID" ]; then
    echo "*** dtb-capsule: capsule verification for this boot has not completed yet ***"
    echo "    check again shortly, or inspect directly: cat ${VERIFY_STATE_FILE}"
    exit 0
fi

[ "$kver_match_state" = "ok" ] && [ "$capsule_state" = "apply_confirmed" ] && [ "$guid_conflict" != "true" ] && exit 0

echo "*** dtb-capsule: last verify state is not fully healthy ***"
echo "    ${summary}"
echo "    kver_match_state=${kver_match_state} capsule_state=${capsule_state}"
echo "    kernel_origin=${kernel_origin} dtb_build_origin=${dtb_build_origin} dtb_kver_content_match=${dtb_kver_content_match}"
[ -n "$detail" ] && echo "    detail: ${detail}"
echo "    run 'journalctl -t dtb-capsule-verify' for details."

exit 0
