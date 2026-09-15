# DTB Capsule Update & Recovery — Implementation Summary

Branch: `dtb-capsule-resolute-devel-tip`

Scope: adds a new `dtb-capsule-<kver>-qcom` Debian package that ships a UEFI
capsule for updating the Qualcomm device tree blob (DTB), plus build-time
generation, install-time staging, and post-reboot runtime verification of
that update — **including automatic GRUB-default recovery when firmware
applies the wrong DTB**. §8.2 flags a known gap that still needs design
work.

## 1. Problem being solved

The kernel package updates DTB files on disk
(`/usr/lib/firmware/<kver>/device-tree/qcom/*.dtb`), but on these Qualcomm
platforms the DTB actually consumed by the bootloader/firmware pre-OS comes
from a dedicated flash partition (`dtb_a`/`dtb_b`, spinor), not from the
filesystem. Updating the kernel package alone does not update what firmware
boots.

UEFI Capsule Update is the standard mechanism to get firmware to flash a new
image into that partition on the next boot. This work adds the tooling to
(a) build a signed capsule containing the new DTB content at kernel-package
build time, (b) stage it for firmware to consume at package-install time,
and (c) verify after reboot that firmware actually applied it — including
detecting rollback/mismatch conditions and, where possible, automatically
recovering from them.

## 2. End-to-end pipeline

```
Build time (kernel package build)
   └─ collect installed .dtb/.dtbo → compute provenance sha256
   └─ embed sha256 into DTB itself (qcom-dtb-capsule-provenance node)
   └─ embed sha256 into linux-modules-<kver> package
   └─ build SoC-filtered FIT DTB image (dtb.bin)
   └─ run qcom_capsule_tool → signed <machine>-dtb.cap per platform
   └─ package into dtb-capsule-<kver>-qcom.deb
        (cap files, capsule.env, expected-kver, expected-dtb-sha256,
         verify script, recovery tool, MOTD script, systemd unit, postinst/prerm)

Install time (dpkg --configure dtb-capsule-<kver>-qcom)
   └─ postinst: gate on linux-modules-<kver> installed + same-build sha256
   └─ match device's ESRT FMP_GUID → pick platform's .cap
   └─ skip if running DTB already matches expected content
   └─ copy .cap to /boot/efi/EFI/UpdateCapsule/
   └─ set OsIndications capsule-delivery bit (efivar), verify read-back

Reboot
   └─ firmware drains /boot/efi/EFI/UpdateCapsule/, flashes DTB partition,
      records result in ESRT (fw_version / last_attempt_status)

Runtime (post-boot, systemd oneshot, every boot)
   └─ dtb-capsule-verify.service → verify-capsule-result.sh
   └─ cross-checks kernel version, ESRT result, DTB content sha256
   └─ on mismatch/rollback/failure with a matching kernel available:
        best-effort calls dtb-capsule-recovery --auto to switch GRUB default
   └─ writes /var/lib/dtb-capsule/last-verify-state
   └─ /etc/update-motd.d/85-dtb-capsule surfaces problems on login

Removal (dpkg remove dtb-capsule-<kver>-qcom)
   └─ prerm: deletes this package's staged-but-unconsumed .cap, if present
```

## 3. Build-time changes (compile / package build)

### 3.1 New build flags and package wiring

- `debian.qcom/rules.d/arm64.mk`: `do_dtb_capsule = true` (arm64-only,
  alongside existing `do_dtbs`/`do_fitimage`).
- `debian/rules.d/0-common-vars.mk`: `dtb_capsule_pkg_name =
  dtb-capsule-$(abi_release)-qcom`, plus the cert paths/firmware-version
  defaults consumed by the capsule signing step (`dtb_capsule_cert_leaf`/
  `_root`/`_sub` under `$(DEBIAN)/certs/`, `dtb_capsule_fwver ?= 0.0.2.0`,
  `dtb_capsule_lfwver ?= 0.0.0.0`, `dtb_capsule_storage_type ?= NORUFS`).
- `debian.qcom/control.stub.in`:
  - New `Build-Depends: mtools [arm64]` (used to build a FAT image without
    requiring a loop device / root).
  - New binary package stanza: `dtb-capsule-PKGVER-ABINUM-qcom` (arch:
    arm64, not per-flavour), `Depends: linux-modules-PKGVER-ABINUM-qcom`,
    `Recommends: grub2-common`, and a version-independent
    `Provides/Conflicts/Replaces: dtb-capsule-qcom` so upgrading to a new
    kver's package lets dpkg cleanly replace the previous one instead of
    erroring on shared, non-kver-scoped paths (`verify-capsule-result.sh`,
    `expected-kver`, the systemd unit, etc.).
