#!/usr/bin/env bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# build-kernel-deb.sh - Build Ubuntu kernel .deb packages from a Canonical
#                       source tree (as checked out from a series branch)
#
# Usage:
#   build-kernel-deb.sh [SOURCE_DIR] [ARCH] [FLAVOR] [JOBS] [VERSION_SUFFIX]
#
# Arguments:
#   SOURCE_DIR      Root of the kernel source tree containing debian/ (default: .)
#   ARCH            Target Debian architecture to compile for: arm64 (default: arm64).
#                    Build host may be arm64 (native) or amd64 (cross-compile via
#                    gcc-aarch64-linux-gnu); amd64 is not a supported target since
#                    the qcom/qcom-rt flavours are arm64-only.
#   FLAVOR          Kernel flavour: qcom | qcom-rt | all (default: qcom)
#   JOBS            Parallel make jobs (default: 8; incremental rebuilds with
#                    few changed files scale worse than expected past this
#                    due to scheduling overhead — override explicitly for a
#                    from-scratch build on a many-core machine)
#   VERSION_SUFFIX  Optional string appended to the package/kernel version,
#                    e.g. "+g1a2b3c4" or "+myuser1" (default: none). Pass
#                    "auto" to generate "+g<short commit>" from SOURCE_DIR's
#                    current HEAD (requires SOURCE_DIR to be a git work tree).
#                    Modifies debian.qcom/changelog, but the script restores it
#                    to HEAD before every run, so this never leaves the tree
#                    dirty.
#
# Environment:
#   INCREMENTAL_BUILD  Set to 0/false/no/off to force debian/rules clean's
#                       rm -rf debian/build debian/stamps even when prior
#                       build state exists, so the next build is guaranteed
#                       clean (default: 1, incremental — kbuild only
#                       recompiles files that actually changed). Falls back
#                       to a full clean automatically on the first build for
#                       a given SOURCE_DIR. Do not leave enabled across a
#                       change to debian/control-level Build-Depends, or
#                       when a guaranteed-clean build is needed (e.g. before
#                       a release/CI run).
#   DBGSYM             Set to 1/true/yes/on to also build the unstripped
#                       -dbgsym.ddeb debug symbol packages alongside the
#                       .deb packages (default: 0, disabled).
#
# Output:
#   Built .deb packages are placed in ./output/ relative to the working
#   directory from which this script is invoked, unless OUTPUT_DIR is set
#   in the environment (relative or absolute; normalized to an absolute path
#   up front), in which case that path is used instead.
#
# Notes:
#   • Supports native (arm64 host) and cross (amd64 host, e.g. via dpkg
#     cross-architecture + gcc-aarch64-linux-gnu) builds.
#   • Needs ~20 GB free disk space.
#   • A full build (all flavours) takes 2+ hours; a single flavour ~1 hour.
#   • Designed to run inside a Docker container with preinstalled dependencies.
#   • For Docker builds, use the docker-build-kernel.sh wrapper.

set -euo pipefail

SOURCE_DIR="${1:-.}"
ARCH="${2:-arm64}"
FLAVOR="${3:-qcom}"
JOBS="${4:-8}"
VERSION_SUFFIX="${5:-}"
SKIP_BUILD_DEP="${SKIP_BUILD_DEP:-0}"
INCREMENTAL_BUILD="${INCREMENTAL_BUILD:-1}"
DBGSYM="${DBGSYM:-0}"

OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/output}"
# Normalize to an absolute path now, before any `cd` below changes pwd out
# from under a relative OUTPUT_DIR.
mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
hr()   { log "$(printf '%0.s─' {1..60})"; }

is_truthy() {
  case "${1:-}" in
    1|[tT][rR][uU][eE]|[yY][eE][sS]|[oO][nN]) return 0 ;;
    *) return 1 ;;
  esac
}

