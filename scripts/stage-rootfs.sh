#!/usr/bin/env bash
# Assemble the Debian root filesystem from the built source and the staged
# production installation. No packaging step runs as root: ownership is fixed
# by dpkg-deb --root-owner-group at package time.

set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_source_env
check_node_version
NODE="$(node_bin)"
PNPM="$(pnpm_bin)"
[ -n "$PNPM" ] || die "pnpm not found; needed to pack the runtime closure"

[ -f "$SRC/apps/cli/lib/bin.js" ] || die "source is not built; run scripts/build-source.sh first"
[ -f "$SRC/.dsh-build/client-build-environment.json" ] || die "missing client build record; rebuild artifacts"

rootfs="$BUILD/rootfs"
rm -rf "$rootfs" "$BUILD/app" "$BUILD/runtime-archives"
mkdir -p "$rootfs"

log "staging the production runtime closure"
SRC_DIR="$SRC" \
OUT_DIR="$BUILD/app" \
ARCHIVES_DIR="$BUILD/runtime-archives" \
PNPM_BIN="$PNPM" \
STORE_DIR="$PNPM_STORE" \
DSH_VERSION="$DSH_VERSION" \
  "$NODE" "$ROOT/scripts/stage-runtime.mjs"

app="$rootfs/usr/lib/dsh/app"
install -d "$app"
cp -a "$BUILD/app/." "$app/"
# pnpm bookkeeping points at build-host tarballs and a store path that do not
# exist on the target; nothing at runtime reads these files. The patch files
# were consumed during the staging install and the root manifest only repeats
# the staging file: specs.
rm -f "$app/pnpm-lock.yaml" "$app/pnpm-workspace.yaml" "$app/node_modules/.modules.yaml" \
  "$app/node_modules/.pnpm-workspace-state-v1.json" "$app/package.json"
rm -rf "$app/patches"

# Some upstream bundles embed the build checkout's absolute path in generated
# comments and source-map URLs. Replace it with a stable path so the payload
# does not leak the builder's home directory and only depends on source content.
if grep -rIl -e "$SRC" "$app" > "$BUILD/build-path-files.txt" 2>/dev/null; then
  step "sanitizing the build path in $(wc -l < "$BUILD/build-path-files.txt") text artifacts"
  xargs -0 -r sed -i "s|$SRC|/usr/src/deepseek-harness|g" < <(tr '\n' '\0' < "$BUILD/build-path-files.txt")
fi

install -d "$rootfs/usr/bin" "$rootfs/usr/lib/systemd/user" \
  "$rootfs/usr/share/man/man1" "$rootfs/usr/share/doc/$DEB_PACKAGE"
install -m 0755 "$ROOT/packaging/dsh" "$rootfs/usr/bin/dsh"
install -m 0755 "$ROOT/packaging/dsh-web-url" "$rootfs/usr/bin/dsh-web-url"
install -m 0644 "$ROOT/packaging/dsh-web.service" "$rootfs/usr/lib/systemd/user/dsh-web.service"
install -m 0644 "$ROOT/packaging/dsh.1" "$rootfs/usr/share/man/man1/dsh.1"
gzip -9n "$rootfs/usr/share/man/man1/dsh.1"

# Ship one pinned pnpm: `dsh plugin` and the Web Plugins page spawn `pnpm`, and
# Ubuntu 24.04 has no package for it. The launcher and the user unit put
# /usr/lib/dsh/bin first on PATH.
log "staging the bundled pnpm"
"$ROOT/scripts/prepare-pnpm.sh"
install -d "$rootfs/usr/lib/dsh/bin" "$rootfs/usr/lib/dsh/pnpm"
cp -a "$WORK/pnpm/package/." "$rootfs/usr/lib/dsh/pnpm/"
install -m 0755 "$ROOT/packaging/pnpm" "$rootfs/usr/lib/dsh/bin/pnpm"

docroot="$rootfs/usr/share/doc/$DEB_PACKAGE"
install -m 0644 "$ROOT/packaging/copyright" "$docroot/copyright"
install -m 0644 "$ROOT/packaging/README.Debian" "$docroot/README.Debian"
gzip -9n "$docroot/README.Debian"
install -m 0644 "$SRC/THIRD_PARTY_NOTICES.md" "$docroot/THIRD_PARTY_NOTICES.md"
printf '%s\n' "$DSH_COMMIT" > "$docroot/source-commit"

