SHELL := /usr/bin/env bash

PACKAGE_NAME := galaxybook-max98390-kmod
VERSION := $(shell sed -n 's/^Version:[[:space:]]*//p' packaging/fedora/$(PACKAGE_NAME).spec | head -n1)
DIST_DIR := dist
RPM_SPEC := packaging/fedora/$(PACKAGE_NAME).spec
RPMBUILD_DIR := .rpmbuild

.PHONY: help build clean dist srpm rpm

help:
	@printf '%s\n' \
		'make build  Build the external modules for the running kernel' \
		'make dist   Create a source tarball in dist/' \
		'make srpm   Create a source RPM in dist/' \
		'make rpm    Create akmod/meta RPMs and a source RPM in dist/' \
		'make clean  Remove local build artifacts'

build:
	$(MAKE) -C module

clean:
	$(MAKE) -C module clean >/dev/null 2>&1 || true
	rm -rf $(DIST_DIR) $(RPMBUILD_DIR)

dist: clean
	mkdir -p $(DIST_DIR)
	tar \
		--exclude='./.git' \
		--exclude='./dist' \
		--exclude='./.rpmbuild' \
		--transform='s,^\./,$(PACKAGE_NAME)-$(VERSION)/,' \
		-czf $(DIST_DIR)/$(PACKAGE_NAME)-$(VERSION).tar.gz \
		.

srpm: dist
	@set -euo pipefail; \
	rm -rf "$(RPMBUILD_DIR)"; \
	mkdir -p "$(RPMBUILD_DIR)"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}; \
	cp "$(DIST_DIR)/$(PACKAGE_NAME)-$(VERSION).tar.gz" "$(RPMBUILD_DIR)/SOURCES/"; \
	cp "$(RPM_SPEC)" "$(RPMBUILD_DIR)/SPECS/"; \
	rpmbuild -bs "$(RPMBUILD_DIR)/SPECS/$(PACKAGE_NAME).spec" --define "_topdir $$(pwd)/$(RPMBUILD_DIR)"; \
	cp "$(RPMBUILD_DIR)"/SRPMS/*.src.rpm "$(DIST_DIR)/"

rpm: dist
	@set -euo pipefail; \
	rm -rf "$(RPMBUILD_DIR)"; \
	mkdir -p "$(RPMBUILD_DIR)"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}; \
	cp "$(DIST_DIR)/$(PACKAGE_NAME)-$(VERSION).tar.gz" "$(RPMBUILD_DIR)/SOURCES/"; \
	cp "$(RPM_SPEC)" "$(RPMBUILD_DIR)/SPECS/"; \
	rpmbuild -ba "$(RPMBUILD_DIR)/SPECS/$(PACKAGE_NAME).spec" --define "_topdir $$(pwd)/$(RPMBUILD_DIR)"; \
	cp "$(RPMBUILD_DIR)"/SRPMS/*.src.rpm "$(DIST_DIR)/"; \
	find "$(RPMBUILD_DIR)/RPMS" -type f -name '*.rpm' -exec cp {} "$(DIST_DIR)/" \;
