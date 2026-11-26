#!/usr/bin/env bash
# Fetch the pinned DSH source into .work/src and write build/source.env.
#
# DSH_REF must be a tag or a full 40-character commit. The checkout is shallow
# (depth 1): a release build needs exactly one immutable tree, not history.
# An existing checkout is reused only when it is the same ref at the same
# commit, is clean, and still matches the recorded build/source.env — so
# iterative rebuilds do not throw away node_modules or built artifacts.

set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_configured_release_identity

require_cmd git "git is required to fetch the pinned source"
require_cmd node "Node.js is required to read the pinned source version"

check_node_version >/dev/null

: "${DSH_REPO_URL:?DSH_REPO_URL is empty}"
: "${DSH_REF:?DSH_REF is empty}"
: "${DEB_REVISION:?DEB_REVISION is empty}"

# The revision is appended to an upstream version that already contains a
# tilde (0.2.2~rc.5). A hyphen would split the Debian version at a different
# point and silently produce a confusing package version, so reject anything
# outside the Debian revision alphabet.
if ! printf '%s' "$DEB_REVISION" | grep -Eq '^[0-9A-Za-z][0-9A-Za-z.+~]*$'; then
  die "invalid DEB_REVISION '$DEB_REVISION': use only letters, digits, '.', '+', '~' (for example 'alex.1'), not a version prefix"
fi

