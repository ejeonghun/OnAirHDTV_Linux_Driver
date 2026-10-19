#!/bin/sh
# Install an onairgt-dkms package in a throwaway container and check that DKMS
# builds the module for the installed kernel headers, then remove it again.
# usage (as root, inside a debian/ubuntu or fedora container):
#   sh packaging/smoke-test.sh <onairgt-dkms .deb or .rpm>
# Never run this on a real system: it installs kernel headers and DKMS.
set -eu

PKGFILE=$(readlink -f "${1:?package file}")
NAME=onairgt

case $PKGFILE in
*.deb)
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq linux-headers-generic >/dev/null 2>&1 ||
		apt-get install -y -qq "linux-headers-$(dpkg --print-architecture)" >/dev/null
	apt-get install -y -qq "$PKGFILE" > /tmp/pkg-install.log 2>&1 ||
		{ cat /tmp/pkg-install.log; exit 1; }
	VERSION=$(dpkg-deb -f "$PKGFILE" Version)
	remove() { apt-get remove -y -qq --purge onairgt-dkms; }
	;;
*.rpm)
	# kernel-core owns /lib/modules/<kver>/build, the link to kernel-devel
	dnf -q -y install --setopt=install_weak_deps=False kernel-core kernel-devel >/dev/null
	dnf -y install "$PKGFILE" > /tmp/pkg-install.log 2>&1 ||
		{ cat /tmp/pkg-install.log; exit 1; }
	VERSION=$(rpm -qp --qf '%{VERSION}' "$PKGFILE")
	remove() { dnf -q -y remove --setopt=clean_requirements_on_remove=False onairgt-dkms; }
	;;
*) echo "not a .deb or .rpm: $PKGFILE" >&2; exit 2 ;;
esac

grep -E 'kheaders:|Building module|Installing|error|failed' /tmp/pkg-install.log || true
echo "=== dkms status"
dkms status -m "$NAME"
status=0
n=0
for d in /lib/modules/*/build; do
	[ -e "$d/Makefile" ] || continue
	k=${d%/build}
	k=${k##*/}
	n=$((n + 1))
	ko=$(find "/lib/modules/$k" -name 'dvb-usb-onairgt.ko*' | head -n 1)
	if dkms status -m "$NAME" -v "$VERSION" -k "$k" | grep -q installed && [ -n "$ko" ]; then
		echo "PASS $k: $ko"
		modinfo "$ko" | grep -E '^(vermagic|depends|alias)' | head -n 3
		grep 'kheaders:' "/var/lib/dkms/$NAME/$VERSION/$k/$(uname -m)/log/make.log" \
			"/var/lib/dkms/$NAME/$VERSION/build/make.log" 2>/dev/null | head -n 2 || true
	else
		echo "FAIL $k"
		cat "/var/lib/dkms/$NAME/$VERSION/build/make.log" 2>/dev/null | tail -n 30
		status=1
	fi
done
[ $n -gt 0 ] || { echo "FAIL: no kernel headers installed"; status=1; }

echo "=== header cache"
find /var/cache/onairgt -name MANIFEST -exec sh -c 'head -n 1 "$1"' sh {} \; 2>/dev/null || true

echo "=== remove"
remove >/dev/null
if [ -n "$(dkms status -m "$NAME" 2>/dev/null)" ] || [ -d "/var/lib/dkms/$NAME" ] ||
   [ -d "/usr/src/$NAME-$VERSION" ] || [ -d /var/cache/onairgt ] ||
   find /lib/modules -name 'dvb-usb-onairgt.ko*' | grep -q .; then
	echo "FAIL: leftovers after removal"
	dkms status -m "$NAME"
	status=1
else
	echo "PASS removal: no DKMS entry, no /usr/src/$NAME-$VERSION, no header cache, no module"
fi
exit $status
