#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# gen-real-control.sh - Shared helpers for producing a kernel source tree's
#                        real, version-accurate debian/control (as generated
#                        by `debian/rules clean`) and for patching it for
#                        cross-builds.
#
# Sourced by build-kernel-deb.sh and build-docker-image.sh. The sourcing
# script must define log() and die() before sourcing, and must set a SUDO
# variable (empty string when already running as root) before calling
# run_debian_rules_clean() — checked there, since both callers set SUDO
# after sourcing this file.

declare -f log >/dev/null 2>&1 || { echo "gen-real-control.sh: log() must be defined before sourcing this file" >&2; exit 1; }
declare -f die >/dev/null 2>&1 || { echo "gen-real-control.sh: die() must be defined before sourcing this file" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Cleanup-action stack: several steps below need to undo a temporary edit on
# exit (success or failure). A single `trap ... EXIT` would be silently
# clobbered by the next one that registers it, so instead each step pushes a
# command string here and one trap runs them all, in reverse (LIFO) order.
# ---------------------------------------------------------------------------
CLEANUP_CMDS=()
add_cleanup() { CLEANUP_CMDS+=("$1"); }
run_cleanup() {
  local i
  for (( i=${#CLEANUP_CMDS[@]}-1; i>=0; i-- )); do
    eval "${CLEANUP_CMDS[$i]}"
  done
}
trap run_cleanup EXIT

is_git_worktree() {
  local dir="$1" out real
  out="$(git -C "${dir}" rev-parse --is-inside-work-tree 2>&1)" && return 0
  if printf '%s' "${out}" | grep -q 'detected dubious ownership'; then
    real="$(realpath "${dir}" 2>/dev/null)" || return 1
    git config --global --get-all safe.directory 2>/dev/null | grep -qxF "${real}" \
      || git config --global --add safe.directory "${real}" 2>/dev/null || true
    git -C "${dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1 && return 0
  fi
  return 1
}

get_debian_dir() {
  awk -F= '($1 == "DEBIAN") { print $2 }' "$1/debian/debian.env"
}

# Resets any leftover modified debian/<flavour>/changelog from a previous
# interrupted run, and registers a cleanup to restore it again on exit.
# No-op when SOURCE_DIR is not a git work tree (there's nothing to check out
# back to).
reset_and_track_changelog() {
  local source_dir="$1" debian_dir="$2"
  if is_git_worktree "${source_dir}"; then
    git -C "${source_dir}" checkout -- "${debian_dir}/changelog" 2>/dev/null || true
    add_cleanup "git -C \"${source_dir}\" checkout -- \"${debian_dir}/changelog\" 2>/dev/null || true"
  fi
}

# Ensures fakeroot/debhelper are present, then runs `debian/rules clean` in
# SOURCE_DIR to (re)generate debian/control and debian/changelog. Resulting
# control file is always at SOURCE_DIR/debian/control.
run_debian_rules_clean() {
  local source_dir="$1" cross_env="${2:-}" tool_pkg pkg bin

  [ -v SUDO ] || die "run_debian_rules_clean: SUDO must be set (possibly empty) by the caller before this is called"

  # `debian/rules clean` needs fakeroot and debhelper (dh_testdir/dh_clean)
  # to run at all — independent of SKIP_BUILD_DEP, since clean must succeed
  # before debian/control exists for apt-get build-dep to read. Only
  # installs what's missing; no-op on images that already have them.
  for tool_pkg in fakeroot:fakeroot debhelper:dh_testdir; do
    pkg="${tool_pkg%%:*}"; bin="${tool_pkg##*:}"
    if ! command -v "${bin}" >/dev/null 2>&1; then
      if [ -n "${SUDO}" ] && ! command -v sudo >/dev/null 2>&1; then
        die "${pkg} is missing and this isn't running as root with no sudo binary available to install it. Install ${pkg} into the image ahead of time, or run as root."
      fi
      log "Installing ${pkg} (required to run debian/rules clean)..."
      ${SUDO} apt-get update -qq
      ${SUDO} apt-get install -y "${pkg}" || die "Failed to install ${pkg}"
    fi
  done

  log "Running debian/rules clean in ${source_dir} (generates debian/control and debian/changelog)..."
  ( cd "${source_dir}" && env ${cross_env} fakeroot debian/rules clean ) \
    || die "Failed to run debian/rules clean in ${source_dir}"

  [ -f "${source_dir}/debian/control" ] \
    || die "debian/rules clean did not produce ${source_dir}/debian/control"
}

# Incremental-mode counterpart to run_debian_rules_clean(): refreshes
# debian/control and debian/changelog (still required by apt-get build-dep
# and the version-parsing steps later in build-kernel-deb.sh) WITHOUT
# wiping debian/build/ or debian/stamps/, so kbuild's and the stamp
# machinery's own incremental state survives across runs.
refresh_control_incremental() {
  local source_dir="$1" debian_dir="$2" cross_env="${3:-}"

  log "INCREMENTAL_BUILD set and previous build state found under ${source_dir}/debian/build — skipping 'debian/rules clean' to preserve it."

  ( cd "${source_dir}" && cp "${debian_dir}/changelog" debian/changelog ) \
    || die "Failed to sync ${debian_dir}/changelog to debian/changelog"

  ( cd "${source_dir}" && env ${cross_env} fakeroot debian/rules debian/control ) \
    || die "Failed to refresh debian/control"

  [ -f "${source_dir}/debian/control" ] \
    || die "debian/rules debian/control did not produce ${source_dir}/debian/control"
}

# Removes the prepare/build/install stamps for FLAVOR (or both qcom and
# qcom-rt when FLAVOR=all, mirroring build-kernel-deb.sh's own FLAVOR
# contract) so `make` re-enters those recipes on the next build instead of
# treating them as already satisfied. debian/build/build-<flavour>/ itself
# is left untouched — kbuild's own .cmd-based dependency tracking (not
# make's stamp mtimes) decides which files actually need recompiling.
invalidate_flavour_stamps() {
  local stampdir="$1" flavor="$2" f flavors
  flavors="${flavor}"
  [ "${flavor}" = "all" ] && flavors="qcom qcom-rt"
  for f in ${flavors}; do
    rm -f "${stampdir}/stamp-prepare-${f}" "${stampdir}/stamp-build-${f}" "${stampdir}/stamp-install-${f}"
  done
}

# Packages debian/control lists without a `:native` qualifier but that the
# kernel's own build rules invoke directly as build-host tools (e.g.
# llvm-config-<N> in debian/rules.d/2-binary-arch.mk) rather than linking
# into the target-arch binaries. Under cross-compilation, `apt-get
# build-dep --host-architecture` installs only the target-arch copy, which
# isn't executable on the build host — these need an explicit native
# (build-arch) install alongside. Keyed by the same package-name/version
# pattern the consuming rules file greps from debian/control.
declare -A NATIVE_HOST_TOOL_DEPS=(
  [llvm]='llvm-[0-9]+-dev'
)

# For each pattern in NATIVE_HOST_TOOL_DEPS matching an *unannotated*
# Build-Depends line in CONTROL_PATH, mark it `:native` so a cross `apt-get
# build-dep --host-architecture` installs the build-host copy instead of a
# non-executable target-arch one. A backup is kept and restored on exit.
patch_native_host_tool_deps() {
  local control="$1" key pattern pkg backup
  for key in "${!NATIVE_HOST_TOOL_DEPS[@]}"; do
    pattern="${NATIVE_HOST_TOOL_DEPS[$key]}"
    pkg="$(grep -oE "${pattern}" "${control}" | head -1)"
    [ -n "${pkg}" ] || continue                        # not in this control file at all
    grep -q "^ ${pkg},\$" "${control}" || continue      # already annotated/restricted — leave as-is

    log "debian/control: ${pkg} is unannotated but is consumed as a build-host tool by the kernel's own rules.d — marking it :native for this cross build..."
    backup="${control}.orig-precross"
    cp "${control}" "${backup}"
    add_cleanup "mv \"${backup}\" \"${control}\" 2>/dev/null || true"
    sed -i "s/^ ${pkg},\$/ ${pkg}:native,/" "${control}"
  done
}
