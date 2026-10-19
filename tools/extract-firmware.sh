#!/bin/sh
# Extract the OnAir GT FX2 firmware from the Windows driver and install it as
# /lib/firmware/dvb-usb-onairgt-01.fw.
#
# Only needed for units that boot "cold" (no firmware in EEPROM). Units that
# enumerate warm work without it. The firmware is proprietary and is not
# shipped in this repository.
set -eu

FW_NAME=dvb-usb-onairgt-01.fw
FW_SHA256=4a574e11e8d8460ce06e2512e9ae4b9303b2829649046e234212fc2734dcd143
FW_LEN=7168
FW_DIR=${FW_DIR:-/lib/firmware}

usage() {
	cat <<EOF
usage: sudo $0 [--check] <firmware source>

<firmware source> is one of:
  OnAirGt64.sys     Windows x64 driver (image at offset 0x16360)
  OnAirGt.sys       Windows x86 driver (image at offset 0x11e90)
  onairgt_fx2.bin   raw FX2 image (7168 bytes)

--check   verify the checksum only, do not install
Installs $FW_DIR/$FW_NAME after checking its SHA-256.
EOF
}

check=0
case ${1:-} in
-h|--help) usage; exit 0 ;;
--check) check=1; shift ;;
esac
src=${1:-}
if [ -z "$src" ] || [ ! -f "$src" ]; then
	usage >&2
	exit 1
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

case $(basename "$src" | tr '[:upper:]' '[:lower:]') in
onairgt64.sys) dd if="$src" of="$tmp" bs=1 skip=$((0x16360)) count=$FW_LEN 2>/dev/null ;;
onairgt.sys)   dd if="$src" of="$tmp" bs=1 skip=$((0x11e90)) count=$FW_LEN 2>/dev/null ;;
*)             cp "$src" "$tmp" ;;
esac

sum=$(sha256sum "$tmp" | cut -d' ' -f1)
if [ "$sum" != "$FW_SHA256" ]; then
	echo "firmware checksum mismatch ($sum); not installing" >&2
	echo "expected $FW_SHA256 (driver version with a different image is not supported)" >&2
	exit 1
fi
if [ $check = 1 ]; then
	echo "firmware image OK"
	exit 0
fi
mkdir -p "$FW_DIR"
install -m 0644 "$tmp" "$FW_DIR/$FW_NAME"
echo "installed $FW_DIR/$FW_NAME"
