#!/usr/bin/env bash
# Prove that a release tag, the pinned source, and the generated build record
# describe the same release. Run it after scripts/fetch-source.sh (the CI build
# job does this before the expensive build) and before publishing artifacts.
#
#   scripts/check-release-tag.sh v0.2.2-rc.5-alex.1
#
# On success it writes these lines to stdout, which is the GITHUB_OUTPUT format:
#
#   release_tag=v0.2.2-rc.5-alex.1
#   release_build_number=1
#   release_revision=alex.1
#   release_deb_version=0.2.2~rc.5-alex.1

set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_configured_release_identity

tag="${1:-}"
[ -n "$tag" ] || die "usage: scripts/check-release-tag.sh <tag>"
[ $# -eq 1 ] || die "usage: scripts/check-release-tag.sh <tag>"

load_source_env

id="$(release_identity)"
[[ "$tag" =~ ^v(.+)-"$id"\.([0-9]+)$ ]] || die "tag '$tag' is not a release tag of the form v<upstream-version>-$id.<N>"
tag_version="${BASH_REMATCH[1]}"
build_number=$((10#${BASH_REMATCH[2]}))
revision="$id.$build_number"
(( build_number >= 1 )) || die "tag '$tag' has an invalid build number"

[ "$tag_version" = "$DSH_VERSION" ] \
  || die "tag '$tag' advertises upstream version '$tag_version', but the pinned source is '$DSH_VERSION' ($DSH_REF)"

# Read the tracked default rather than the effective one: CI exports
# DEB_REVISION, and the release commit must record the same value as the tag.
conf_revision="$(env -u DEB_REVISION -u DSH_REF bash -c '. "$1/release.conf"; printf "%s" "$DEB_REVISION"' _ "$ROOT")"
[ "$conf_revision" = "$revision" ] \
  || die "tag '$tag' expects release.conf DEB_REVISION=$revision, but the tracked file records '$conf_revision'; the tag was not cut by scripts/release.sh"

[ "${DSH_RELEASE_TAG:-}" = "$tag" ] \
  || die "build/source.env was generated for release '${DSH_RELEASE_TAG:-<none>}', not '$tag'"
[ "${DEB_REVISION:-}" = "$revision" ] \
  || die "build/source.env was generated with DEB_REVISION='${DEB_REVISION:-}', not '$revision'"

expected_deb="${DEB_UPSTREAM_VERSION}-${revision}"
[ "$DEB_FULL_VERSION" = "$expected_deb" ] \
  || die "build/source.env has deb version '$DEB_FULL_VERSION', expected '$expected_deb'"

# The tag must be the commit being built: a release tag that points elsewhere
# would advertise a package this build cannot reproduce. In CI, actions/checkout
# normally creates the local tag ref; GITHUB_SHA is the fallback for runtimes
# that only expose the commit.
if git -C "$ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  tag_commit="$(git -C "$ROOT" rev-parse "$tag^{commit}")"
elif [ -n "${GITHUB_SHA:-}" ]; then
  tag_commit="$(git -C "$ROOT" rev-parse "${GITHUB_SHA}^{commit}" 2>/dev/null || git -C "$ROOT" rev-parse "$GITHUB_SHA")"
  step "tag ref $tag is not local; using GITHUB_SHA ${GITHUB_SHA:0:12}"
else
  die "tag '$tag' is not present in this checkout; fetch tags or check out the tag"
fi
head_commit="$(git -C "$ROOT" rev-parse HEAD)"
[ "$tag_commit" = "$head_commit" ] \
  || die "tag '$tag' points at ${tag_commit:0:12}, but HEAD is ${head_commit:0:12}"

step "tag $tag -> upstream $DSH_REF ($DSH_COMMIT), deb $expected_deb"

printf 'release_tag=%s\n' "$tag"
printf 'release_build_number=%s\n' "$build_number"
printf 'release_revision=%s\n' "$revision"
printf 'release_deb_version=%s\n' "$expected_deb"