- `debian/rules.d/2-binary-arch.mk`: new `do_dtb_capsule` blocks in the
  install stage, the packaging/`dh_systemd_enable` stage, and `dh_prep`.
  Key design: DTB content is flavour-agnostic (both `qcom` and `qcom-rt`
  flavours produce identical `.dtb`/`.dtbo` files), so the capsule package
  is built only once using the first flavour's DTBs — same
  `if [ $* = $(firstword $(flavours)) ]` guard already used for
  `linux-bpf-dev`.

### 3.2 Vendored source

Two upstream sources were vendored (as-is, unmodified) into this tree, with
the exact upstream commit recorded in the vendoring commit message for
traceability:

| What | Vendored from | Commit |
|---|---|---|
| `debian.qcom/scripts/qcom_capsule_tool/*.py` (14 modules) | `qualcomm/cbsp-boot-utilities` | `8a0f1deef97beae600910506bfba488976465828` |
| `debian.qcom/qcom-ptool/platforms/iq-x7181-evk/spinor/partitions.conf` | `qualcomm-linux/qcom-ptool` | `fb8c99c308732eaaba427233029f33c5327beebf` |
| `debian.qcom/fitimage/build-dtb-image.sh` | `qualcomm-linux/qcom-dtb-metadata` | `f1596a6b726c232743f968786de375a91d954eca` |

`qcom_capsule_tool` is a Python package invoked as `python3 -m
qcom_capsule_tool.cli <subcommand>`. The dispatcher (`cli.py`) exposes
`create` (the full pipeline used by this build), plus the internal steps it
composes — `sysfw-version-create`, `update-fv-xml`, `fv-create`,
`generate-capsule`, `update-json`, `bin-to-hex` — and a `patch-capsule-cert`
subcommand that exists in the vendored tool (patches a root cert into
`uefi_dtbs`/`xbl_config` ELF images, including transparent `.xz` handling)
but is **not** exercised by the current pipeline, since only the `dtb`
partition is updated.

### 3.3 Build steps added to `2-binary-arch.mk` (per-build, first flavour only)

1. **Collect shipped DTBs**: copy every `.dtb`/`.dtbo` actually installed
   under `usr/lib/firmware/<abi_release>-<flavour>/device-tree/qcom/` (i.e.
   the output of `dtbs_install`, run earlier in the same rule) into a
   staging dir. This directory holds only the final `dtb-y` targets actually
   shipped to the device — not `.dtbo` overlay fragments that exist solely
   as FIT-image inputs and are never installed standalone — so the manifest
   below doesn't later get reported as "missing" by the runtime verifier
   for files that were never meant to be on the device in the first place.
2. **Compute provenance sha256**: `sha256sum` every collected file, sorted
   by filename (`sort -k2,2`) into
   `dtb-provenance-content-sha256sums.txt`, then `sha256sum` that manifest
   file itself → one `dtb_provenance_sha256` value representing the exact
   set of DTB content shipped in this build. This value is the backbone
   that ties build, install, and runtime together (see §6).
3. **Embed provenance into the DTB itself**: `fdtput -p -t s <dtb>
   /qcom-dtb-capsule-provenance dtb-provenance-sha256 <sha256>` on every
   collected `.dtb` — so a running kernel can read back which build produced
   the DTB it's currently booted with, via
   `/sys/firmware/devicetree/base/qcom-dtb-capsule-provenance/`.
4. **Embed provenance into `linux-modules-<kver>`**: writes the same sha256
   to `/usr/lib/modules/<kver>/dtb-provenance-sha256` inside the kernel
   modules package — the "what should be installed for this kernel version"
   reference value, readable even when that DTB isn't the one currently
   active.
5. **Build the FIT DTB image**: `build-dtb-image.sh --dtb-src <dir> --soc
   hamoa purwa --size 4 --out dtb.bin --prune`. Filters the FIT `.its` down
   to only the DTBs needed for the `hamoa`/`purwa` SoCs (excludes DTBs for
   other platforms), keeping `dtb.bin` under the spinor partition's 4MB
   size cap. Builds an external-data FIT image with `mkimage`, wraps it in
   a FAT image via `mtools` (no loop device / root required). `--prune`
   skips any DTB the `.its` references but that's missing from the source
   directory, instead of failing the build.
