#!/usr/bin/env bash
# Write dist/release.json: the machine-readable identity of the package built
# by the previous stages. scripts/release.sh and the tag-triggered CI workflow
# both read it back to prove that the tag, the source pin, and the .deb agree.

set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_source_env

NODE="$(node_bin)"
[ -n "$NODE" ] || die "Node.js is required to write the release manifest"

name="$(cat "$DIST/latest.txt" 2>/dev/null || true)"
[ -n "$name" ] || die "no package recorded in $DIST/latest.txt; run scripts/package.sh first"
[ -f "$DIST/$name" ] || die "package missing: $DIST/$name"
[ -f "$DIST/$name.sha256" ] || die "digest missing: $DIST/$name.sha256"

sha256="$(cut -d' ' -f1 "$DIST/$name.sha256")"
build_number="$(release_build_number "$DEB_REVISION" || true)"

export DEB_PACKAGE DEB_FULL_VERSION DEB_ARCH DSH_VERSION DSH_REF DSH_COMMIT
export DEB_REVISION DSH_RELEASE_TAG BUILD_NUMBER="$build_number"
export RELEASE_FILE="$name" RELEASE_SHA256="$sha256"

"$NODE" - "$DIST/release.json" <<'EOF'
const { writeFileSync } = require('node:fs')
const e = process.env
const tag = e.DSH_RELEASE_TAG || null
const release = {
  schemaVersion: 1,
  releaseTag: tag,
  releaseVersion: tag ? tag.slice(1) : null,
  buildNumber: e.BUILD_NUMBER ? Number(e.BUILD_NUMBER) : null,
  revision: e.DEB_REVISION,
  debVersion: e.DEB_FULL_VERSION,
  package: e.DEB_PACKAGE,
  architecture: e.DEB_ARCH,
  file: e.RELEASE_FILE,
  sha256: e.RELEASE_SHA256,
  source: {
    ref: e.DSH_REF,
    commit: e.DSH_COMMIT,
    version: e.DSH_VERSION,
  },
}
writeFileSync(process.argv[2], JSON.stringify(release, null, 2) + '\n')
EOF

step "release manifest: $DIST/release.json (release ${DSH_RELEASE_TAG:-<none>})"
