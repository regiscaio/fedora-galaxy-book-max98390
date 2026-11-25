#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TEST_DIR/.." && pwd)"
SPEC="$REPO_ROOT/packaging/fedora/galaxybook-max98390-kmod.spec"
FILTER="$REPO_ROOT/scripts/kmodtool-queue-only-filter.sh"
HELPER="$REPO_ROOT/scripts/finalizer-transaction.sh"
VERSION_SCRIPT="$REPO_ROOT/scripts/package-version.sh"
CONTAINER_IMAGE="${SRPM_BOOTSTRAP_IMAGE:-}"
EXPECTED_FAILURE='kmodtool queue-only filtering was deferred; refusing an unverified binary build'
EXPECTED_KERNEL_FAILURE='kmodtool is required to generate a source RPM with explicit kernels'

if [[ -z "$CONTAINER_IMAGE" ]]; then
    printf '%s\n' \
        'test_srpm_bootstrap: skipped (set SRPM_BOOTSTRAP_IMAGE to an rpm-build image without kmodtool)'
    exit 0
fi
if [[ ! "$CONTAINER_IMAGE" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]]; then
    printf 'test_srpm_bootstrap: unsafe container image: %s\n' "$CONTAINER_IMAGE" >&2
    exit 1
fi
if ! command -v podman >/dev/null 2>&1; then
    printf 'test_srpm_bootstrap: podman is unavailable\n' >&2
    exit 1
fi
if ! podman image exists "$CONTAINER_IMAGE"; then
    printf 'test_srpm_bootstrap: container image is unavailable: %s\n' \
        "$CONTAINER_IMAGE" >&2
    exit 1
fi

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/max98390-srpm-bootstrap.XXXXXX")"
cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/max98390-srpm-bootstrap.*)
            rm -rf -- "$TEST_ROOT"
            ;;
        *)
            printf 'test_srpm_bootstrap: refusing cleanup outside fixture: %s\n' \
                "$TEST_ROOT" >&2
            ;;
    esac
}
trap cleanup EXIT

version="$($VERSION_SCRIPT)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'test_srpm_bootstrap: unsafe package version: %s\n' "$version" >&2
    exit 1
}
package_name=galaxybook-max98390-kmod
topdir="$TEST_ROOT/rpmbuild"
mkdir -p "$topdir"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
git -C "$REPO_ROOT" archive --format=tar \
    --prefix="${package_name}-${version}/" HEAD | \
    gzip -n > "$topdir/SOURCES/${package_name}-${version}.tar.gz"
cp -- "$FILTER" "$topdir/SOURCES/kmodtool-queue-only-filter.sh"
cp -- "$HELPER" "$topdir/SOURCES/finalizer-transaction.sh"
sed 's/%/%%/g' "$HELPER" \
    > "$topdir/SOURCES/finalizer-transaction-pretrans.sh"
sed \
    -e "s/^Version:[[:space:]].*/Version:        ${version}/" \
    -e 's/^Release:[[:space:]].*/Release:        1%{?dist}/' \
    "$SPEC" > "$topdir/SPECS/${package_name}.spec"

if ! podman run --rm --pull=never --network=none \
    --env "TEST_PACKAGE_VERSION=$version" \
    --volume "$topdir:/work:Z" \
    "$CONTAINER_IMAGE" \
    /usr/bin/bash --noprofile --norc -c '
        set -euo pipefail
        test -x /usr/bin/rpmbuild
        test ! -e /usr/bin/kmodtool
        rpmbuild -bs /work/SPECS/galaxybook-max98390-kmod.spec \
            --define "_topdir /work" \
            > /work/buildsrpm.out 2> /work/buildsrpm.err
        test -f /work/SRPMS/galaxybook-max98390-kmod-*.src.rpm
        set +e
        rpmbuild -bs /work/SPECS/galaxybook-max98390-kmod.spec \
            --define "_topdir /work" \
            --define "kernels 7.3.4-200.fc44.x86_64" \
            > /work/explicit-kernel.out 2> /work/explicit-kernel.err
        kernel_status=$?
        set -e
        test "$kernel_status" -ne 0
        grep -Fq -- \
            "kmodtool is required to generate a source RPM with explicit kernels" \
            /work/explicit-kernel.err
        set +e
        rpmbuild -bp --nodeps /work/SPECS/galaxybook-max98390-kmod.spec \
            --define "_topdir /work" \
            --define "kmodtool_queue_only_build_verified 1" \
            --define "kmodtool_queue_only_filter_deferred 0" \
            > /work/binary.out 2> /work/binary.err
        status=$?
        set -e
        test "$status" -ne 0
        grep -Fq -- \
            "kmodtool queue-only filtering was deferred; refusing an unverified binary build" \
            /work/binary.err
        mkdir -p \
            "/work/BUILD/galaxybook-max98390-kmod-${TEST_PACKAGE_VERSION}-build/galaxybook-max98390-kmod-${TEST_PACKAGE_VERSION}"
        set +e
        rpmbuild -bc --short-circuit --nodeps \
            /work/SPECS/galaxybook-max98390-kmod.spec \
            --define "_topdir /work" \
            --define "kmodtool_queue_only_build_verified 1" \
            --define "kmodtool_queue_only_filter_deferred 0" \
            > /work/short-circuit.out 2> /work/short-circuit.err
        short_status=$?
        set -e
        test "$short_status" -ne 0
        grep -Fq -- \
            "kmodtool queue-only filtering was deferred; refusing an unverified binary build" \
            /work/short-circuit.err
    '; then
    printf '%s\n' 'test_srpm_bootstrap: container validation failed' >&2
    [[ ! -s "$topdir/buildsrpm.err" ]] || tail -n 20 "$topdir/buildsrpm.err" >&2
    [[ ! -s "$topdir/explicit-kernel.err" ]] || \
        tail -n 20 "$topdir/explicit-kernel.err" >&2
    [[ ! -s "$topdir/binary.err" ]] || tail -n 20 "$topdir/binary.err" >&2
    [[ ! -s "$topdir/short-circuit.err" ]] || \
        tail -n 20 "$topdir/short-circuit.err" >&2
    exit 1
fi

grep -Fq -- "$EXPECTED_FAILURE" "$topdir/binary.err" || {
    printf '%s\n' 'test_srpm_bootstrap: binary guard diagnostic is missing' >&2
    exit 1
}
grep -Fq -- "$EXPECTED_FAILURE" "$topdir/short-circuit.err" || {
    printf '%s\n' 'test_srpm_bootstrap: short-circuit build guard diagnostic is missing' >&2
    exit 1
}
grep -Fq -- "$EXPECTED_KERNEL_FAILURE" "$topdir/explicit-kernel.err" || {
    printf '%s\n' 'test_srpm_bootstrap: explicit-kernel source guard diagnostic is missing' >&2
    exit 1
}
printf '%s\n' 'test_srpm_bootstrap: ok'