export DEB_PACKAGE DEB_FULL_VERSION DEB_ARCH DSH_REPO_URL DSH_REF DSH_COMMIT DSH_VERSION SOURCE_DATE_EPOCH PNPM_VERSION
export DSH_RELEASE_TAG DEB_REVISION
"$NODE" - "$docroot/BUILD-INFO.json" <<'EOF'
const { writeFileSync } = require('node:fs')
const out = process.argv[2]
const info = {
  package: process.env.DEB_PACKAGE,
  version: process.env.DEB_FULL_VERSION,
  release: process.env.DSH_RELEASE_TAG || null,
  architecture: process.env.DEB_ARCH,
  source: {
    repository: process.env.DSH_REPO_URL,
    ref: process.env.DSH_REF,
    commit: process.env.DSH_COMMIT,
    version: process.env.DSH_VERSION,
  },
  build: {
    revision: process.env.DEB_REVISION,
    sourceDateEpoch: Number(process.env.SOURCE_DATE_EPOCH),
    builtAt: new Date(Number(process.env.SOURCE_DATE_EPOCH) * 1000).toISOString(),
    node: process.version,
    platform: `${process.platform}/${process.arch}`,
  },
  bundled: {
    pnpm: process.env.PNPM_VERSION,
  },
  service: {
    kind: 'systemd-user',
    unit: '/usr/lib/systemd/user/dsh-web.service',
    url: 'http://127.0.0.1:3080',
  },
}
writeFileSync(out, JSON.stringify(info, null, 2) + '\n')
EOF

{
  printf '%s (%s) unstable; urgency=medium\n\n' "$DEB_PACKAGE" "$DEB_FULL_VERSION"
  printf '  * Package upstream %s (%s), built from source.\n' "$DSH_REF" "$DSH_COMMIT"
  printf '  * Install dsh-web as a systemd user service; no root system service\n'
  printf '    is installed or enabled by the package.\n'
  printf '  * Bundle pnpm %s so plugin management needs no separate install.\n\n' "$PNPM_VERSION"
  printf ' -- %s  %s\n' "$DEB_MAINTAINER" "$(LC_ALL=C date -R -u -d "@$SOURCE_DATE_EPOCH")"
} > "$docroot/changelog.Debian"
gzip -9n "$docroot/changelog.Debian"

# Control area (excluded from the data tarball by dpkg-deb).
install -d "$rootfs/DEBIAN"
installed_size="$(du -sk --exclude=DEBIAN "$rootfs" | cut -f1)"
sed \
  -e "s|@PACKAGE@|$DEB_PACKAGE|g" \
  -e "s|@VERSION@|$DEB_FULL_VERSION|g" \
  -e "s|@ARCH@|$DEB_ARCH|g" \
  -e "s|@MAINTAINER@|$DEB_MAINTAINER|g" \
  -e "s|@INSTALLED_SIZE@|$installed_size|g" \
  -e "s|@NODE_MIN@|$NODE_MIN|g" \
  -e "s|@DSH_REF@|$DSH_REF|g" \
  -e "s|@DSH_COMMIT@|$DSH_COMMIT|g" \
  -e "s|@PNPM_VERSION@|$PNPM_VERSION|g" \
  "$ROOT/packaging/control.in" > "$rootfs/DEBIAN/control"
for script in postinst prerm postrm; do
  install -m 0755 "$ROOT/packaging/$script" "$rootfs/DEBIAN/$script"
done

# Normalize modes: cp -a preserves the builder's umask, while dpkg packages use
# 0755 directories and 0644/0755 files. Executable bits (launcher, spawn
# helpers, landlock-run) are preserved.
find "$rootfs" -type d -exec chmod 0755 {} +
find "$rootfs" -type f -perm -u+x -exec chmod 0755 {} +
find "$rootfs" -type f ! -perm -u+x -exec chmod 0644 {} +

# Deterministic archive timestamps; dpkg-deb otherwise records wall-clock mtimes.
find "$rootfs" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

log "${C_GREEN}rootfs ready${C_RESET}: $rootfs ($(du -sh "$rootfs" | cut -f1))"
