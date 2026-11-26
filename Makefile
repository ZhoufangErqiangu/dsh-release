# Build the DeepSeek Harness Debian package from pinned source.
#
#   make            fetch -> build -> stage -> package -> verify
#   make deb        same as the default target
#   make release    advance the release version, commit, tag and push it
#                   (GitHub Actions builds and publishes from the tag)
#   make check      re-run structural checks and the runtime smoke test
#   make version    show the pinned source and the release version
#   make clean      remove build/ and dist/ (keeps the fetched source and pnpm store)
#   make distclean  also remove .work/ (source checkout, node_modules, pnpm store)
#
# Release versions are v<upstream-version>-alex.<N> (for example
# v0.2.2-rc.5-alex.1); the matching .deb is 0.2.2~rc.5-alex.1. scripts/release.sh
# owns the build number. For a one-off local package, override the pin and the
# build identity directly:
#   make DSH_REF=<tag-or-40-char-commit> DEB_REVISION=alex.7
#
# Everything runs as the invoking user. The .deb itself is built with
# dpkg-deb --root-owner-group, so fakeroot or root is not needed.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

ROOT := $(CURDIR)

# release.conf holds shell defaults. Read them through the shell (rather than
# `include`) so `?=` lets an environment value or a command-line override win.
DSH_REPO_URL ?= $(shell . ./release.conf; printf '%s' "$$DSH_REPO_URL")
DSH_REF ?= $(shell . ./release.conf; printf '%s' "$$DSH_REF")
DEB_PACKAGE ?= $(shell . ./release.conf; printf '%s' "$$DEB_PACKAGE")
DEB_REVISION ?= $(shell . ./release.conf; printf '%s' "$$DEB_REVISION")
DEB_ARCH ?= $(shell . ./release.conf; printf '%s' "$$DEB_ARCH")
DEB_MAINTAINER ?= $(shell . ./release.conf; printf '%s' "$$DEB_MAINTAINER")
NODE_MIN ?= $(shell . ./release.conf; printf '%s' "$$NODE_MIN")

export ROOT DSH_REPO_URL DSH_REF DEB_PACKAGE DEB_REVISION DEB_ARCH DEB_MAINTAINER NODE_MIN

.DEFAULT_GOAL := deb

.PHONY: all deb fetch build stage package verify check clean distclean print-config release version

all: deb

fetch:
	scripts/fetch-source.sh

build: fetch
	scripts/build-source.sh

stage: build
	scripts/stage-rootfs.sh

package: stage
	scripts/package.sh

verify check: package
	scripts/verify-deb.sh

deb: verify
	@printf '\nDeepSeek Harness package: %s\n' "$$(cat $(ROOT)/dist/latest.txt)"

print-config:
	@printf 'source:  %s @ %s\n' "$(DSH_REPO_URL)" "$(DSH_REF)"
	@printf 'package: %s (%s, %s)\n' "$(DEB_PACKAGE)" "$(DEB_REVISION)" "$(DEB_ARCH)"
	@printf 'release: v<upstream-version>-$(shell . ./release.conf; printf '%s' "$$DSH_RELEASE_ID").<N>\n'
	@printf 'node:    >= %s (system)\n' "$(NODE_MIN)"

release:
	scripts/release.sh

version:
	@if [ -f "$(ROOT)/build/source.env" ]; then \
	  . "$(ROOT)/build/source.env"; \
	  printf 'source:  %s (%s)\n' "$$DSH_REF" "$${DSH_COMMIT:0:12}"; \
	  printf 'release: %s\n' "$${DSH_RELEASE_TAG:-<none>}"; \
	  printf 'deb:     %s\n' "$$DEB_FULL_VERSION"; \
	else \
	  . "$(ROOT)/release.conf"; \
	  printf 'source pin: %s\n' "$$DSH_REF"; \
	  printf 'revision:   %s (run make fetch to resolve the upstream version)\n' "$$DEB_REVISION"; \
	fi

clean:
	rm -rf "$(ROOT)/build" "$(ROOT)/dist"

distclean: clean
	rm -rf "$(ROOT)/.work"
