#!/bin/sh
# Build onairgt-dkms_<version>_all.deb with dpkg-deb.
# usage: sh packaging/build-deb.sh [outdir]      (default: dist/)
# The version is PACKAGE_VERSION from dkms.conf. File times come from
# SOURCE_DATE_EPOCH (default: the last commit), so rebuilds are identical.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
OUT=${1:-$REPO/dist}
VERSION=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$REPO/dkms.conf")
NAME=$(sed -n 's/^PACKAGE_NAME="\(.*\)"/\1/p' "$REPO/dkms.conf")
: "${SOURCE_DATE_EPOCH:=$(git -C "$REPO" log -1 --format=%ct 2>/dev/null || date +%s)}"
export SOURCE_DATE_EPOCH

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root=$work/root
make -s -C "$REPO" dkms-src DEST="$root/usr/src/$NAME-$VERSION"

mkdir -p "$root/DEBIAN"
size=$(du -sk "$root/usr" | cut -f1)
sed -e "s/@VERSION@/$VERSION/" -e "s/@SIZE@/$size/" "$HERE/deb/control" > "$root/DEBIAN/control"
for f in postinst prerm postrm; do
	sed "s/@VERSION@/$VERSION/" "$HERE/deb/$f" > "$root/DEBIAN/$f"
	chmod 0755 "$root/DEBIAN/$f"
done

find "$root" -type d -exec chmod 0755 {} +
find "$root/usr" -type f -exec chmod 0644 {} +
find "$root" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
mkdir -p "$OUT"
deb=$OUT/${NAME}-dkms_${VERSION}_all.deb
dpkg-deb --root-owner-group -Zxz --build "$root" "$deb" >/dev/null
echo "$deb"