6. **Generate a signed capsule per platform** (`hamoa`, `purwa`), via
   `qcom_capsule_tool.cli create`:
   - `-S NORUFS -T <IQ-X7181|IQ-X5121>` (storage type / target platform,
     from each machine's `capsule.env`)
   - `--ptool-path <vendored qcom-ptool> --update-partitions dtb` (only the
     `dtb`/`dtb_a`/`dtb_b` partitions are marked `Operation=UPDATE`; every
     other partition in `partitions.conf` stays `Operation=IGNORE`)
   - `-guid <platform FMP_GUID>` (Hamoa: `0F6D58FC-2258-4D27-9E23-D77219B0897C`,
     Purwa: `185a798b-13b2-4595-bd08-e2770a4bb190`)
   - signs with `$(dtb_capsule_cert_leaf)`/`_root`/`_sub`
     (`QcFMPCert.pem`/`QcFMPRoot.pub.pem`/`QcFMPSub.pub.pem`, supplied via
     the CI secrets wired in §3.5)
   - produces `<machine>-dtb.cap`
7. **Package the outputs** into `dtb-capsule-<kver>-qcom.deb`:
   - `/usr/share/dtb-capsule/<machine>/<machine>-dtb.cap` + `capsule.env`
     (per platform)
   - `/usr/share/dtb-capsule/dtb-provenance-content-sha256sums.txt`
     (per-file manifest, used later to localize a content mismatch to a
     specific file)
   - `/usr/share/dtb-capsule/expected-kver` (this package's target kernel
     version)
   - `/usr/share/dtb-capsule/expected-dtb-sha256` (this kver's expected
     aggregate provenance sha256)
   - `/usr/share/dtb-capsule/verify-capsule-result.sh`
   - `/usr/sbin/dtb-capsule-recovery` (from `dtb-capsule-recovery.sh`)
   - `/etc/update-motd.d/85-dtb-capsule`
   - `/lib/systemd/system/dtb-capsule-verify.service`
   - rendered `postinst`/`prerm` (from `debian.qcom/templates/dtb-capsule.
     postinst.in` / `.prerm.in`)
   - systemd wiring: `dh_systemd_enable`/`dh_systemd_start` for
     `dtb-capsule-verify.service` — this package ships only a systemd unit
     (no init.d script), matching this repo's existing convention for other
     systemd-only units; the unit's own `ConditionPathExists` keeps
     postinst-time start from doing anything until a capsule is actually
     staged.

### 3.4 Per-platform capsule parameters (`capsule.env`)

Two platform config files, each just an `FMP_GUID` + `TARGET`:

- **hamoa** (`IQ-X7181`): GUID from the cbsp-boot-utilities
  `uefi_capsule_generation` README, confirmed by reading it directly off
  real Hamoa hardware's ESRT (`/sys/firmware/efi/esrt/.../fw_class`).
- **purwa** (`IQ-X5121`): GUID from the same README; maps to the same
  `qcom-ptool` platform directory (`iq-x7181-evk`) as Hamoa
  (`UpdateFvXml.py`'s `SUPPORTED_PLATFORMS` dict: both `IQ-X7181` and
  `IQ-X5121` point at `iq-x7181-evk`).

### 3.5 CI wiring

`.github/workflows/premerge-pr.yml` adds `secrets: inherit` on the reusable
`build-kernel.yml` call so the pre-merge build can read the `FMPCERT`/
`FMPROOT`/`FMPSUB` secrets needed to populate `debian.qcom/certs/QcFMP*.pem`
for capsule signing — without this, the `-p`/`-x`/`-oc` cert args passed to
`qcom_capsule_tool.cli create` in §3.3 step 6 would have nothing to sign
with in CI.

## 4. Install-time behavior (`dtb-capsule.postinst.in`, runs on `dpkg --configure`)

Runs `stage_capsule()` on every `configure` of the package:

1. **Clears previous verify-state result** (`last-verify-state` file only —
   the ESRT dedup cache and reboot-stall tracking files are owned by
   `verify-capsule-result.sh` and not touched here) — every configure is a
   fresh staging attempt, so the old verification result is stale.
2. **Clears a stale `IsCapsulePendingInPersistedMedia` flag** if set to
   `0x01`: if a prior capsule update failed (e.g. UEFI crash), this EFI
   variable may be stuck in the "update in progress" state, causing
   firmware to reject new capsules. Detects and resets it to `0x00` via
   `efivar -w`; logs a warning if the reset fails (efivar not available, or
   efivarfs not writable).
3. **Determines target kernel version** from the package's own baked-in
   `expected-kver` file; bails out (warn, `return 0` — never fails the
   install) if missing/empty.
4. **Gate 1 — dependency defense-in-depth**: confirms
   `linux-modules-<KVER>` is actually `install ok installed` (guards against
   `--force-depends` bypassing the declared package `Depends`). If not,
   logs an error and **fails the install** (`exit 1`). Under a normal `apt
   install`, this never fires — the declared `Depends` already guarantees
   `linux-modules-<kver>` is installed first.
5. **Gate 2 — same-build check**: this package's `expected-dtb-sha256` must
   equal `linux-modules-<KVER>/dtb-provenance-sha256`; mismatch → `exit 1`.
   Ensures the dtb-capsule package and the kernel package were actually
   built in the same build event.
6. **Platform auto-selection via ESRT**: reads every packaged platform's
   `FMP_GUID` (from its `capsule.env`) and checks it against this device's
   actual ESRT entries (`/sys/firmware/efi/esrt/entries/entry*/fw_class`):
   - 0 matches → skip staging (device doesn't have any of the packaged
     platforms' GUIDs).
   - **>1 match (ambiguous)** → skip staging, record a `last-guid-conflict`
     state file (timestamp, kver, all matched machines) for the runtime
     verifier / MOTD to surface.
   - exactly 1 match → proceeds with that platform's `.cap`.
7. **Already-matches shortcut**: if the running DTB's provenance sha256
   already equals this package's `expected-dtb-sha256`, staging is skipped
   entirely and any stale `.cap` left in `UpdateCapsule/` is removed — so
   next boot's verifier doesn't see it as an unconsumed capsule.
8. **Stale-capsule detection**: if `/boot/efi/EFI/UpdateCapsule/` already
   has an unconsumed capsule from a previous attempt and the `OsIndications`
   capsule-delivery bit is **not** set, logs a warning (firmware likely
   never got the earlier request) but still proceeds to (re)stage.
9. **Stage the capsule**: copies `<machine>-dtb.cap` →
   `/boot/efi/EFI/UpdateCapsule/qcom-dtb-<kver>.cap` (clears any other
   `qcom-dtb-*.cap` first).
10. **Tell firmware to process it**: sets bit 2 of the `OsIndications` EFI
    variable via `efivar -w` (creating the variable if it doesn't exist).
    The little-endian 8-byte value is hand-assembled via `\NNN` octal
    escapes (dash's `printf` builtin does not understand `\xHH`). Reads the
    value back afterward (`le64_from_offset4`) and logs an explicit error if
    the bit did not actually stick — `efivar -w`'s own exit code only
    reflects whether the write syscall was accepted, not whether firmware
    will really honor it.
11. **No reboot is triggered here** — firmware applies the capsule pre-OS on
    the next boot, whenever that happens.

### 4.1 Removal behavior (`dtb-capsule.prerm.in`, runs on package removal)

On `remove`, deletes this package's staged-but-unconsumed capsule at
`/boot/efi/EFI/UpdateCapsule/qcom-dtb-<kver>.cap`, if it's still there. This
file is written by postinst at runtime and is outside dpkg's file list, so
ordinary package removal would otherwise leave it behind — firmware would
still flash the now-uninstalled DTB pre-OS on the next boot even though the
package that shipped it is gone. Does not touch the `OsIndications`
capsule-delivery bit or `/var/lib/dtb-capsule/` state files.

## 5. Runtime verification (post-reboot)

### 5.1 Trigger

`dtb-capsule-verify.service` — a oneshot systemd unit,
`ConditionPathExists=/boot/efi/EFI/UpdateCapsule`, runs
`verify-capsule-result.sh` after `multi-user.target` on every boot. (The
condition only checks the directory *exists*, not that it's non-empty, so
the script itself has to dedup re-checks across boots — see §5.4.)

### 5.2 What it checks — `kver_match_state` (Phase 1)

Whether the installed dtb-capsule package's `expected-kver` matches the
kernel actually running right now (`DTB_CAPSULE_EXPECTED_KVER` vs
`RUNNING_KVER`). See the matrix in §5.8 for the full list of states and
their meaning; two mechanisms behind specific states are worth calling out
here since the matrix doesn't have room for them:

- `reboot_pending` vs. `reboot_stalled` are the same underlying condition
  (expected kernel doesn't match running kernel, with an unconsumed or
  content-already-matched capsule) at two different points in time.
  `check_reboot_stall()` tells them apart via `boot_id`, not a counter, so
  clock skew can't distort it: "just detected this boot" → `reboot_pending`
  (wait for next reboot); "already survived a reboot without resolving" →
  `reboot_stalled` (triggers auto-recovery).
- `kernel_dtb_mismatch` and `no_capsule_for_running_kernel` are
  distinguished by whether the running kernel's own DTB content is
  self-consistent with its installed package — mismatch is the error case,
  self-consistent is benign (a kernel-only install with no matching
  dtb-capsule package).

### 5.3 What it checks — `dtb_pairing_state` (Phase 2, only when `kver_match_state=ok`)

See the matrix in §5.8 for the full list of states. Two mechanisms behind
specific states are worth calling out here:

- `apply_confirmed` is a content-level short-circuit: if the running DTB's
  provenance sha256 already matches `linux-modules-<RUNNING_KVER>`'s
  recorded value, every ESRT check below is skipped entirely — content
  match wins regardless of what firmware reports.
- `apply_failed` decodes the UEFI capsule status code into a human-readable
  reason (`ErrorUnsuccessful`, `ErrorInsufficientResources`,
  `ErrorIncorrectVersion`, `ErrorInvalidFormat`, `ErrorAuthError` (signature
  failure), `ErrorPwrEvtAC`/`ErrorPwrEvtBatt`, `ErrorUnsatisfiedDependencies`).
- `content_mismatch_localized` cross-checks every individual `.dtb`/`.dtbo`
  against the per-file `dtb-provenance-content-sha256sums.txt` manifest to
  name the specific file(s) that differ (or reports "not localized to any
  packaged .dtb/.dtbo" if the differing file isn't a tracked one).
- `ROLLBACK_TARGET_KVER` (used by both `suspected_dtb_rollback` and
  `apply_failed_with_rollback_available`, but classified differently
  depending on whether ESRT reported success or failure — see §5.7) is
  computed **once**, at the top of the script, by scanning every kernel
  under `/usr/lib/modules/*` (`sort -V`, ties resolve to the highest
  version) for one whose own `dtb-provenance-sha256` matches the running
  DTB's. Every branch reuses this single scan result instead of re-scanning.

### 5.4 ESRT dedup

The ESRT scan result is cached per running kernel version
(`last-esrt-cache`: kver/confirmed/detail) — once confirmed for a given
`RUNNING_KVER`, subsequent boots on the same kernel skip the sysfs scan and
recall the cached verdict (`esrt_dedup_skipped=true` in the state file). The
cache is only written when `UpdateCapsule/` is confirmed empty, so an
unconsumed-capsule boot never poisons the cache with a stale result.

### 5.5 Output

Every run writes `/var/lib/dtb-capsule/last-verify-state` (sourceable
`key=value` file): `timestamp`, `boot_id`, `kver`, `kver_match_state`,
`dtb_pairing_state`, `guid_conflict`/`guid_conflict_detail`,
`esrt_dedup_skipped`, `rollback_target_kver`/`rollback_target_available`,
`dtb_kver_content_match`, `detail`, and a one-line human-readable `summary`
(always last, so `tail -1` alone tells you if anything needs attention).
Also logs everything via `logger -t dtb-capsule-verify` (visible via
`journalctl -t dtb-capsule-verify`).

### 5.6 Login-time surfacing

`/etc/update-motd.d/85-dtb-capsule` (runs on every interactive login via
`pam_motd`): prints nothing if the last verify state was fully healthy
(`kver_match_state=ok`, `dtb_pairing_state=apply_confirmed`, no GUID
conflict). Otherwise prints the summary line, the raw state fields, and
points at `journalctl -t dtb-capsule-verify` for detail; for
`kernel_dtb_mismatch`/`reboot_stalled` it also tells the admin to run
`dtb-capsule-recovery` directly. Also detects a stale state file (`boot_id`
mismatch — this boot's check hasn't run/finished yet) and tells the admin to
check back shortly instead of showing a possibly-outdated verdict.

### 5.7 Automatic recovery (`dtb-capsule-recovery.sh`, `/usr/sbin/dtb-capsule-recovery`)

Called best-effort (`run_auto_recovery()` — no-op if the tool is missing or
not executable) from four Phase-1/Phase-2 branches, always gated on a
matching kernel already having been found:

- `kernel_dtb_mismatch` (Phase 1, when `ROLLBACK_TARGET_KVER` is non-empty)
- `reboot_stalled` (Phase 1, when `ROLLBACK_TARGET_KVER` is non-empty)
- `suspected_dtb_rollback` (Phase 2)
- `apply_failed_with_rollback_available` (Phase 2)

**Matching**: scans `/usr/lib/modules/*`, finds every kernel whose own
`dtb-provenance-sha256` equals the running DTB's, resolves ties to the
highest `sort -V` version (`find_matching_kernels_for_dtb`).

**Switching** (`set_grub_default`): locates the target kernel's
`menuentry` in `/boot/grub/grub.cfg` via `awk` (excluding `recovery`
entries), builds the `Advanced options for Ubuntu><entry>` submenu path,
then `grub-set-default` → patches `GRUB_DEFAULT=` in `/etc/default/grub` via
`sed` → runs `update-grub` if present.

**Modes**: `--auto` (scripted; errors out with no changes made if no match
found), `--list` (prints every installed kernel with `match`/`mismatch`/
`unknown` against the running DTB), and a bare interactive mode (numbered
selection).

**Known limitation (accepted scope)**: the matching logic only cares
whether DTB *content* matches — it has no notion of whether that kernel has
actually been verified healthy at runtime. If a newly-applied kernel
repeatedly crashes or hangs before `verify-capsule-result.sh` can complete,
there is currently no automatic mechanism to detect this and fall back to the
previously-known-good kernel. The device will remain stuck in a crash loop.
This scenario — where the kernel fails to boot successfully but the DTB was
already applied by firmware — is addressed by the boot-counter mechanism
proposed in §8.2.

### 5.8 Verification Result Classification Matrix

#### 5.8.1 Kernel Version × Capsule Application State Matrix

| `kver_match_state` | `dtb_pairing_state` | Meaning | Auto-recovery? |
|---|---|---|---|
| `package_mismatch` | (N/A) | Package targets a kernel whose `linux-modules` is in an abnormal dpkg state | No |
| `reboot_pending` | (N/A) | Capsule staged/content-matched for a different kernel, awaiting first reboot into it | No — wait |
| `reboot_stalled` | (N/A) | Same as above, but survived a reboot without resolving | **Yes**, if a matching kernel exists |
| `no_capsule_for_running_kernel` | (N/A) | No capsule targets the running kernel, but its own DTB content is self-consistent | No — benign |
| `kernel_dtb_mismatch` | (N/A) | Running kernel's own DTB content doesn't match its installed package | **Yes**, if a matching kernel exists |
| `unknown` | (N/A) | Can't determine running kernel's DTB self-consistency | No |
| `ok` | `pending` | Capsule not yet confirmed applied by firmware | No — wait |
| `ok` | `apply_failed` | Firmware reported the capsule update failed, no rollback target | No |
| `ok` | `apply_failed_with_rollback_available` | Firmware reported apply failed, but a matching kernel exists | **Yes** |
| `ok` | `suspected_dtb_rollback` | ESRT reports success but running DTB content belongs to another installed kernel | **Yes**, if that kernel's package is still installed |
| `ok` | `apply_confirmed` | ✅ DTB content matches the running kernel's own package | No action needed |
| `ok` | `content_mismatch_localized` | ESRT success but DTB content matches neither the running kernel nor any other installed kernel | No — needs manual investigation |
| `ok` | `unknown` | Can't confirm capsule result (missing provenance node/reference) | No |

## 6. Provenance / traceability mechanism (cross-cutting)

A single `dtb_provenance_sha256` value — computed once at build time from
the sorted sha256 list of every `.dtb`/`.dtbo` actually shipped — is the
backbone that ties build, install, and runtime together:

- Embedded in the DTB itself (`qcom-dtb-capsule-provenance` FDT node) →
  readable by a running kernel regardless of which package installed it.
- Embedded in `linux-modules-<kver>` → the "expected" value for that
  specific kernel version, readable without needing that DTB to be
  currently active — this is what lets the runtime verifier and the
  recovery tool scan *every installed kernel* (not just the running one)
  for a content match.
- A per-file manifest (`dtb-provenance-content-sha256sums.txt`) is also
  shipped, so a mismatch in the aggregate hash can be localized to the
  specific `.dtb`/`.dtbo` that differs, rather than only reporting
  "something changed."

This is what lets `verify-capsule-result.sh` distinguish, after any reboot:
same kernel with matching DTB, same kernel with a stale/rolled-back DTB
(belonging to some other installed kernel), or a kernel/DTB pairing that
matches nothing installed at all — purely from sysfs + package-installed
files, with no dependency on network or a build-time database, and (for the
first two cases) hand off to `dtb-capsule-recovery` to actually fix it.

### 6.1 Why a content hash, not just the kernel version string

The kernel version string (`abi_release`, e.g. `6.8.0-1013-qcom`) only
changes when a developer deliberately bumps the ABI number in the
changelog. DTB/`.dts` content changes far more often than that during
development: rebuilding the same PR/branch, cherry-picking the same kver
onto different branches, or CI re-running the same source at a different
commit can all produce a different DTB while the version **string** stays
byte-for-byte identical. A comparison based purely on the version string
cannot see any of this — it would report "match" even when the DTB actually
installed does not correspond to what was actually built for that string.

This is exactly the failure mode Gate 2 in `dtb-capsule.postinst.in` (§4,
step 5) is closing: even when `linux-modules-<KVER>` is installed and the
version string matches, the postinst still refuses to stage the capsule
unless this package's `expected-dtb-sha256` equals
`linux-modules-<KVER>/dtb-provenance-sha256` — i.e. unless the dtb-capsule
package and the kernel package actually came from the *same build event*,
not just a build that happens to share the same version string. Dropping
the content hash in favor of a bare version-string comparison would remove
this check's ability to catch that case; the version string alone cannot
distinguish "same string, same content" from "same string, different
content."

### 6.2 Alternative: version string + build commit hash

A candidate approach to reduce the overhead of computing and embedding full
content hashes would be to combine the kernel version string (`abi_release`)
with a short build commit hash (e.g. the first 12 hex digits of the kernel
source tree's HEAD commit at build time). This hybrid identifier would be:

- **Stable across rebuilds of the same source**: the version string + commit
  hash pair uniquely identifies a specific kernel source snapshot, so
  rebuilding the same commit produces the same identifier.
- **Sensitive to source changes**: cherry-picking, rebasing, or CI re-running
  at a different commit changes the hash, so the identifier differs even if
  the version string stays the same.
- **Cheaper to compute**: requires only a git rev-parse at build time, no
  need to collect, sort, and hash all DTB files.
- **Smaller to store**: a 12-char hex string is much smaller than a full
  sha256 hex digest (64 chars).

**Trade-offs vs. content hash**:
- **Pro**: simpler, faster, smaller. Catches source-level changes (commits,
  cherry-picks, rebases) that the version string alone misses.
- **Con**: does not catch content drift caused by toolchain changes (compiler
  version, device-tree-compiler version, build flags) that produce different
  DTB output from the same source. If the kernel source is identical but the
  build environment differs, the version+commit pair would still match even
  though the DTB content differs.

This approach would be suitable if the build environment is tightly
controlled (e.g. always built in the same CI container with pinned tool
versions) and source-level changes are the primary concern. The current
content-hash approach is more robust for environments where toolchain
versions or build flags may vary.

## 7. Known temporary workaround

`debian.qcom/qcom-ptool/platforms/iq-x7181-evk/spinor/partitions.conf`:
renamed the `dtb`/`dtb_BACKUP` partition entries to `dtb_a`/`dtb_b`. This is
a workaround: the real on-device flash meta table already uses `dtb_a`/
`dtb_b` naming, but the vendored `partitions.conf` still had the older
`dtb`/`dtb_BACKUP` naming, so a capsule built against the vendored file
failed to apply on real hardware. The proper fix — updating the meta's own
partition table to match — is future work; this rename is what makes
partition matching work correctly against real hardware today.

## 8. Known Limitations & Future Work

### 8.1 Current scope

- Only the `dtb` partition (`dtb_a`/`dtb_b`) is updated (not `xbl_config`,
  `uefi_dtbs`).
- Only Hamoa (`IQ-X7181`) and Purwa (`IQ-X5121`) platforms supported.
- Capsule signing uses pre-generated certs from CI secrets (no HSM
  integration).
- Auto-recovery is content-matching only, with the crash-loop gap described
  in §5.7 and §8.2.

### 8.2 Future work

- Partition table alignment (§7 workaround → proper fix on the device meta
  side).
- Support for additional SoCs/platforms.
- **Boot-counter mechanism for crash recovery**: When a newly-applied kernel
  fails to boot (crashes, hangs, or panics before `verify-capsule-result.sh`
  can run), the device needs a way to automatically fall back to the
  previously-known-good kernel without manual intervention. The current
  content-matching recovery in `dtb-capsule-recovery` cannot handle this case
  because it has no notion of kernel health — it only knows whether DTB
  content matches.

  **Proposed design**: A GRUB boot-counter state machine layered on grubenv:
  - **Arm phase**: Before switching to a newly-applied kernel, a helper tool
    records the trial kernel, the current known-good kernel as fallback, and
    a retry budget (e.g. 3 attempts) into grubenv.
  - **Trial phase**: A GRUB script fragment reads this state on each boot. If
    the trial is not yet confirmed, it decrements the retry counter and boots
    the trial kernel. Once the counter reaches zero, GRUB automatically boots
    the fallback kernel instead.
  - **Confirm phase**: `verify-capsule-result.sh` confirms the trial (clears
    the armed state) once it successfully observes `apply_confirmed` for the
    new kernel, indicating the kernel booted and DTB content is correct.

  **Open design questions**:
  - How to prevent the rejected kernel from being selected again by
    `dtb-capsule-recovery`'s content-matching logic after the boot-counter
    has already rejected it? (Needs a rejection marker or exclusion list.)
  - What to do with the rejected kernel afterward: leave it installed but
    excluded from auto-recovery, or uninstall it?
  - How to preserve diagnostic data (logs, coredumps) for post-mortem analysis
    while managing storage and avoiding repeated collection of the same
    failure?
  - How to integrate with existing GRUB configuration and ensure the
    boot-counter survives across GRUB updates?

- `dtb-capsule.postinst.in` currently gates staging only on
  `linux-modules-<kver>` being installed; it does not check that
  `linux-image-<kver>` is installed or that grub.cfg actually has a
  menuentry for it before letting firmware make the DTB flash.

## 10. Troubleshooting Guide

### 10.1 Capsule not applied

- Check: `tail -1 /var/lib/dtb-capsule/last-verify-state` (one-line summary)
  or `cat` the whole file for all fields.
- Check: `journalctl -t dtb-capsule-verify`
- Check: ESRT entry exists (`cat /sys/firmware/efi/esrt/entries/entry*/fw_class`)
- Check: `OsIndications` bit set (`efivar -p -n
  8be4df61-93ca-11d2-aa0d-00e098032b8c-OsIndications`)

### 10.2 Content mismatch (`content_mismatch_localized`)

- Check the per-file manifest:
  `cat /usr/share/dtb-capsule/dtb-provenance-content-sha256sums.txt`
- Compare against the actually-installed files under
  `/usr/lib/firmware/<kver>/device-tree/qcom/`
- The `detail` field in `last-verify-state` names which specific
  `.dtb`/`.dtbo` file(s) differ (or says "not localized" if the differing
  file isn't a tracked one).

### 10.3 GUID conflict

- Check: `cat /var/lib/dtb-capsule/last-guid-conflict`
- Check: device's ESRT entries (`ls /sys/firmware/efi/esrt/entries/`)
- Investigate: whether more than one packaged platform's `FMP_GUID` matches
  this device's ESRT — this is treated as ambiguous and staging is skipped
  entirely.

### 10.4 Capsule not staged (dependency issue)

Under normal `apt install`, this cannot happen — the declared `Depends`
guarantees `linux-modules-<kver>` is installed first. If `dtb-capsule` was
installed with `--force-depends` while `linux-modules` was missing,
postinst fails the install outright (`exit 1`) rather than silently
skipping, so the package is left unconfigured (not "installed with no
capsule staged"):

- Check: `journalctl -t dtb-capsule-verify` for the "linux-modules is not
  installed" error, or the postinst's own stderr from the failed
  `dpkg --configure`.
- Fix: `apt install linux-modules-<kver>-qcom` first, then
  `dpkg --configure dtb-capsule-<kver>-qcom`.
- Avoid `--force-depends` to bypass dependency checks — it defeats Gate 1
  in §4.

### 10.5 Mismatch persists after `dtb-capsule-recovery` ran

- Run `dtb-capsule-recovery --list` to see every installed kernel's match
  status against the running DTB.
- If no kernel shows `match`, the recovery tool has nothing to switch to —
  this is the §8.1/§5.7 known limitation (no healthy content-matching
  kernel installed), not a bug in the tool.
- Check `grub-set-default`/`update-grub` actually ran without error in
  `journalctl -t dtb-capsule-recovery`; a missing `menuentry` for the target
  kernel in `/boot/grub/grub.cfg` will make `set_grub_default` fail loudly.
