#!/usr/bin/env bash
# Build the .deb from the staged root filesystem and record its digest.

set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_source_env

rootfs="$BUILD/rootfs"
[ -f "$rootfs/DEBIAN/control" ] || die "rootfs is not staged; run scripts/stage-rootfs.sh first"

mkdir -p "$DIST"
deb="${DEB_PACKAGE}_${DEB_FULL_VERSION}_${DEB_ARCH}.deb"
rm -f "$DIST/$deb" "$DIST/$deb.sha256"

log "building $deb"
SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" dpkg-deb \
  --build --root-owner-group \
  -Zxz -z6 \
  "$rootfs" "$DIST/$deb"

printf '%s\n' "$deb" > "$DIST/latest.txt"
( cd "$DIST" && sha256sum "$deb" > "$deb.sha256" )

# Release builds also get a machine-readable manifest next to the package, so a
# GitHub Release, a mirror, or a deployment job can read the release tag, the
# upstream pin, and the digest from one file.
"$ROOT/scripts/release-manifest.sh"

log "${C_GREEN}package ready${C_RESET}: $DIST/$deb ($(du -h "$DIST/$deb" | cut -f1))"
dpkg-deb --info "$DIST/$deb" >&2
