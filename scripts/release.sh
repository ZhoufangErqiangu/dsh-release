#!/usr/bin/env bash
# Cut a new release: advance the build number, rebuild the .deb from the pinned
# upstream source, record the version in release.conf, commit it, and tag the
# release as v<upstream-version>-<id>.<N>.
#
# The version always comes from the pinned upstream checkout, never from a
# hand-edited string:
#
#   upstream dsh-v0.2.2-rc.5   ->  0.2.2-rc.5   (package.json)
#   release tag                ->  v0.2.2-rc.5-alex.1
#   Debian version             ->  0.2.2~rc.5-alex.1
#
# N is one greater than the highest v*-<id>.<N> tag in this repository, so a
# build number is never reused, even after the upstream pin moves.
#
# Typical use:
#   scripts/release.sh                     # build + commit + tag, locally
#   scripts/release.sh --push              # ... and push, so CI publishes it
#   scripts/release.sh --dsh-ref dsh-v0.2.3 --ci
#                                          # move the pin, tag, push; CI builds
#   scripts/release.sh --dry-run           # show the next version, no tracked change

set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat <<'EOF'
usage: scripts/release.sh [options]

Advance the release version, build it, and tag it. The release version is
v<upstream-version>-<DSH_RELEASE_ID>.<N>, where <upstream-version> is read from
the pinned DSH checkout and N is the next repository-wide build number.

options:
  --dsh-ref REF         move the upstream pin to REF (tag or full 40-hex commit)
                        before releasing; written to release.conf on success
  --build-number N      force build number N (must be greater than every
                        existing v*-<id>.<N> tag)
  --no-build            do not run make; only advance release.conf and tag
  --push                push the release commit and tag to origin after building
  --ci                  shorthand for --no-build --push (GitHub Actions builds)
  --dry-run             resolve and print the plan; change no tracked file
  --no-commit           write release.conf but leave it uncommitted; must be
                        combined with --no-tag (useful for a local trial build)
  --no-tag              do not create the annotated git tag
  -h, --help            show this help

environment:
  RELEASE_BRANCH        branch releases are cut from (default: main)
  DSH_RELEASE_ID        edit it in release.conf; an environment override is
                        rejected because the CI tag filter reads the file

The working tree must be clean. The script fetches origin tags first so the
build number does not collide with an existing release.
EOF
}

# set_release_conf_values REF REVISION rewrites both default assignments
#   : "${DSH_REF:=...}"
#   : "${DEB_REVISION:=...}"
# in one atomic replace, without touching comments or preserving an environment
# override. Fails (leaving release.conf untouched) when a line is missing.
conf_tmp=""
cleanup_conf_tmp() { [ -z "$conf_tmp" ] || rm -f "$conf_tmp"; }
trap cleanup_conf_tmp EXIT

set_release_conf_values() {
  local ref="$1" revision="$2" file="$ROOT/release.conf" tmp
  tmp="$(mktemp "$file.XXXXXX")"
  conf_tmp="$tmp"
  if ! awk -v ref="$ref" -v revision="$revision" '
    BEGIN {
      p_ref = ": \"${DSH_REF:=" ; p_rev = ": \"${DEB_REVISION:="
      seen_ref = 0 ; seen_rev = 0
    }
    index($0, p_ref) == 1 && substr($0, length($0) - 1) == "}\"" {
      print ": \"${DSH_REF:=" ref "}\"" ; seen_ref = 1 ; next
    }
    index($0, p_rev) == 1 && substr($0, length($0) - 1) == "}\"" {
      print ": \"${DEB_REVISION:=" revision "}\"" ; seen_rev = 1 ; next
    }
    { print }
    END { if (!seen_ref || !seen_rev) exit 1 }
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    conf_tmp=""
    die "could not update release.conf at $file"
  fi
  chmod --reference="$file" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
  mv "$tmp" "$file"
  conf_tmp=""
}

