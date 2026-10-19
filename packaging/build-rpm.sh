#!/bin/sh
# Build onairgt-dkms-<version>-1.noarch.rpm with rpmbuild.
# usage: sh packaging/build-rpm.sh [outdir]      (default: dist/)
# The version is PACKAGE_VERSION from dkms.conf.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
OUT=${1:-$REPO/dist}
VERSION=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$REPO/dkms.conf")
NAME=$(sed -n 's/^PACKAGE_NAME="\(.*\)"/\1/p' "$REPO/dkms.conf")
: "${SOURCE_DATE_EPOCH:=$(git -C "$REPO" log -1 --format=%ct 2>/dev/null || date +%s)}"
export SOURCE_DATE_EPOCH

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES" "$top/stage"
make -s -C "$REPO" dkms-src DEST="$top/stage/$NAME-$VERSION"
tar -C "$top/stage" --sort=name --owner=0 --group=0 --numeric-owner \
	--mtime="@$SOURCE_DATE_EPOCH" -czf "$top/SOURCES/$NAME-$VERSION.tar.gz" "$NAME-$VERSION"
rpmbuild -bb --quiet \
	--define "_topdir $top" \
	--define "pkgver $VERSION" \
	--define "use_source_date_epoch_as_buildtime 1" \
	--define "clamp_mtime_to_source_date_epoch 1" \
	--define "_buildhost reproducible" \
	"$HERE/onairgt-dkms.spec"
mkdir -p "$OUT"
for rpm in "$top"/RPMS/noarch/*.rpm; do
	cp "$rpm" "$OUT/"
	echo "$OUT/${rpm##*/}"
done
