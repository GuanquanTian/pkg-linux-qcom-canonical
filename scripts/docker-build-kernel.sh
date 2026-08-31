#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# docker-build-kernel.sh - Build Ubuntu kernel .deb packages inside a Docker container
#
# This script wraps build-kernel-deb.sh and runs it inside a Docker container.
# It automatically detects the current architecture and, if the appropriate
# Docker image isn't already available locally, builds one via
# build-docker-image.sh (using SOURCE_DIR's own debian/control).
#
# Arguments: positional args override env vars, which override defaults.
# SOURCE_DIR is resolved relative to the current working directory.
#
# Usage:
#   docker-build-kernel.sh [SOURCE_DIR] [ARCH] [FLAVOR] [JOBS] [VERSION_SUFFIX]
#
# Arguments:
#   SOURCE_DIR      Root of the kernel source tree (relative to current directory, default: resolute-qcom-devel)
#   ARCH            Target Debian architecture: arm64 (default: arm64)
#   FLAVOR          Kernel flavour: qcom | qcom-rt | all (default: qcom)
#   JOBS            Parallel make jobs (default: 8)
#   VERSION_SUFFIX  Optional version suffix (default: none)
#
# Environment:
#   IMAGE           Docker image to use (default: kernel-build-docker:resolute-target-<ARCH>,
#                    built on demand via build-docker-image.sh if not already
#                    present locally). Set this to use a different image
#                    instead — it must already exist locally, since this
#                    script no longer pulls from a registry.
#   OUTPUT_DIR      Where to place built .deb packages (default: ./output
#                    relative to the current directory). Set this to a fixed
#                    absolute path if you don't want the output location to
#                    depend on which directory you invoke this script from.
#                    Created on the host (with your uid/gid) before the
#                    container starts, so it's never auto-created by Docker
#                    as root.
#   DEBEMAIL        Email for changelog entries (default: build-kernel-deb@localhost)
#   DEBFULLNAME     Full name for changelog entries (default: build-kernel-deb.sh)
#   INCREMENTAL_BUILD  Set to 0/false/no/off to force a full debian/rules
#                    clean even when prior build state exists (default: 1,
#                    incremental). See build-kernel-deb.sh for details and
#                    caveats.
#   DBGSYM          Set to 1/true/yes/on to also build the unstripped
#                    -dbgsym.ddeb debug symbol packages alongside the .deb
#                    packages (default: 0, disabled). See build-kernel-deb.sh
#                    for details.
#
# Output:
#   Built .deb packages are placed in OUTPUT_DIR (default: ./output relative
#   to the current directory).

set -euo pipefail

# Logging helpers
log()  { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
hr()   { log "$(printf '%0.s─' {1..60})"; }

is_truthy() {
  case "${1:-}" in
    1|[tT][rR][uU][eE]|[yY][eE][sS]|[oO][nN]) return 0 ;;
    *) return 1 ;;
  esac
}

# Resolve the script's absolute directory
SCRIPT_ABS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get current working directory
CURRENT_DIR="$(pwd)"

# Parse arguments and environment variables
# Priority: positional arguments > environment variables > defaults
SOURCE_DIR="${1:-${SOURCE_DIR:-resolute-qcom-devel}}"
ARCH="${2:-${ARCH:-arm64}}"
FLAVOR="${3:-${FLAVOR:-qcom}}"
JOBS="${4:-${JOBS:-8}}"
VERSION_SUFFIX="${5:-${VERSION_SUFFIX:-}}"

# Convert SOURCE_DIR (relative to current directory) to an absolute path
SOURCE_DIR_ABS="$(cd "${CURRENT_DIR}" && cd "${SOURCE_DIR}" 2>/dev/null && pwd)" || die "SOURCE_DIR '${SOURCE_DIR}' not found (relative to current directory: ${CURRENT_DIR})"

# OUTPUT_DIR defaults to ./output relative to CURRENT_DIR; may be relative
# or absolute. Created here on the host so Docker doesn't auto-create it
# (and any missing parents) as root via the -v flag below.
OUTPUT_DIR="${OUTPUT_DIR:-${CURRENT_DIR}/output}"
mkdir -p "${OUTPUT_DIR}" || die "Failed to create OUTPUT_DIR '${OUTPUT_DIR}'"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"

