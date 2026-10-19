#!/bin/sh
# Compile-test dvb-usb-onairgt inside a distro container.
#
# usage (inside the container, the repository mounted or checked out at $SRC):
#   SRC=/src sh compile.sh <target>
# targets:
#   ubuntu-18.04 ubuntu-18.04-hwe ubuntu-20.04 ubuntu-22.04 ubuntu-24.04
#   debian-11 debian-12 debian-13 fedora vanilla-4.4.302 vanilla-5.10.55
#
# Distro targets install the distro's generic kernel headers package and build
# against it (headers fetched from kernel.org by kheaders.sh). Vanilla targets
# configure a kernel.org tree with the DVB options and build against the full
# tree (its own private headers). Prints "RESULT <target> <kernel> PASS|FAIL".
set -eu

T=${1:?target}
SRC=${SRC:-/src}
WORK=/tmp/onairgt-build

apt_setup() {
	export DEBIAN_FRONTEND=noninteractive
	# Debian 11 left the regular mirrors in 2026
	if grep -q 'bullseye' /etc/os-release 2>/dev/null; then
		rm -f /etc/apt/sources.list.d/*
		cat > /etc/apt/sources.list <<-EOF
		deb http://archive.debian.org/debian bullseye main
		deb http://archive.debian.org/debian-security bullseye-security main
		EOF
	fi
	apt-get update -qq
	apt-get install -y -qq build-essential curl ca-certificates kmod bc "$@" >/dev/null
}

vanilla() { # version
	v=$1
	apt_setup flex bison libelf-dev libssl-dev xz-utils cpio python3
	cd /tmp
	curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v${v%%.*}.x/linux-$v.tar.xz" | tar xJf -
	cd "linux-$v"
	make -s defconfig
	./scripts/config -e MEDIA_SUPPORT -e MEDIA_DIGITAL_TV_SUPPORT -e DVB_CORE \
		-e MEDIA_USB_SUPPORT -e MEDIA_SUBDRV_AUTOSELECT -m DVB_USB_V2 \
		-m DVB_LGDT330X -m MEDIA_TUNER_SIMPLE -e I2C -e USB -e RC_CORE
	make -s olddefconfig
	make -s -j"$(nproc)" modules_prepare
	KDIRS=$PWD
	export KBUILD_MODPOST_WARN=1	# dvb_usb_v2 itself is not built here
}

case $T in
ubuntu-18.04)     apt_setup linux-headers-generic ;;
ubuntu-18.04-hwe) apt_setup linux-headers-generic-hwe-18.04 ;;
ubuntu-20.04|ubuntu-22.04|ubuntu-24.04) apt_setup linux-headers-generic ;;
debian-*)         apt_setup linux-headers-amd64 ;;
fedora)
	dnf -q -y install make gcc curl kmod kernel-devel elfutils-libelf-devel >/dev/null
	;;
vanilla-*)        vanilla "${T#vanilla-}" ;;
*) echo "unknown target $T" >&2; exit 2 ;;
esac

if [ -z "${KDIRS:-}" ]; then
	KDIRS=$(ls -d /lib/modules/*/build /usr/src/kernels/* 2>/dev/null |
		while read -r d; do [ -f "$d/Makefile" ] && readlink -f "$d"; done | sort -u)
	[ -n "$KDIRS" ] || { echo "no kernel headers installed" >&2; exit 1; }
fi

status=0
for kdir in $KDIRS; do
	kver=$(cat "$kdir/include/config/kernel.release" 2>/dev/null ||
	       make -s --no-print-directory -C "$kdir" kernelrelease)
	# use the compiler the kernel was built with when it is installed
	cc=$(sed -n 's/^CONFIG_CC_VERSION_TEXT="\([^ ]*\) .*/\1/p' "$kdir/.config" 2>/dev/null || true)
	command -v "$cc" >/dev/null 2>&1 || cc=gcc
	rm -rf "$WORK"
	make -s -C "$SRC" dkms-src DEST="$WORK"
	echo "=== $T: building against $kver ($kdir) with $cc"
	rc=0
	make -C "$WORK" KVER="$kver" KDIR="$kdir" CC="$cc" > /tmp/build.log 2>&1 || rc=$?
	cat /tmp/build.log
	if [ $rc -eq 0 ] && [ -f "$WORK/dvb-usb-onairgt.ko" ] &&
	   ! grep -E "onairgt\.c:[0-9]+:[0-9]+: (warning|error)" /tmp/build.log; then
		modinfo "$WORK/dvb-usb-onairgt.ko" | grep -E '^(vermagic|depends)'
		echo "RESULT $T $kver PASS"
	else
		echo "RESULT $T $kver FAIL"
		status=1
	fi
done
exit $status
