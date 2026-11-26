#!/usr/bin/env bash
# Verify the built .deb without installing it system-wide:
#   * control metadata and dependency/conflict fields
#   * data-owned paths, modes, and unit placement (user unit only)
#   * maintainer-script syntax
#   * systemd unit syntax where systemd-analyze can verify an offline root
#   * the packaged launcher and Web UI actually boot from an extracted root
#
# The smoke test does not need the package to be installed, because the
# launcher supports DSH_APP_ROOT/DSH_NODE for exactly this kind of check.

set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_source_env
require_cmd curl "curl is required for the Web UI smoke test"

deb="$(deb_file)"
[ -f "$deb" ] || die "package missing: $deb"

check=0
pass() { check=$((check + 1)); printf '  %s[ok]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
fail() { printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

log "verifying $(basename "$deb")"

info="$(dpkg-deb --field "$deb")"
grep -q "^Package: $DEB_PACKAGE$" <<<"$info" || fail "control Package is not $DEB_PACKAGE"
grep -q "^Version: $DEB_FULL_VERSION$" <<<"$info" || fail "control Version is not $DEB_FULL_VERSION"
grep -q "^Architecture: $DEB_ARCH$" <<<"$info" || fail "control Architecture is not $DEB_ARCH"
grep -q "^Depends: .*nodejs (>= $NODE_MIN)" <<<"$info" || fail "missing nodejs (>= $NODE_MIN) dependency"
grep -q "^Depends: .*libc6" <<<"$info" || fail "missing libc6 dependency"
grep -q "^Conflicts: dsh$" <<<"$info" || fail "missing Conflicts: dsh (the unrelated Ubuntu package)"
grep -q "^X-DSH-Source-Commit: $DSH_COMMIT$" <<<"$info" || fail "source commit is not recorded in control"
pass "control metadata (version, arch, node dependency, source commit)"

rm -rf "$BUILD/verify"
mkdir -p "$BUILD/verify/root" "$BUILD/verify/home"
dpkg-deb --extract "$deb" "$BUILD/verify/root"
root="$BUILD/verify/root"

[ -x "$root/usr/bin/dsh" ] || fail "/usr/bin/dsh is missing or not executable"
[ -x "$root/usr/bin/dsh-web-url" ] || fail "/usr/bin/dsh-web-url is missing or not executable"
[ -f "$root/usr/lib/dsh/app/node_modules/@deepseek-ai/dsh/lib/bin.js" ] || fail "CLI entry is missing from the payload"
[ -f "$root/usr/lib/dsh/app/node_modules/@deepseek-ai/dsh-web-frontend/dist/index.html" ] || fail "Web UI dist is missing from the payload"
[ -f "$root/usr/lib/systemd/user/dsh-web.service" ] || fail "user unit is missing"
[ ! -e "$root/lib/systemd/system/dsh-web.service" ] || fail "a root system unit was packaged; that must never happen"
[ ! -e "$root/usr/lib/systemd/system/dsh-web.service" ] || fail "a root system unit was packaged; that must never happen"
[ -f "$root/usr/share/doc/$DEB_PACKAGE/copyright" ] || fail "copyright file is missing"
[ -f "$root/usr/share/doc/$DEB_PACKAGE/README.Debian.gz" ] || fail "README.Debian.gz is missing"
[ -f "$root/usr/share/doc/$DEB_PACKAGE/THIRD_PARTY_NOTICES.md" ] || fail "third-party notices are missing"
[ -f "$root/usr/share/doc/$DEB_PACKAGE/BUILD-INFO.json" ] || fail "BUILD-INFO.json is missing"
pass "payload layout and documentation"

unit="$root/usr/lib/systemd/user/dsh-web.service"
grep -q '^WantedBy=default.target$' "$unit" || fail "unit is not enabled by default.target"
grep -q '^ExecStart=/usr/bin/dsh web' "$unit" || fail "unit does not start dsh web"
grep -q '^User=' "$unit" && fail "user unit must not set User=" || true
grep -q '^EnvironmentFile=-%h/.config/dsh/web.env$' "$unit" || fail "unit does not read the per-user env file"
grep -q -- '--no-open' "$unit" || fail "unit would try to open a browser under systemd"
pass "user unit content (no User=, no root paths, --no-open)"

dpkg-deb --control "$deb" "$BUILD/verify/control"
for script in postinst prerm postrm; do
  sh -n "$BUILD/verify/control/$script" || fail "maintainer script $script has a syntax error"
done
pass "maintainer-script syntax"

if command -v systemd-analyze >/dev/null 2>&1; then
  # Verify the real unit's syntax and directives, with only ExecStart pointed at
  # an existing local binary (the packaged /usr/bin/dsh is not installed on the
  # build host). The real ExecStart path is checked separately above.
  mkdir -p "$BUILD/verify/unit"
  sed 's|^ExecStart=.*|ExecStart=/bin/true|' "$unit" > "$BUILD/verify/unit/dsh-web.service"
  if LC_ALL=C systemd-analyze verify "$BUILD/verify/unit/dsh-web.service" >"$BUILD/verify/systemd-analyze.log" 2>&1; then
    pass "systemd-analyze verify (unit syntax)"
  else
    cat "$BUILD/verify/systemd-analyze.log" >&2
    fail "systemd-analyze rejected dsh-web.service"
  fi
fi

NODE="$(node_bin)"
[ -n "$NODE" ] || die "Node.js is required for the smoke test"
version="$("$NODE" -p "process.versions.node")"

log "smoke: dsh --version (Node $version, extracted tree)"
DSH_APP_ROOT="$root/usr/lib/dsh/app" DSH_NODE="$NODE" HOME="$BUILD/verify/home" \
  "$root/usr/bin/dsh" --version >"$BUILD/verify/version.log" 2>&1 || {
    cat "$BUILD/verify/version.log" >&2
    fail "packaged launcher could not run --version"
  }
grep -q "^$DSH_VERSION$" "$BUILD/verify/version.log" || {
  cat "$BUILD/verify/version.log" >&2
  fail "launcher reported an unexpected version"
}
pass "packaged launcher runs dsh $DSH_VERSION"

log "smoke: dsh web boots and serves the Web UI"
mkdir -p "$BUILD/verify/dsh-home" "$BUILD/verify/workspace"
web_log="$BUILD/verify/web.log"
( cd "$BUILD/verify/workspace" && exec env \
    DSH_APP_ROOT="$root/usr/lib/dsh/app" \
    DSH_NODE="$NODE" \
    DSH_HOME="$BUILD/verify/dsh-home" \
    HOME="$BUILD/verify/home" \
    DSH_TELEMETRY_DISABLED=1 \
    "$root/usr/bin/dsh" web --no-open --host 127.0.0.1 --port 0 ) \
  >"$web_log" 2>&1 &
web_pid=$!
cleanup() { kill "$web_pid" >/dev/null 2>&1 || true; wait "$web_pid" 2>/dev/null || true; }
trap cleanup EXIT

origin=""
for _ in $(seq 1 120); do
  origin="$(sed -n 's/.*dsh web: \(http:\/\/127\.0\.0\.1:[0-9][0-9]*\/?token=[A-Za-z0-9_-]*\).*/\1/p' "$web_log" | head -n1)"
  [ -n "$origin" ] && break
  kill -0 "$web_pid" 2>/dev/null || break
  sleep 0.5
done
if [ -z "$origin" ]; then
  cat "$web_log" >&2
  fail "Web UI did not report a tokenized listening URL"
fi
base="${origin%%\?*}"
jar="$BUILD/verify/cookies.txt"

# The launch URL is the only unauthenticated input: a bare index request must
# be rejected, the token must mint the browser cookie, and the clean URL must
# then work with that cookie.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$base" || true)"
[ "$unauth" = "401" ] || { tail -40 "$web_log" >&2; fail "unauthenticated GET $base returned $unauth, expected 401"; }
code="$(curl -sS -c "$jar" -L -o "$BUILD/verify/index.html" -w '%{http_code}' --max-time 20 "$origin" || true)"
[ "$code" = "200" ] || { tail -40 "$web_log" >&2; fail "GET launch URL returned $code"; }
grep -qi "<html" "$BUILD/verify/index.html" || fail "served page does not look like the Web UI"
cookie_code="$(curl -sS -b "$jar" -o /dev/null -w '%{http_code}' --max-time 20 "$base" || true)"
[ "$cookie_code" = "200" ] || fail "GET $base with the minted cookie returned $cookie_code"
pass "Web UI served at $base (401 without token, 200 with token/cookie)"
cleanup
trap - EXIT

log "${C_GREEN}all checks passed${C_RESET} ($check structural checks + runtime smoke)"