# Detect current system architecture
CURRENT_ARCH="$(uname -m)"
case "$CURRENT_ARCH" in
  aarch64) CURRENT_ARCH="arm64" ;;
  x86_64)  CURRENT_ARCH="amd64" ;;
esac

# Default to the local image build-docker-image.sh produces for this ARCH.
IMAGE="${IMAGE:-kernel-build-docker:resolute-target-${ARCH}}"

hr
log "Docker kernel build"
log "  Source dir      : ${SOURCE_DIR} (resolved to: ${SOURCE_DIR_ABS})"
log "  Target arch     : ${ARCH}"
log "  Current arch    : ${CURRENT_ARCH}"
log "  Flavour         : ${FLAVOR}"
log "  Jobs            : ${JOBS}"
log "  Docker image    : ${IMAGE}"
log "  Output dir      : ${OUTPUT_DIR}"
if is_truthy "${INCREMENTAL_BUILD:-1}"; then
  log "  Incremental     : enabled"
else
  log "  Incremental     : disabled"
fi
log "  Dbgsym          : $(is_truthy "${DBGSYM:-0}" && echo enabled || echo disabled)"
hr

# Build the local image on demand if not already present (no registry pull —
# see build-docker-image.sh).
log "Checking if Docker image exists locally..."
if docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  log "✓ Docker image found locally: ${IMAGE}"
else
  log "✗ Docker image not found locally: ${IMAGE}"
  log "Building it via build-docker-image.sh..."
  "${SCRIPT_ABS}/build-docker-image.sh" "${SOURCE_DIR_ABS}" "${ARCH}" \
    || die "Failed to build local Docker image ${IMAGE}"
fi

hr

# Bind mounts: CURRENT_DIR, OUTPUT_DIR, SOURCE_DIR's parent (debian/rules
# writes .deb/.changes/.buildinfo to "..", next to SOURCE_DIR), and
# SCRIPT_ABS (read-only) — not the whole workspace. Duplicate/nested mounts
# are skipped to avoid overlapping -v flags.
SOURCE_DIR_PARENT="$(dirname "${SOURCE_DIR_ABS}")"
# write_dirs need -v (rw); SCRIPT_ABS defaults to :ro unless its path
# coincides with (or is a parent of) a write_dir.
write_dirs=("${CURRENT_DIR}" "${OUTPUT_DIR}" "${SOURCE_DIR_PARENT}")
mount_dirs=("${write_dirs[@]}" "${SCRIPT_ABS}")
docker_mounts=()
docker_mount_flags=()
for d in "${mount_dirs[@]}"; do
  covered=false
  for m in "${docker_mounts[@]}"; do
    [ "${d}" = "${m}" ] && covered=true && break
    case "${d}" in "${m}"/*) covered=true; break ;; esac
  done
  ${covered} && continue
  docker_mounts+=("${d}")
  needs_write=false
  for w in "${write_dirs[@]}"; do
    [ "${d}" = "${w}" ] && needs_write=true && break
  done
  if ${needs_write}; then
    docker_mount_flags+=(-v "${d}:${d}")
  else
    docker_mount_flags+=(-v "${d}:${d}:ro")
  fi
done

docker_flags=(--rm "${docker_mount_flags[@]}")
[ -t 0 ] && [ -t 1 ] && docker_flags+=(-it)

log "Bind mounts:"
for f in "${docker_mount_flags[@]}"; do
  [ "${f}" = "-v" ] && continue
  log "  ${f}"
done
hr

# Runs as the invoking host uid/gid so build output keeps host ownership.
exec docker run "${docker_flags[@]}" \
  -u "$(id -u):$(id -g)" \
  -w "${CURRENT_DIR}" \
  -e OUTPUT_DIR="${OUTPUT_DIR}" \
  -e DEBEMAIL="${DEBEMAIL:-}" \
  -e DEBFULLNAME="${DEBFULLNAME:-}" \
  -e INCREMENTAL_BUILD="${INCREMENTAL_BUILD:-1}" \
  -e DBGSYM="${DBGSYM:-0}" \
  "${IMAGE}" \
  bash "${SCRIPT_ABS}/build-kernel-deb.sh" "${SOURCE_DIR_ABS}" "${ARCH}" "${FLAVOR}" "${JOBS}" "${VERSION_SUFFIX}"
