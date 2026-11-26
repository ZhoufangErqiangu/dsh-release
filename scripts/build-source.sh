#!/usr/bin/env bash
# Install workspace dependencies and build all DSH runtime artifacts from the
# pinned checkout. Only artifact steps run: type-checking the repository's test
# programs is a contributor gate, not a release requirement.

set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_source_env
check_node_version

NODE="$(node_bin)"
PNPM="$(pnpm_bin)"
[ -n "$PNPM" ] || die "pnpm not found. The repository pins pnpm@$(cd "$SRC" && node -p "require('./package.json').packageManager")"

expected_pnpm="$(cd "$SRC" && node -p "require('./package.json').packageManager")"
actual_pnpm="$("$PNPM" --version)"
[ "pnpm@$actual_pnpm" = "$expected_pnpm" ] || die "pnpm version mismatch: repository pins $expected_pnpm, found pnpm@$actual_pnpm (set PNPM_BIN or enable corepack)"

case "${NODE_OPTIONS:-}" in
  *--no-experimental-strip-types*) die "NODE_OPTIONS disables TypeScript stripping; the DSH build scripts require it" ;;
esac

mkdir -p "$PNPM_STORE"
cd "$SRC"

log "installing workspace dependencies (store: $PNPM_STORE)"
"$PNPM" install --frozen-lockfile --store-dir "$PNPM_STORE"

# The artifact graph only builds the host-libc Node-API addon
# (`--host-addon-only`). The runtime also needs the static-musl Landlock
# launcher and the musl addon, so build the complete native set here.
"$ROOT/scripts/prepare-musl.sh"
log "building complete native system binaries (Landlock launcher + glibc/musl addons)"
PATH="$WORK/musl/bin:$PATH" "$PNPM" --filter @deepseek-ai/node-addon-system-workspace run build:native

native_pkg="$SRC/native/system/packages/linux-x64"
[ -x "$native_pkg/bin/landlock-run" ] || die "native build did not produce bin/landlock-run"
[ -f "$native_pkg/bin/glibc/system.node" ] || die "native build did not produce the glibc addon"
[ -f "$native_pkg/bin/musl/system.node" ] || die "native build did not produce the musl addon"

log "building runtime artifacts (official client profile)"
# --profile official selects the release branding and omits the local dirty
# marker, matching the artifacts the DSH publication workflow builds.
"$PNPM" run build:artifacts --profile official

[ -f "$SRC/apps/cli/lib/bin.js" ] || die "build did not produce apps/cli/lib/bin.js"
[ -f "$SRC/apps/web/dist/index.html" ] || die "build did not produce apps/web/dist/index.html"
[ -f "$SRC/.dsh-build/client-build-environment.json" ] || die "build did not write the client build record"

record="$SRC/.dsh-build/client-build-environment.json"
DSH_VERSION="$DSH_VERSION" DSH_COMMIT="$DSH_COMMIT" "$NODE" -e '
  const record = require(process.argv[1])
  const version = record.environment?.DSH_CLIENT_VERSION
  const commit = record.environment?.DSH_CLIENT_COMMIT_HASH
  if (version !== process.env.DSH_VERSION) throw new Error(`client version ${version} != ${process.env.DSH_VERSION}`)
  if (commit !== process.env.DSH_COMMIT.slice(0, 7)) throw new Error(`client commit ${commit} != ${process.env.DSH_COMMIT.slice(0, 7)}`)
' "$record" || die "client build record does not match the pinned source"

log "${C_GREEN}artifacts ready${C_RESET}"