# is_git_worktree, add_cleanup/run_cleanup (+ trap), run_debian_rules_clean,
# reset_and_track_changelog, patch_native_host_tool_deps: shared with
# build-docker-image.sh, defined in gen-real-control.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/gen-real-control.sh
source "${SCRIPT_DIR}/lib/gen-real-control.sh"

if [ "${VERSION_SUFFIX}" = "auto" ]; then
  is_git_worktree "${SOURCE_DIR}" \
    || die "VERSION_SUFFIX=auto requires '${SOURCE_DIR}' to be a git work tree"
  AUTO_COMMIT="$(git -C "${SOURCE_DIR}" rev-parse --short HEAD)"
  VERSION_SUFFIX="+g${AUTO_COMMIT}"
fi

BUILD_ARCH="$(dpkg --print-architecture)"
CROSS_BUILD=false
if [ "${ARCH}" != "${BUILD_ARCH}" ]; then
  CROSS_BUILD=true
fi

hr
log "Ubuntu kernel .deb build"
log "  Source dir : ${SOURCE_DIR}"
log "  Build arch : ${BUILD_ARCH}"
log "  Host arch  : ${ARCH}$([ "${CROSS_BUILD}" = true ] && echo ' (cross-compiling)')"
log "  Flavour    : ${FLAVOR}"
log "  Jobs       : ${JOBS}"
log "  Output dir : ${OUTPUT_DIR}"
log "  Version    : ${VERSION_SUFFIX:-(none)}"
log "  Incremental: $(is_truthy "${INCREMENTAL_BUILD}" && echo enabled || echo disabled)"
log "  Dbgsym     : $(is_truthy "${DBGSYM}" && echo enabled || echo disabled)"
hr

# ---------------------------------------------------------------------------
# 1. Validate source tree
# ---------------------------------------------------------------------------
[ -f "${SOURCE_DIR}/debian/rules" ] \
  || die "No debian/rules found in '${SOURCE_DIR}' – is this a kernel source tree?"

# ---------------------------------------------------------------------------
# 2. Prepare build environment
# ---------------------------------------------------------------------------
hr
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

if [ "${CROSS_BUILD}" = true ]; then
  if dpkg --print-foreign-architectures | grep -qxF "${ARCH}"; then
    log "dpkg foreign architecture ${ARCH} already enabled (baked into the build image) — skipping."
  else
    log "Enabling dpkg foreign architecture ${ARCH} for cross-compilation..."
    ${SUDO} dpkg --add-architecture "${ARCH}"
  fi
fi

# For cross-compilation, set DEB_HOST_ARCH and related variables.
CROSS_ENV=""
if [ "${CROSS_BUILD}" = true ]; then
  DEB_HOST_GNU_TYPE="$(dpkg-architecture -a"${ARCH}" -qDEB_HOST_GNU_TYPE)"
  DEB_HOST_MULTIARCH="$(dpkg-architecture -a"${ARCH}" -qDEB_HOST_MULTIARCH)"
  CROSS_ENV="DEB_HOST_ARCH=${ARCH} DEB_HOST_GNU_TYPE=${DEB_HOST_GNU_TYPE} DEB_HOST_MULTIARCH=${DEB_HOST_MULTIARCH}"
fi

# `clean` regenerates debian/control and copies debian.<flavour>/changelog to debian/changelog.
DEBIAN_DIR="$(get_debian_dir "${SOURCE_DIR}")"

reset_and_track_changelog "${SOURCE_DIR}" "${DEBIAN_DIR}"

