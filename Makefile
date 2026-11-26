# Build the DeepSeek Harness Debian package from pinned source.
#
#   make            fetch -> build -> stage -> package -> verify
#   make deb        same as the default target
#   make check      re-run structural checks and the runtime smoke test
#   make clean      remove build/ and dist/ (keeps the fetched source and pnpm store)
#   make distclean  also remove .work/ (source checkout, node_modules, pnpm store)
#
# Override the pin for a one-off build:
#   make DSH_REF=<tag-or-40-char-commit> DEB_REVISION=2
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

.PHONY: all deb fetch build stage package verify check clean distclean print-config

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
	@printf 'node:    >= %s (system)\n' "$(NODE_MIN)"

clean:
	rm -rf "$(ROOT)/build" "$(ROOT)/dist"

distclean: clean
	rm -rf "$(ROOT)/.work"