IS_COMMIT=0
case "$DSH_REF" in
  *)
    if printf '%s' "$DSH_REF" | grep -Eq '^[0-9a-f]{40}$'; then
      IS_COMMIT=1
    else
      case "$DSH_REF" in
        */*|*:*|*' '*|refs/heads/*|refs/tags/*) die "DSH_REF must be a tag name or full commit hash, got: $DSH_REF" ;;
      esac
      if printf '%s' "$DSH_REF" | grep -Eq '^[0-9a-f]{7,39}$'; then
        die "DSH_REF looks like a short commit hash. Use the full 40-character hash or a tag: $DSH_REF"
      fi
    fi
    ;;
esac

host_arch="$(host_deb_arch)"
[ "$host_arch" = "$DEB_ARCH" ] || die "configured DEB_ARCH=$DEB_ARCH but this host is $host_arch; cross-building is not supported"

mkdir -p "$WORK" "$BUILD"
export GIT_TERMINAL_PROMPT=0

# remote_tag_commit NAME prints the commit a tag points at, peeling annotated
# tags. It fails when the tag does not exist.
remote_tag_commit() {
  local name="$1" out peeled direct
  out="$(git ls-remote --tags "$DSH_REPO_URL" "refs/tags/$name" "refs/tags/$name^{}" 2>/dev/null || true)"
  peeled="$(printf '%s\n' "$out" | awk -v want="refs/tags/$name^{}" '$2 == want { print $1; exit }')"
  if [ -n "$peeled" ]; then
    printf '%s\n' "$peeled"
    return 0
  fi
  direct="$(printf '%s\n' "$out" | awk -v want="refs/tags/$name" '$2 == want { print $1; exit }')"
  [ -n "$direct" ] || return 1
  printf '%s\n' "$direct"
}

resolve_remote_tag() {
  remote_tag_commit "$DSH_REF"
}

cached_commit=""
cached_ref=""
if [ -f "$BUILD/source.env" ]; then
  # Read the record without letting its variables leak into this script.
  cached_commit="$(sed -n "s/^DSH_COMMIT='\([0-9a-f]*\)'$/\1/p" "$BUILD/source.env")"
  cached_ref="$(sed -n "s/^DSH_REF='\(.*\)'$/\1/p" "$BUILD/source.env")"
fi

# Resolve the immutable commit this build must end up at. A cached record
# avoids network access on an unchanged pin; otherwise the tag is resolved
# against the remote before we decide whether the checkout is reusable.
desired_commit=""
if [ "$IS_COMMIT" -eq 1 ]; then
  desired_commit="$DSH_REF"
elif [ -n "$cached_commit" ] && [ "$cached_ref" = "$DSH_REF" ]; then
  desired_commit="$cached_commit"
else
  desired_commit="$(resolve_remote_tag || true)"
fi

reuse=0
if [ -d "$SRC/.git" ] && [ -n "$desired_commit" ]; then
  head_commit="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)"
  if [ "$head_commit" = "$desired_commit" ] && [ -z "$(git -C "$SRC" status --porcelain --untracked-files=no)" ]; then
    reuse=1
  fi
fi

if [ "$reuse" -eq 1 ]; then
  step "reusing pinned checkout at $SRC (${desired_commit:0:12})"
else
  if [ -e "$SRC" ]; then
    log "discarding previous source checkout (its ref or commit no longer matches the pin)"
    rm -rf "$SRC"
  fi
  mkdir -p "$SRC"
  git -C "$SRC" init -q
  git -C "$SRC" remote add origin "$DSH_REPO_URL"

  if [ "$IS_COMMIT" -eq 1 ]; then
    log "fetching commit $DSH_REF"
    git -C "$SRC" fetch --depth=1 --no-tags origin "$DSH_REF" \
      || die "could not fetch commit $DSH_REF (GitHub serves only reachable commits; use a release tag instead)"
    git -C "$SRC" checkout -q --detach FETCH_HEAD
  else
    if [ -z "$desired_commit" ]; then
      hint="$(remote_tag_commit "dsh-$DSH_REF" 2>/dev/null || true)"
      if [ -n "$hint" ]; then
        die "tag not found upstream: $DSH_REF (did you mean dsh-$DSH_REF?)"
      fi
      die "tag not found upstream: $DSH_REF"
    fi
    log "fetching tag $DSH_REF (${desired_commit:0:12})"
    git -C "$SRC" fetch --depth=1 --no-tags origin "+refs/tags/$DSH_REF:refs/tags/$DSH_REF"
    git -C "$SRC" checkout -q --detach "$DSH_REF^{commit}"
  fi
fi

HEAD_COMMIT="$(git -C "$SRC" rev-parse HEAD)"
[ -n "$desired_commit" ] || die "could not resolve $DSH_REF to an immutable commit"
[ "$HEAD_COMMIT" = "$desired_commit" ] || die "pinned source mismatch: wanted $desired_commit, checked out $HEAD_COMMIT"

[ -z "$(git -C "$SRC" status --porcelain --untracked-files=no)" ] || die "source checkout is dirty after fetch"

DSH_VERSION="$(cd "$SRC" && node -p "require('./package.json').version")"
printf '%s' "$DSH_VERSION" | grep -Eq '^[0-9][0-9A-Za-z.+~-]*$' || die "unexpected upstream version: $DSH_VERSION"

# 0.2.2-rc.5 -> 0.2.2~rc.5: a Debian upstream version may not contain a hyphen
# (it separates the revision), and '~' sorts before the final release.
DEB_UPSTREAM_VERSION="${DSH_VERSION/-/\~}"
DEB_FULL_VERSION="${DEB_UPSTREAM_VERSION}-${DEB_REVISION}"
DSH_RELEASE_TAG="$(release_tag "$DSH_VERSION" "$DEB_REVISION")"
SOURCE_DATE_EPOCH="$(git -C "$SRC" log -1 --format=%ct)"

cat > "$BUILD/source.env" <<EOF
# Generated by scripts/fetch-source.sh — do not edit.
DSH_REPO_URL='$DSH_REPO_URL'
DSH_REF='$DSH_REF'
DSH_VERSION='$DSH_VERSION'
DSH_COMMIT='$HEAD_COMMIT'
DEB_UPSTREAM_VERSION='$DEB_UPSTREAM_VERSION'
DEB_REVISION='$DEB_REVISION'
DEB_FULL_VERSION='$DEB_FULL_VERSION'
DSH_RELEASE_TAG='$DSH_RELEASE_TAG'
DEB_PACKAGE='$DEB_PACKAGE'
DEB_ARCH='$DEB_ARCH'
SOURCE_DATE_EPOCH='$SOURCE_DATE_EPOCH'
EOF

log "${C_GREEN}source ready${C_RESET}: dsh $DSH_VERSION @ ${HEAD_COMMIT:0:12} (deb $DEB_FULL_VERSION${DSH_RELEASE_TAG:+, release $DSH_RELEASE_TAG})"