# assert_tag_available TAG fails when the tag exists locally or on origin. It
# runs before the build and again after it, so a tag created during a long build
# cannot be silently overwritten.
assert_tag_available() {
  local tag="$1" remote_tags
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then
    die "tag $tag already exists locally; fetch tags or use --build-number"
  fi
  if [ -n "$remote" ]; then
    if remote_tags="$(git ls-remote --tags "$remote" "refs/tags/$tag" 2>/dev/null)"; then
      [ -z "$remote_tags" ] || die "tag $tag already exists on origin"
    else
      warn "could not check origin for tag $tag; creating it locally is still safe"
    fi
  fi
}

dsh_ref_override=""
build_number=""
do_build=1
do_commit=1
do_tag=1
do_push=0
dry_run=0
branch="${RELEASE_BRANCH:-main}"

while [ $# -gt 0 ]; do
  case "$1" in
    --dsh-ref)
      [ $# -ge 2 ] || die "--dsh-ref requires a value"
      dsh_ref_override="$2"
      shift 2
      ;;
    --dsh-ref=*)      dsh_ref_override="${1#*=}"; shift ;;
    --build-number)
      [ $# -ge 2 ] || die "--build-number requires a value"
      build_number="$2"
      shift 2
      ;;
    --build-number=*) build_number="${1#*=}"; shift ;;
    --no-build)       do_build=0; shift ;;
    --no-commit)      do_commit=0; shift ;;
    --no-tag)         do_tag=0; shift ;;
    --push)           do_push=1; shift ;;
    --ci)             do_build=0; do_push=1; shift ;;
    --dry-run)        dry_run=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

if [ "$do_commit" -eq 0 ] && { [ "$do_tag" -eq 1 ] || [ "$do_push" -eq 1 ]; }; then
  die "--no-commit cannot be combined with tagging or pushing"
fi
if [ "$do_tag" -eq 0 ] && [ "$do_push" -eq 1 ]; then
  die "--no-tag cannot be combined with --push"
fi

require_cmd git
require_cmd node
require_configured_release_identity
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "$ROOT is not a git repository"

# A release must be reproducible from one commit: refuse a dirty tree instead of
# committing unrelated edits along with the version bump.
[ -z "$(git -C "$ROOT" status --porcelain)" ] || die "working tree is dirty; commit or stash your changes before releasing"

current_branch="$(git -C "$ROOT" symbolic-ref --quiet --short HEAD || true)"
[ -n "$current_branch" ] || die "detached HEAD: check out '$branch' before releasing"
[ "$current_branch" = "$branch" ] || die "releases are cut from '$branch' (currently '$current_branch'); set RELEASE_BRANCH to override"
git -C "$ROOT" var GIT_AUTHOR_IDENT >/dev/null 2>&1 || die "git user.name and user.email are not configured"

# Fail before the expensive build (and before creating a tag) when publishing
# would not fast-forward: a commit made during the build is handled later.
if [ "$do_push" -eq 1 ]; then
  git -C "$ROOT" fetch --quiet origin "$branch" || die "could not fetch origin $branch; check the remote and retry"
  git -C "$ROOT" merge-base --is-ancestor "$(git -C "$ROOT" rev-parse FETCH_HEAD)" HEAD \
    || die "origin/$branch has commits this release does not contain; rebase first"
fi

