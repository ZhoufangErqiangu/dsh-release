#!/usr/bin/env bash
# Fetch, verify, and unpack the pnpm release the package bundles.
#
# `dsh plugin` and the Web Plugins page invoke `pnpm`. Ubuntu 24.04 has no pnpm
# package, and corepack resolves a moving "latest" instead of the version the
# upstream repository pins, so the package ships exactly one pnpm. The tarball
# is pinned in release.conf and checked by sha256 before use; the unpacked tree
# is cached in .work/pnpm so repeated stage runs do not hit the network.

set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${PNPM_VERSION:?PNPM_VERSION is empty}"
: "${PNPM_TARBALL_SHA256:?PNPM_TARBALL_SHA256 is empty}"
: "${PNPM_BASE_URL:?PNPM_BASE_URL is empty}"

require_cmd curl "curl is required to fetch pnpm"
require_cmd sha256sum "sha256sum is required to verify pnpm"
require_cmd tar "tar is required to unpack pnpm"

check_node_version >/dev/null
NODE="$(node_bin)"

cache="$WORK/pnpm"
tarball="$cache/pnpm-$PNPM_VERSION.tgz"
package="$cache/package"

mkdir -p "$cache"

# verify_checksum FILE succeeds only for the pinned digest.
verify_checksum() {
  printf '%s  %s\n' "$PNPM_TARBALL_SHA256" "$1" | sha256sum -c - >/dev/null 2>&1
}

if [ ! -f "$tarball" ]; then
  log "fetching pnpm $PNPM_VERSION from $PNPM_BASE_URL"
  partial="$tarball.part"
  rm -f "$partial"
  curl -fsSL --retry 3 --connect-timeout 20 --max-time 300 \
    -o "$partial" "$PNPM_BASE_URL/pnpm-$PNPM_VERSION.tgz" \
    || die "could not download pnpm $PNPM_VERSION; set PNPM_BASE_URL to a reachable mirror"
  mv "$partial" "$tarball"
fi

verify_checksum "$tarball" \
  || die "pnpm $PNPM_VERSION checksum mismatch for $tarball; delete it and retry"

if [ -f "$package/package.json" ] && "$NODE" -e '
  process.exit(require(process.argv[1]).version === process.argv[2] ? 0 : 1)
' "$package/package.json" "$PNPM_VERSION" 2>/dev/null; then
  step "reusing unpacked pnpm $PNPM_VERSION"
else
  log "unpacking pnpm $PNPM_VERSION"
  rm -rf "$package"
  mkdir -p "$package"
  tar -xzf "$tarball" -C "$package" --strip-components=1
  [ -f "$package/bin/pnpm.mjs" ] || die "pnpm tarball does not contain bin/pnpm.mjs"
  [ -f "$package/LICENSE" ] || die "pnpm tarball does not contain LICENSE"
fi

log "${C_GREEN}pnpm ready${C_RESET}: $PNPM_VERSION ($(du -sh "$package" | cut -f1))"
