#!/usr/bin/env bash
# Shared shell helpers for the dsh-release build.
#
# Every script can run standalone (it locates the repository root from its own
# path) or under the Makefile (which exports ROOT/WORK/SRC/BUILD/DIST).

set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORK="${WORK:-$ROOT/.work}"
SRC="${SRC:-$WORK/src}"
BUILD="${BUILD:-$ROOT/build}"
DIST="${DIST:-$ROOT/dist}"
PNPM_STORE="${PNPM_STORE:-$WORK/pnpm-store}"
export ROOT WORK SRC BUILD DIST PNPM_STORE

# shellcheck source=../release.conf
. "$ROOT/release.conf"

if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  C_RESET='' C_BOLD='' C_DIM='' C_GREEN='' C_YELLOW='' C_RED=''
else
  C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_RED=$'\033[31m'
fi

log()  { printf '%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$*" >&2; }
step() { printf '%s  -%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[error]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# require_cmd CMD MESSAGE
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "${2:-required command not found: $1}"
}

# node_bin prints the Node executable used for builds and verification.
# DSH_NODE overrides discovery; nvm users can export it for local builds.
node_bin() {
  if [ -n "${DSH_NODE:-}" ]; then
    printf '%s\n' "$DSH_NODE"
    return 0
  fi
  command -v node 2>/dev/null || true
}

# pnpm_bin prints the pnpm executable. The repository pins pnpm@11.28.5; the
# build verifies the version against package.json so a stale global pnpm fails
# loudly instead of producing a subtly different dependency tree.
pnpm_bin() {
  if [ -n "${PNPM_BIN:-}" ]; then
    printf '%s\n' "$PNPM_BIN"
    return 0
  fi
  if command -v pnpm >/dev/null 2>&1; then
    command -v pnpm
    return 0
  fi
  # After the first `pnpm install`, the pinned pnpm is available inside the
  # source checkout even when it is not on PATH (corepack not enabled).
  if [ -x "$SRC/node_modules/.bin/pnpm" ]; then
    printf '%s\n' "$SRC/node_modules/.bin/pnpm"
    return 0
  fi
}

# check_node_version enforces the repository's Node floor (>= 24.9.0).
check_node_version() {
  local node min
  node="$(node_bin)"
  [ -n "$node" ] || die "Node.js not found. Install Node >= $NODE_MIN (NodeSource) or set DSH_NODE."
  min="$NODE_MIN" "$node" -e '
    const [a,b,c] = process.versions.node.split(".").map(Number)
    const [x,y,z] = process.env.min.split(".").map(Number)
    if (a < x || (a === x && (b < y || (b === y && c < z)))) {
      console.error(`Node ${process.versions.node} is older than required ${process.env.min}`)
      process.exit(1)
    }
  ' || die "Node >= $NODE_MIN is required (found $("$node" -v)). See README."
}

# load_source_env reads build/source.env produced by fetch-source.sh.
load_source_env() {
  [ -f "$BUILD/source.env" ] || die "missing $BUILD/source.env; run scripts/fetch-source.sh first"
  # shellcheck disable=SC1090
  . "$BUILD/source.env"
}

# deb_file prints the absolute path of the built package.
deb_file() {
  local name
  name="$(cat "$DIST/latest.txt" 2>/dev/null || true)"
  [ -n "$name" ] || die "no built package recorded in $DIST/latest.txt; run scripts/package.sh first"
  printf '%s/%s\n' "$DIST" "$name"
}

host_deb_arch() {
  case "$(uname -m)" in
    x86_64)  echo amd64 ;;
    aarch64) echo arm64 ;;
    *)       die "unsupported build architecture: $(uname -m)" ;;
  esac
}

# --- release version scheme --------------------------------------------------
#
# A release version is
#
#   v<upstream-version>-<DSH_RELEASE_ID>.<N>
#
# for example v0.2.2-rc.5-alex.1, where 0.2.2-rc.5 is the version in the pinned
# upstream checkout and alex.1 is our build identifier. The matching Debian
# version is 0.2.2~rc.5-alex.1: the tag keeps the upstream hyphen, while the
# package version turns that hyphen into '~' (Debian upstream versions may not
# contain '-', and '~' sorts a prerelease before the final release).

release_identity() {
  printf '%s\n' "${DSH_RELEASE_ID:-alex}"
}

# release_build_number REVISION prints N when REVISION is "<identity>.N".
release_build_number() {
  local id
  id="$(release_identity)"
  [[ "$1" =~ ^"$id"\.([0-9]+)$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# release_tag VERSION REVISION prints the release tag, or nothing when the
# revision does not follow the "<identity>.N" scheme (for example "1").
release_tag() {
  local n
  n="$(release_build_number "$2")" || return 0
  [ -n "$n" ] || return 0
  printf 'v%s-%s.%s\n' "$1" "$(release_identity)" "$n"
}

# release_identity_from_config prints DSH_RELEASE_ID as recorded in
# release.conf, ignoring an environment override.
release_identity_from_config() {
  env -u DSH_RELEASE_ID bash -c '. "$1/release.conf"; printf "%s" "$DSH_RELEASE_ID"' _ "$ROOT"
}

# require_configured_release_identity keeps the build identity in one place.
# The CI tag filter and check-release-tag.sh read release.conf, so an
# environment override would produce a tag the pipeline does not recognise.
require_configured_release_identity() {
  local configured current
  configured="$(release_identity_from_config)"
  printf '%s' "$configured" | grep -Eq '^[a-z][a-z0-9]*$' \
    || die "invalid DSH_RELEASE_ID '$configured' in release.conf: use lowercase letters and digits (for example 'alex')"
  current="$(release_identity)"
  [ "$current" = "$configured" ] \
    || die "DSH_RELEASE_ID is overridden as '$current', but release.conf records '$configured'; edit release.conf instead (the tag filter and CI validation read the file)"
}