new_ref="${dsh_ref_override:-$DSH_REF}"
[ -n "$new_ref" ] || die "DSH_REF is empty"
case "$new_ref" in
  */*|*:*|*' '*|refs/*) die "DSH_REF must be a tag name or full commit hash, got: $new_ref" ;;
esac
if printf '%s' "$new_ref" | grep -Eq '^[0-9a-f]{7,39}$'; then
  die "DSH_REF looks like a short commit hash; use the full 40-character hash or a tag: $new_ref"
fi

# Resolve the next build number from the tags published by earlier releases.
# Fetching can fail offline; the tag-existence check below still protects against
# reusing a number that origin already has.
export GIT_TERMINAL_PROMPT=0
remote="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
if [ -n "$remote" ]; then
  if git -C "$ROOT" fetch --quiet --tags --prune origin; then
    step "fetched release tags from origin"
  else
    warn "could not fetch tags from origin; the next build number may be stale"
  fi
fi

id="$(release_identity)"
max_build=0
while IFS= read -r tag_name; do
  [ -n "$tag_name" ] || continue
  if [[ "$tag_name" =~ ^v.*-"$id"\.([0-9]+)$ ]]; then
    tag_build=$((10#${BASH_REMATCH[1]}))
    if (( tag_build > max_build )); then
      max_build=$tag_build
    fi
  fi
done < <(git -C "$ROOT" tag -l "v*-$id.*")

if [ -n "$build_number" ]; then
  printf '%s' "$build_number" | grep -Eq '^[1-9][0-9]*$' || die "invalid --build-number '$build_number': use a positive integer"
  next_build=$((10#$build_number))
  (( next_build > max_build )) || die "--build-number $next_build is not greater than the highest existing build ($max_build)"
else
  next_build=$((max_build + 1))
fi
revision="$id.$next_build"

# Resolve the upstream version/commit before touching release.conf. This is the
# same pin validation the build runs later, so a bad ref fails before any
# tracked file changes.
log "resolving upstream source: $new_ref"
DSH_REF="$new_ref" DEB_REVISION="$revision" "$ROOT/scripts/fetch-source.sh"
load_source_env

tag="$(release_tag "$DSH_VERSION" "$revision")"
[ -n "$tag" ] || die "could not derive a release tag from DEB_REVISION=$revision"
[ "${DSH_RELEASE_TAG:-}" = "$tag" ] || die "build/source.env records release '${DSH_RELEASE_TAG:-<none>}', expected '$tag'"
deb_version="${DEB_UPSTREAM_VERSION}-${revision}"
[ "$deb_version" = "$DEB_FULL_VERSION" ] || die "build/source.env has deb version '$DEB_FULL_VERSION', expected '$deb_version'"
deb_name="${DEB_PACKAGE}_${deb_version}_${DEB_ARCH}.deb"

assert_tag_available "$tag"

actions="write release.conf"
[ "$do_build" -eq 1 ] && actions="$actions, build"
[ "$do_commit" -eq 1 ] && actions="$actions, commit"
[ "$do_tag" -eq 1 ] && actions="$actions, tag"
[ "$do_push" -eq 1 ] && actions="$actions, push"

printf '\n%srelease plan%s\n' "$C_BOLD" "$C_RESET"
printf '  upstream ref:     %s\n' "$new_ref"
printf '  upstream commit:  %s\n' "$DSH_COMMIT"
printf '  upstream version: %s\n' "$DSH_VERSION"
printf '  release tag:      %s\n' "$tag"
printf '  build number:     %s\n' "$next_build"
printf '  Debian version:   %s\n' "$deb_version"
printf '  package:          %s\n' "$DIST/$deb_name"
printf '  actions:          %s\n' "$actions"

if [ "$dry_run" -eq 1 ]; then
  printf '\ndry run: release.conf, tags, and dist/ were not modified\n'
  exit 0
fi

if [ "$do_build" -eq 1 ]; then
  require_cmd make
  log "building $tag"
  make -C "$ROOT" deb "DSH_REF=$new_ref" "DEB_REVISION=$revision"

  [ -f "$DIST/$deb_name" ] || die "build did not produce $DIST/$deb_name (latest: $(cat "$DIST/latest.txt" 2>/dev/null || echo none))"
  [ "$(cat "$DIST/latest.txt")" = "$deb_name" ] || die "$DIST/latest.txt does not point at $deb_name"
  [ "$(dpkg-deb -f "$DIST/$deb_name" Version)" = "$deb_version" ] || die "$deb_name does not declare Version: $deb_version"
  [ -f "$DIST/release.json" ] || die "dist/release.json is missing"
  RELEASE_JSON="$DIST/release.json" EXPECTED_TAG="$tag" EXPECTED_DEB="$deb_version" "$(node_bin)" -e '
    const release = require(process.env.RELEASE_JSON)
    if (release.releaseTag !== process.env.EXPECTED_TAG) {
      throw new Error(`manifest releaseTag ${release.releaseTag} != ${process.env.EXPECTED_TAG}`)
    }
    if (release.debVersion !== process.env.EXPECTED_DEB) {
      throw new Error(`manifest debVersion ${release.debVersion} != ${process.env.EXPECTED_DEB}`)
    }
  ' || die "dist/release.json does not describe the planned release"
  step "package verified: $DIST/$deb_name"

  # The build takes a while; make sure nobody published this number meanwhile.
  assert_tag_available "$tag"
fi

# Update the single source of truth for the next plain `make`.
set_release_conf_values "$new_ref" "$revision"
( unset DSH_REF DEB_REVISION; . "$ROOT/release.conf"
  [ "$DSH_REF" = "$new_ref" ] && [ "$DEB_REVISION" = "$revision" ] ) \
  || die "failed to write the release pin to release.conf"

if [ "$do_commit" -eq 1 ]; then
  if git -C "$ROOT" diff --quiet -- release.conf; then
    step "release.conf already records $tag; nothing to commit"
  else
    git -C "$ROOT" add release.conf
    git -C "$ROOT" commit -m "release: $tag" -m "Upstream: $new_ref ($DSH_COMMIT)
Debian:   $deb_version"
    step "committed release.conf"
  fi
fi

if [ "$do_tag" -eq 1 ]; then
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then
    [ "$(git -C "$ROOT" rev-parse "$tag^{commit}")" = "$(git -C "$ROOT" rev-parse HEAD)" ] \
      || die "tag $tag exists but does not point at HEAD"
    step "tag $tag already points at HEAD"
  else
    git -C "$ROOT" tag -a "$tag" -m "$tag

Upstream: $new_ref ($DSH_COMMIT)
Debian:   $deb_version"
    step "tagged $tag"
  fi
fi

if [ "$do_push" -eq 1 ]; then
  # Do not publish a tag that origin/main cannot fast-forward to: CI checks out
  # the tag, but the branch should remain the linear history of releases.
  git -C "$ROOT" fetch --quiet origin "$branch" || die "could not fetch origin $branch before pushing"
  git -C "$ROOT" merge-base --is-ancestor "$(git -C "$ROOT" rev-parse FETCH_HEAD)" HEAD \
    || die "origin/$branch has commits that this release does not contain; rebase and retry"

  # Push the tag first: the tag is what triggers CI, and a partial push is
  # easier to recover from than a branch that moved without its tag.
  if ! git -C "$ROOT" push origin "refs/tags/$tag"; then
    warn "the release commit and tag exist locally, but $tag was not pushed"
    printf '  retry the push instead of re-running this script (which would pick the next N):\n'
    printf '    git push origin %s\n' "refs/tags/$tag"
    exit 1
  fi
  if ! git -C "$ROOT" push origin "HEAD:refs/heads/$branch"; then
    warn "$tag is pushed and CI is already building it, but $branch was not pushed"
    printf '  retry when the network is back:\n'
    printf '    git push origin %s\n' "$branch"
    exit 1
  fi
  log "pushed $tag and $branch; the tag-triggered GitHub Actions build publishes it"
fi

if [ "$do_commit" -eq 0 ]; then
  warn "release.conf was updated but not committed (--no-commit)"
fi

printf '\n'
log "${C_GREEN}release ready${C_RESET}: $tag"
if [ "$do_build" -eq 1 ]; then
  printf '  package: %s\n' "$DIST/$deb_name"
fi
if [ "$do_tag" -eq 1 ]; then
  printf '  tag:     %s\n' "$tag"
  if [ "$do_push" -eq 0 ]; then
    printf '  publish: git push origin %s && git push origin %s\n' "$tag" "$branch"
  fi
else
  printf '  tag:     <not created (--no-tag)>\n'
fi
