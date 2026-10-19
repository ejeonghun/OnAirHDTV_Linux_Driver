#!/bin/sh
# Resolve the kernel-private headers dvb-usb-onairgt needs and print the
# compiler -I flags for them.
#
# usage: kheaders.sh <kernel build dir> <cache dir>
#
# dvb_usb.h, lgdt330x.h and tuner-simple.h (and, before Linux 4.16, the
# dvb-core headers) live under drivers/media/ and are not shipped in distro
# kernel-header packages. Their structures must match the running
# dvb_usb_v2/lgdt330x modules exactly; a mismatch corrupts memory silently.
#
# Order:
#   1. the kernel build dir is a full source tree: use its own headers
#   2. cached copy for the kernel's upstream version
#   3. download from kernel.org stable for vX.Y.Z, then vX.Y
#   4. offline: the bundled Linux 7.0 copies, only for kernels whose layouts
#      match them (5.5 and later), with a warning
set -eu

KDIR=$1
CACHE=$2
HERE=$(cd "$(dirname "$0")" && pwd)
URL=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain

say() { echo "kheaders: $*" >&2; }
die() { say "error: $*"; exit 1; }

# 1. full source tree (also how in-tree / Synology builds see it)
if [ -f "$KDIR/drivers/media/usb/dvb-usb-v2/dvb_usb.h" ]; then
	say "using the headers of the kernel source tree $KDIR"
	m=$KDIR/drivers/media
	echo "-I$m/usb/dvb-usb-v2 -I$m/dvb-frontends -I$m/tuners -I$m/dvb-core"
	exit 0
fi

# upstream version of the target kernel. Ubuntu keeps SUBLEVEL at 0 in its
# Makefile and records the stable base in /proc/version_signature (running
# kernel only); everyone else has the real X.Y.Z in the Makefile.
kver=$(MAKEFLAGS='' MAKELEVEL='' make -s --no-print-directory -C "$KDIR" kernelversion 2>/dev/null |
	grep -E '^[0-9]+\.[0-9]+' | tail -n 1) || die "cannot read the kernel version from $KDIR"
case $kver in
[0-9]*.[0-9]*.[0-9]*) ;;
*) die "unexpected kernel version '$kver' from $KDIR" ;;
esac
if [ -r /proc/version_signature ] && [ "${KVER:-}" = "$(uname -r)" ]; then
	sig=$(awk '{print $NF}' /proc/version_signature)
	case $sig in "${kver%.*}".*) kver=$sig ;; esac
fi
major=${kver%%.*}
rest=${kver#*.}
minor=${rest%%.*}
sub=${rest#*.}
sub=${sub%%[!0-9]*}
xy=$major.$minor
code=$((major * 65536 + minor * 256))

files="drivers/media/usb/dvb-usb-v2/dvb_usb.h:struct dvb_usb_device_properties
drivers/media/dvb-frontends/lgdt330x.h:lgdt330x_attach
drivers/media/tuners/tuner-simple.h:simple_tuner_attach"
if [ $code -lt $((4 * 65536 + 16 * 256)) ]; then
	# before 4.16 dvb_usb.h includes "dvb_frontend.h" etc. from dvb-core
	for f in dvb_frontend.h dvb_demux.h dvb_net.h dmxdev.h dvbdev.h demux.h \
		 dvb_ringbuffer.h dvb_math.h dvb-usb-ids.h; do
		files="$files
drivers/media/dvb-core/$f:#"
	done
fi

fetch() { # url out
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 2 --connect-timeout 15 -o "$2" "$1"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -T 15 -O "$2" "$1"
	else
		return 1
	fi
}

download() { # tag dir
	tmp=$2.tmp.$$
	rm -rf "$tmp"
	mkdir -p "$tmp"
	echo "$files" | while IFS=: read -r path marker; do
		out=$tmp/$(basename "$path")
		fetch "$URL/$path?h=$1" "$out" || exit 1
		# cgit answers unknown tags with an HTML page; check the content
		if head -c 200 "$out" | grep -qi '<html\|<!doctype' ||
		   ! grep -q -- "$marker" "$out"; then
			say "unexpected content for $path at $1"
			exit 1
		fi
	done || { rm -rf "$tmp"; return 1; }
	{
		echo "tag $1"
		echo "source $URL"
		(cd "$tmp" && sha256sum -- *.h)
	} > "$tmp/MANIFEST"
	rm -rf "$2"
	mv "$tmp" "$2"
}

# 2./3. cache or download
tags=v$xy
[ -n "$sub" ] && [ "$sub" != 0 ] && tags="v$xy.$sub $tags"
for tag in $tags; do
	dir=$CACHE/$tag
	if [ -f "$dir/MANIFEST" ] && (cd "$dir" && sed -n '3,$p' MANIFEST | sha256sum -c --quiet -) >/dev/null 2>&1; then
		say "using cached $tag headers ($dir)"
		echo "-I$dir"
		exit 0
	fi
done
for tag in $tags; do
	dir=$CACHE/$tag
	say "fetching $tag headers from kernel.org"
	if download "$tag" "$dir"; then
		echo "-I$dir"
		exit 0
	fi
done

# 4. offline fallback
fb=$HERE/fallback-kheaders
if [ $code -ge $((5 * 65536 + 5 * 256)) ]; then
	say "**************************************************************"
	say "WARNING: could not download the headers for Linux $kver."
	say "Using the bundled Linux 7.0 copies. Their structures are"
	say "identical from 5.5 to 7.0; for newer kernels this is a guess."
	say "Rebuild with network access to be safe."
	say "**************************************************************"
	echo "-I$fb"
	exit 0
fi
die "could not download the headers for Linux $kver (tried: $tags) and the bundled copies do not match kernels older than 5.5. Connect to the network, or set KDIR to a full kernel source tree."
