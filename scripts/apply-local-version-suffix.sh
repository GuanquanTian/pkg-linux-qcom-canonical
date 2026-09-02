#!/usr/bin/env bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Appends a local Debian version suffix (+qcom<N>.<sha>) to the topmost
# debian/changelog entry for resolute-qcom-devel builds that carry commits
# past the last Canonical sync tag, so the package version differs from a
# plain rebuild of that tag. N is the commit count past the tag and sorts
# numerically, so later builds always compare as newer. Skipped for
# resolute-qcom mirror builds and kernel_version-pinned builds, which must
# stay byte-identical to Canonical. Nothing here is ever committed to git.
#
# Uses the GitHub Compare API to find the nearest Ubuntu-qcom-* tag rather
# than local git tags: the checkout is shallow, deepening history alone
# doesn't fetch tags, and this repo's full tag namespace is too large to
# fetch blindly on every build.
#
# Never fails the build itself. Writes a full replacement changelog to a
# temp file and swaps it in with mv at the end, so a failure partway
# through never leaves debian/changelog partially written; the calling
# workflow step also downgrades any non-zero exit to a warning.
set -euo pipefail

: "${SUITE:?SUITE is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
KERNEL_VERSION="${KERNEL_VERSION:-}"

emit_kernel_version() {
  echo "KERNEL_LOCAL_VERSION=$1" >> "$GITHUB_ENV"
}

if [[ "$SUITE" != "resolute-qcom-devel" || -n "$KERNEL_VERSION" ]]; then
  echo "Not a resolute-qcom-devel development build (suite=${SUITE}, kernel_version=${KERNEL_VERSION:-<empty>}); no local version suffix needed."
  emit_kernel_version "unmodified"
  exit 0
fi

cd kernel-src/

DEBIAN_DIR="$(awk -F= '($1 == "DEBIAN") { print $2 }' debian/debian.env 2>/dev/null || true)"
if [[ -z "$DEBIAN_DIR" ]]; then
  echo "::warning::Could not resolve DEBIAN directory from debian/debian.env; skipping local version suffix."
  emit_kernel_version "unmodified"
  exit 0
fi

CHANGELOG="${DEBIAN_DIR}/changelog"
if [[ ! -f "$CHANGELOG" ]]; then
  echo "::warning::${CHANGELOG} not found; skipping local version suffix."
  emit_kernel_version "unmodified"
  exit 0
fi

HEAD_SHA="$(git rev-parse HEAD)"
SHORT_SHA="$(git rev-parse --short=12 HEAD)"

if [[ ! "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || [[ ! "$SHORT_SHA" =~ ^[0-9a-f]{12}$ ]]; then
  echo "::warning::Unexpected HEAD SHA format; skipping local version suffix."
  emit_kernel_version "unmodified"
  exit 0
fi

if ! TAGS_RAW="$(
  gh api --paginate "repos/${GITHUB_REPOSITORY}/tags" \
    -X GET -f per_page=100 \
    --jq '[.[] | select(.name | test("^Ubuntu-qcom-[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+\\.[0-9]+$")) | .name]' \
    2>&1
)"; then
  echo "::warning::Unable to list Ubuntu-qcom-* tags; skipping local version suffix. ${TAGS_RAW}"
  emit_kernel_version "unmodified"
  exit 0
fi

TAGS_JSON="$(jq -s 'add // []' <<< "$TAGS_RAW")"
if [[ "$(jq 'length' <<< "$TAGS_JSON")" == "0" ]]; then
  echo "::warning::No Ubuntu-qcom-* tags returned; skipping local version suffix."
  emit_kernel_version "unmodified"
  exit 0
fi

# Find the tag with the smallest ahead_by among all tags that are actual
# ancestors of HEAD (status "identical" or "ahead"). That is the nearest
# sync point, independent of whatever order the API happens to list tags in.
BEST_AHEAD=""
BEST_TAG=""
LAST_COMPARE_ERROR=""
for tag in $(jq -r '.[]' <<< "$TAGS_JSON"); do
  if ! cmp="$(gh api "repos/${GITHUB_REPOSITORY}/compare/${tag}...${HEAD_SHA}" \
          --jq '{status, ahead_by} | @json' 2>&1)"; then
    LAST_COMPARE_ERROR="$cmp"
    continue
  fi
  status="$(jq -r '.status' <<< "$cmp")"
  ahead="$(jq -r '.ahead_by' <<< "$cmp")"
  [[ "$status" == "identical" || "$status" == "ahead" ]] || continue
  [[ "$ahead" =~ ^[0-9]+$ ]] || continue
  if [[ -z "$BEST_AHEAD" || "$ahead" -lt "$BEST_AHEAD" ]]; then
    BEST_AHEAD="$ahead"
    BEST_TAG="$tag"
  fi
done

if [[ -z "$BEST_AHEAD" ]]; then
  echo "::warning::No Ubuntu-qcom-* tag found as an ancestor of ${HEAD_SHA}; skipping local version suffix. ${LAST_COMPARE_ERROR}"
  emit_kernel_version "unmodified"
  exit 0
fi

if [[ "$BEST_AHEAD" == "0" ]]; then
  echo "HEAD is exactly ${BEST_TAG}; pure Canonical content, no local version suffix needed."
  emit_kernel_version "unmodified"
  exit 0
fi

PACKAGE="$(dpkg-parsechangelog -l "$CHANGELOG" -SSource)"
BASE_VERSION="$(dpkg-parsechangelog -l "$CHANGELOG" -SVersion)"
DISTRIBUTION="$(dpkg-parsechangelog -l "$CHANGELOG" -SDistribution)"
NEW_VERSION="${BASE_VERSION}+qcom${BEST_AHEAD}.${SHORT_SHA}"

TMP_CHANGELOG="$(mktemp)"
{
  printf '%s (%s) %s; urgency=medium\n\n' "$PACKAGE" "$NEW_VERSION" "$DISTRIBUTION"
  printf '  * Qualcomm downstream build: %s commit(s) past %s.\n\n' "$BEST_AHEAD" "$BEST_TAG"
  printf ' -- Qualcomm Linux CI <noreply@qualcomm.com>  %s\n\n' "$(LC_ALL=C date -R)"
  cat "$CHANGELOG"
} > "$TMP_CHANGELOG"

# The rewritten file must parse cleanly before it ever replaces the real
# changelog; a malformed entry must never reach the actual build.
dpkg-parsechangelog -l "$TMP_CHANGELOG" -SVersion >/dev/null

mv "$TMP_CHANGELOG" "$CHANGELOG"

echo "Applied local version suffix: ${BASE_VERSION} -> ${NEW_VERSION} (${BEST_AHEAD} commit(s) past ${BEST_TAG})"
emit_kernel_version "$NEW_VERSION"
