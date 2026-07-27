#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# build-docker-image.sh - Build a local Docker image with kernel build
#                         dependencies resolved dynamically from a real
#                         kernel source tree's debian/control (via
#                         `debian/rules clean`), instead of a hand-maintained
#                         snapshot file.
#
# Usage:
#   build-docker-image.sh [SOURCE_DIR] [ARCH]
#
# Arguments:
#   SOURCE_DIR  Root of the kernel source tree containing debian/ (default: .)
#   ARCH        Target Debian architecture to compile for: arm64 (default: arm64).
#               Build host may be arm64 (native) or amd64 (cross-compile); amd64
#               is not a supported target since the qcom/qcom-rt flavours are
#               arm64-only.
#
# Output:
#   A local Docker image tagged kernel-build-docker:resolute-target-<ARCH>,
#   where <ARCH> is the compile TARGET architecture, not necessarily the
#   image's own native architecture (matches the build host, per the base
#   image's multi-arch manifest). SKIP_BUILD_DEP=1 is preset so
#   build-kernel-deb.sh skips apt-get build-dep when run inside it. Use via:
#     IMAGE=kernel-build-docker:resolute-target-<ARCH> docker-build-kernel.sh ...
#
# Notes:
#   • debian/control doesn't exist until `debian/rules clean` runs, so this
#     script runs it on the host first and copies only the resulting file
#     into a scratch build context — the kernel source tree itself is not
#     baked into the image.
#   • Modifies SOURCE_DIR/debian/changelog during clean; restored on exit
#     (success or failure).
#   • Base image: docker.io/library/ubuntu:resolute, with
#     public.ecr.aws/ubuntu/ubuntu:resolute as a fallback for when that tag
#     isn't published under the primary registry. Both are genuine
#     multi-arch manifest lists; see Dockerfile.kernel-build.

set -euo pipefail

SOURCE_DIR="${1:-.}"
ARCH="${2:-arm64}"

log()  { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
hr()   { log "$(printf '%0.s─' {1..60})"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/gen-real-control.sh
source "${SCRIPT_DIR}/lib/gen-real-control.sh"

[ -f "${SOURCE_DIR}/debian/rules" ] \
  || die "No debian/rules found in '${SOURCE_DIR}' – is this a kernel source tree?"

SOURCE_DIR="$(cd "${SOURCE_DIR}" && pwd)"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

BUILD_ARCH="$(dpkg --print-architecture)"
CROSS_BUILD=false
if [ "${ARCH}" != "${BUILD_ARCH}" ]; then
  CROSS_BUILD=true
fi

IMAGE_TAG="kernel-build-docker:resolute-target-${ARCH}"

hr
log "Kernel build image (dynamic dependency resolution)"
log "  Source dir : ${SOURCE_DIR}"
log "  Build arch : ${BUILD_ARCH}"
log "  Target arch: ${ARCH}$([ "${CROSS_BUILD}" = true ] && echo ' (cross-compiling)')"
log "  Image tag  : ${IMAGE_TAG}"
hr

CROSS_ENV=""
if [ "${CROSS_BUILD}" = true ]; then
  DEB_HOST_GNU_TYPE="$(dpkg-architecture -a"${ARCH}" -qDEB_HOST_GNU_TYPE)"
  DEB_HOST_MULTIARCH="$(dpkg-architecture -a"${ARCH}" -qDEB_HOST_MULTIARCH)"
  CROSS_ENV="DEB_HOST_ARCH=${ARCH} DEB_HOST_GNU_TYPE=${DEB_HOST_GNU_TYPE} DEB_HOST_MULTIARCH=${DEB_HOST_MULTIARCH}"
fi

DEBIAN_DIR="$(get_debian_dir "${SOURCE_DIR}")"
reset_and_track_changelog "${SOURCE_DIR}" "${DEBIAN_DIR}"
run_debian_rules_clean "${SOURCE_DIR}" "${CROSS_ENV}"

# ---------------------------------------------------------------------------
# Scratch build context: just the generated control file + a small tool
# list, not the whole kernel source tree.
# ---------------------------------------------------------------------------
CONTEXT_DIR="$(mktemp -d)"
add_cleanup "rm -rf \"${CONTEXT_DIR}\""

cp "${SOURCE_DIR}/debian/control" "${CONTEXT_DIR}/control"

if [ "${CROSS_BUILD}" = true ]; then
  patch_native_host_tool_deps "${CONTEXT_DIR}/control"
fi

# Extra tool list: kernel-specific build-host tools not covered by
# Dockerfile.kernel-build's base package set. Cross-compiler toolchain
# packages are not listed here — debian/control already carries the full
# GCC_BUILD_DEPENDS set, so apt-get build-dep resolves the right one per ARCH.
printf '%s\n' bc bison flex > "${CONTEXT_DIR}/extra-tools.txt"

# Prefer the official multi-arch ubuntu:resolute image; fall back to
# public.ecr.aws's mirror for whichever registry hasn't published that tag.
PRIMARY_BASE_IMAGE="docker.io/library/ubuntu:resolute"
FALLBACK_BASE_IMAGE="public.ecr.aws/ubuntu/ubuntu:resolute"
BASE_IMAGE="${PRIMARY_BASE_IMAGE}"
if ! docker manifest inspect "${PRIMARY_BASE_IMAGE}" >/dev/null 2>&1 \
    && ! docker image inspect "${PRIMARY_BASE_IMAGE}" >/dev/null 2>&1; then
  log "${PRIMARY_BASE_IMAGE} not available — falling back to ${FALLBACK_BASE_IMAGE}"
  BASE_IMAGE="${FALLBACK_BASE_IMAGE}"
fi

hr
log "Building Docker image via docker build..."
log "  Base image : ${BASE_IMAGE}"
docker build \
  -f "${SCRIPT_DIR}/Dockerfile.kernel-build" \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "TARGET_ARCH=${ARCH}" \
  --build-arg "CROSS=${CROSS_BUILD}" \
  --build-arg "HTTP_PROXY=${HTTP_PROXY:-}" \
  --build-arg "HTTPS_PROXY=${HTTPS_PROXY:-}" \
  --build-arg "NO_PROXY=${NO_PROXY:-}" \
  -t "${IMAGE_TAG}" \
  "${CONTEXT_DIR}" \
  || die "docker build failed"

hr
log "Build complete."
log "Image: ${IMAGE_TAG}"
log "Use it with docker-build-kernel.sh via: IMAGE=${IMAGE_TAG} docker-build-kernel.sh ..."
