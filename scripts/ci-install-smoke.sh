#!/usr/bin/env bash
# CI-only check for an *installed* deepseek-harness package.
#
# The workflow installs the deb with `DSH_DEB_USER=<runner user>`, so the
# postinst is expected to have enabled dsh-web as that user's systemd *user*
# service. This script asserts the package never produced a root system unit,
# then validates the Web UI authentication flow either through the running user
# service or by starting the packaged ExecStart directly when the CI runner has
# no systemd user manager.
set -euo pipefail

UNIT=dsh-web.service

fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
pass() { printf '[ok] %s\n' "$*"; }

command -v dsh >/dev/null 2>&1 || fail "dsh is not on PATH"
command -v dsh-web-url >/dev/null 2>&1 || fail "dsh-web-url is not on PATH"
dpkg-query -W -f='${Status}' deepseek-harness 2>/dev/null | grep -q 'install ok installed' \
  || fail "deepseek-harness is not installed"
pass "dsh --version: $(dsh --version)"

[ -f "/usr/lib/systemd/user/$UNIT" ] || fail "user unit missing at /usr/lib/systemd/user/$UNIT"
[ ! -e "/lib/systemd/system/$UNIT" ] || fail "root system unit present at /lib/systemd/system/$UNIT"
[ ! -e "/usr/lib/systemd/system/$UNIT" ] || fail "root system unit present at /usr/lib/systemd/system/$UNIT"
pass "unit is installed only under /usr/lib/systemd/user"

wants="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/default.target.wants/$UNIT"
[ -L "$wants" ] || fail "user service was not enabled: $wants is missing"
pass "user service enabled at $wants"

work="$(mktemp -d)"
pid=""
cleanup() {
  if [ -n "$pid" ]; then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

url=""
service_active=0
if systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
  service_active=1
  pass "systemd user manager reports $UNIT active"
  for _ in $(seq 1 45); do
    url="$(dsh-web-url 2>/dev/null || true)"
    [ -n "$url" ] && break
    sleep 1
  done
  if [ -z "$url" ]; then
    journalctl --user -u "$UNIT" --no-pager -n 40 2>/dev/null || true
    fail "the user service is active but did not publish a launch URL"
  fi
fi

# Runners frequently have no user manager, so run the exact packaged ExecStart
# command in the foreground. Port 0 avoids colliding with a service that might
# already own 3080.
if [ "$service_active" -eq 0 ]; then
  printf '[info] no systemd user manager; starting the packaged command directly\n'
  ( cd "$work" && exec env HOME="$HOME" dsh web --no-open --host 127.0.0.1 --port 0 ) \
    >"$work/web.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 90); do
    url="$(sed -n 's/.*dsh web: \(http:\/\/[^ ]*\).*/\1/p' "$work/web.log" | head -n1)"
    [ -n "$url" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
fi

if [ -z "$url" ]; then
  [ -f "$work/web.log" ] && tail -n 40 "$work/web.log" >&2
  fail "Web UI did not report a launch URL"
fi

# Use the runtime's own Node fetch instead of curl: the package already
# requires Node >= 24.9, and CI images differ in which HTTP clients they ship.
node_bin=/usr/bin/node
[ -x "$node_bin" ] || node_bin="$(command -v node)"
DSH_SMOKE_ORIGIN="$url" "$node_bin" --input-type=module -e '
  const origin = process.env.DSH_SMOKE_ORIGIN
  const base = origin.split("?")[0]
  const unauth = await fetch(base)
  if (unauth.status !== 401) throw new Error(`GET ${base} without a token: ${unauth.status}, expected 401`)
  const token = await fetch(origin, { redirect: "manual" })
  if (token.status !== 303) throw new Error(`launch URL: ${token.status}, expected 303`)
  const cookies = token.headers.getSetCookie?.() ?? [token.headers.get("set-cookie")]
  if (cookies.length !== 1 || !cookies[0]) throw new Error("launch URL did not set the browser cookie")
  const cookie = cookies[0].split(";")[0]
  const clean = await fetch(base, { headers: { cookie } })
  const html = await clean.text()
  if (clean.status !== 200) throw new Error(`clean URL with cookie: ${clean.status}, expected 200`)
  if (!/<html/i.test(html)) throw new Error("clean URL did not serve the Web UI")
' || fail "Web UI authentication flow failed"
pass "Web UI auth flow: 401 without token, 303 token exchange, 200 with cookie"