if [ -n "${VERSION_SUFFIX}" ]; then
  export DEBEMAIL="${DEBEMAIL:-build-kernel-deb@localhost}"
  export DEBFULLNAME="${DEBFULLNAME:-build-kernel-deb.sh}"

  # Ensure dch is available
  if ! command -v dch >/dev/null 2>&1; then
    if [ -n "${SUDO}" ] && ! command -v sudo >/dev/null 2>&1; then
      die "dch is missing and this isn't running as root with no sudo binary available to install devscripts. Install devscripts into the image ahead of time, or run as root."
    fi
    log "dch not found, installing devscripts..."
    ${SUDO} apt-get update -qq
    ${SUDO} apt-get install -y devscripts || die "Failed to install devscripts"
  fi

  BASE_VERSION="$(dpkg-parsechangelog -l"${SOURCE_DIR}/${DEBIAN_DIR}/changelog" -S Version)" \
    || die "Failed to read current version from ${SOURCE_DIR}/${DEBIAN_DIR}/changelog"
  rm -f "${SOURCE_DIR}/${DEBIAN_DIR}/changelog.dch"
  log "Tagging local version suffix '${VERSION_SUFFIX}' onto ${DEBIAN_DIR}/changelog..."
  ( cd "${SOURCE_DIR}" && dch --changelog "${DEBIAN_DIR}/changelog" \
      --newversion "${BASE_VERSION}${VERSION_SUFFIX}" "Local build" ) \
    || die "Failed to apply version suffix via dch"

  if is_git_worktree "${SOURCE_DIR}"; then
    add_cleanup "git -C \"${SOURCE_DIR}\" checkout -- \"${DEBIAN_DIR}/changelog\" 2>/dev/null || true"
  fi
fi

BUILD_STATE_DIR="${SOURCE_DIR}/debian/build"
if is_truthy "${INCREMENTAL_BUILD}" && [ -d "${BUILD_STATE_DIR}" ]; then
  refresh_control_incremental "${SOURCE_DIR}" "${DEBIAN_DIR}" "${CROSS_ENV}"
  invalidate_flavour_stamps "${SOURCE_DIR}/debian/stamps" "${FLAVOR}"
else
  is_truthy "${INCREMENTAL_BUILD}" \
    && log "INCREMENTAL_BUILD set but no previous build state found under ${BUILD_STATE_DIR} — doing a full 'debian/rules clean' this first time."
  run_debian_rules_clean "${SOURCE_DIR}" "${CROSS_ENV}"
fi

# ---------------------------------------------------------------------------
# 3. Install build dependencies (if not skipped)
# ---------------------------------------------------------------------------
hr

log "Installing build dependencies${SUDO:+ (requires sudo)}..."
if is_truthy "${SKIP_BUILD_DEP}"; then
  log "  SKIP_BUILD_DEP set — skipping apt-get build-dep."
else
  # Not root and no sudo: apt-get build-dep can't escalate. Fail fast with a
  # clear error instead of a confusing "sudo: command not found" from deep
  # inside apt. Fix: SKIP_BUILD_DEP=1 with deps preinstalled (e.g. baked into
  # the image via build-docker-image.sh), or run as root.
  if [ -n "${SUDO}" ] && ! command -v sudo >/dev/null 2>&1; then
    die "apt-get build-dep needs root, but this isn't running as root and no sudo binary is available. Set SKIP_BUILD_DEP=1 (and make sure build-deps are already installed — e.g. baked into the image via build-docker-image.sh), or run as root."
  fi

  # Enable deb-src for build-dep to work
  log "Enabling deb-src sources..."
  ${SUDO} sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true

  if [ "${CROSS_BUILD}" = true ]; then
    patch_native_host_tool_deps "${SOURCE_DIR}/debian/control"
  fi

  ${SUDO} apt-get update -qq
  BUILD_DEP_PROFILE_OPT=""
  if [ "${CROSS_BUILD}" = true ]; then
    # For cross-compilation, use the "cross" build profile.
    BUILD_DEP_PROFILE_OPT="--build-profiles cross"
  fi
  ( cd "${SOURCE_DIR}" && ${SUDO} apt-get build-dep -y --host-architecture "${ARCH}" ${BUILD_DEP_PROFILE_OPT} . ) \
    || die "apt-get build-dep failed"

  if [ "${CROSS_BUILD}" = true ]; then
    # For cross-compilation, also install native copies of build dependencies.
    log "Installing native (build-arch) copies of build dependencies for host-tool helpers..."
    ( cd "${SOURCE_DIR}" && ${SUDO} apt-get build-dep -y . ) \
      || die "apt-get build-dep (native pass) failed"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Build
# ---------------------------------------------------------------------------
hr
log "Starting kernel build (flavour=${FLAVOR}, arch=${ARCH}, jobs=${JOBS})..."

# Determine the debian/rules target(s). binary-${FLAVOR} alone builds only
# the arch-specific flavour packages; the common linux-qcom-headers-*
# package (arch: all, hard-depended on by linux-headers-*-${FLAVOR}) comes
# from binary-indep only, so it must be appended explicitly. `all` maps to
# "binary", which already runs binary-arch + binary-indep for every flavour.
if [ "${FLAVOR}" = "all" ]; then
  RULES_TARGET="binary"
else
  RULES_TARGET="binary-${FLAVOR} binary-indep"
fi

export DEB_BUILD_OPTIONS="parallel=${JOBS} nocheck"

# do_skip_checks=true bypasses the config-policy check (avoids failures when
# optional toolchains like Rust/bindgen are absent). do_dbgsym_package
# controls the unstripped -dbgsym.ddeb (vmlinux + modules with full debug
# symbols) — same knob and default as the CI build-kernel.yml workflow.
# RULES_TARGET is unquoted so make receives multiple targets as separate
# arguments.
DBGSYM_OPT="do_dbgsym_package=false"
is_truthy "${DBGSYM}" && DBGSYM_OPT="do_dbgsym_package=true"
(
  cd "${SOURCE_DIR}"
  env ${CROSS_ENV} fakeroot debian/rules ${RULES_TARGET} do_skip_checks=true "${DBGSYM_OPT}" \
    || die "debian/rules ${RULES_TARGET} failed"
)

# ---------------------------------------------------------------------------
# 5. Collect output packages
# ---------------------------------------------------------------------------
hr
# Clear only the artifact types we produce, not the whole dir.
mkdir -p "${OUTPUT_DIR}"
rm -f "${OUTPUT_DIR}"/*.deb "${OUTPUT_DIR}"/*.ddeb "${OUTPUT_DIR}"/*.changes "${OUTPUT_DIR}"/*.buildinfo

# Collect .deb/.ddeb files from the parent directory matching this build's version.
PARENT_DIR=$(dirname "$(realpath "${SOURCE_DIR}")")
DEB_VERSION="$(dpkg-parsechangelog -l "${SOURCE_DIR}/debian/changelog" -S Version)" \
  || die "Failed to read package version from debian/changelog"
# .deb filenames drop the epoch ("1:7.0.0" -> "7.0.0..."); no-op otherwise.
DEB_VERSION="${DEB_VERSION##*:}"
[ -n "${DEB_VERSION}" ] \
  || die "Empty package version parsed from ${SOURCE_DIR}/debian/changelog"

# Read into the parent shell so the counter survives to the empty-collection check.
collected=0
while IFS= read -r -d '' f; do
  mv "${f}" "${OUTPUT_DIR}/" || die "Failed to move $(basename "${f}") to ${OUTPUT_DIR}"
  log "  Collected: $(basename "${f}")"
  collected=$((collected + 1))
done < <(find "${PARENT_DIR}" -maxdepth 1 -name "*_${DEB_VERSION}_*" \
           \( -name "*.deb" -o -name "*.ddeb" -o -name "*.changes" -o -name "*.buildinfo" \) -print0)

[ "${collected}" -gt 0 ] \
  || die "Build finished but no artifacts matching version '${DEB_VERSION}' were found in ${PARENT_DIR}"

hr
log "Build complete."
log ""
log "Output packages:"
ls -lh "${OUTPUT_DIR}"/ 2>/dev/null \
  || log "  (no output files found — check build log above)"
