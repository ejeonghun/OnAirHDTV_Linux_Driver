#!/bin/sh
# Install the OnAir GT DVB bundle on Synology DSM / Xpenology (EXPERIMENTAL).
#
# usage (as root, from the unpacked bundle directory):
#   ./install-dsm.sh [--firmware <onairgt_fx2.bin|OnAirGt64.sys|OnAirGt.sys>]
#                    [--prefix /usr/local/onairgt] [--no-start] [--force]
#
# Copies the bundle to the prefix, adds an rc.d hook and loads the modules
# once. --firmware is optional: units with a programmed EEPROM boot their own
# FX2 firmware; only blank-EEPROM units need it (extracted from your own
# Windows driver, it is not redistributable). For boot-time loading also add
# the Task Scheduler boot-up task printed at the end.
set -e
PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin
SRC=$(cd "$(dirname "$0")" && pwd)
PREFIX=/usr/local/onairgt
FW=""
START=1
FORCE=0

FW_NAME=dvb-usb-onairgt-01.fw
FW_SHA256=4a574e11e8d8460ce06e2512e9ae4b9303b2829649046e234212fc2734dcd143
FW_LEN=7168

while [ $# -gt 0 ]; do
	case $1 in
	--firmware) FW=$2; shift ;;
	--prefix) PREFIX=$2; shift ;;
	--no-start) START=0 ;;
	--force) FORCE=1 ;;
	*) sed -n '4,7p' "$0"; exit 1 ;;
	esac
	shift
done

[ "$(id -u)" = 0 ] || { echo "run as root (sudo -i)" >&2; exit 1; }

want=$(sed -n 's/^kernel_release=//p' "$SRC/BUILDINFO")
platform=$(sed -n 's/^platform=//p' "$SRC/BUILDINFO")
# synoinfo.conf: unique="synology_<platform>_<model>"
have=$(sed -n 's/^unique="synology_\([^_]*\)_.*/\1/p' /etc.defaults/synoinfo.conf 2>/dev/null || true)
if [ "$(uname -r)" != "$want" ] || [ "$have" != "$platform" ]; then
	echo "this bundle is for $platform / kernel $want; this system is ${have:-unknown} / $(uname -r)" >&2
	[ $FORCE = 1 ] || exit 1
fi
echo "OnAir GT DSM bundle for $platform / $want -- EXPERIMENTAL; see runtime verification notes"

# validate the firmware before touching the system
tmp=""
if [ -n "$FW" ]; then
	[ -f "$FW" ] || { echo "firmware source $FW not found" >&2; exit 1; }
	tmp=$(mktemp)
	trap 'rm -f "$tmp"' EXIT
	case "$(basename "$FW" | tr '[:upper:]' '[:lower:]')" in
	onairgt64.sys) dd if="$FW" of="$tmp" bs=1 skip=$((0x16360)) count=$FW_LEN 2>/dev/null ;;
	onairgt.sys)   dd if="$FW" of="$tmp" bs=1 skip=$((0x11e90)) count=$FW_LEN 2>/dev/null ;;
	*)             cp "$FW" "$tmp" ;;
	esac
	if [ "$(sha256sum "$tmp" | cut -d' ' -f1)" != "$FW_SHA256" ]; then
		echo "firmware checksum mismatch; nothing installed" >&2; exit 1
	fi
fi

mkdir -p "$PREFIX/firmware"
cp -R "$SRC/modules" "$SRC/fallback" "$SRC/modules.load" "$SRC/BUILDINFO" \
      "$SRC/onairgt-dsm.sh" "$SRC/uninstall-dsm.sh" "$PREFIX/"
[ -f "$PREFIX/onairgt.conf" ] || cat > "$PREFIX/onairgt.conf" <<'EOF'
# options passed to insmod dvb-usb-onairgt, e.g. "xfer=1" for bulk transfer
ONAIRGT_OPTS=""
# permissions of /dev/dvb/adapterN/* (0666 lets TVHeadend's user open them)
DVB_MODE=0666
EOF
chmod 755 "$PREFIX"/*.sh

if [ -n "$tmp" ]; then
	mkdir -p /lib/firmware
	cp "$tmp" "$PREFIX/firmware/$FW_NAME"
	cp "$tmp" "/lib/firmware/$FW_NAME"
	chmod 644 "$PREFIX/firmware/$FW_NAME" "/lib/firmware/$FW_NAME"
	echo "installed firmware $FW_NAME"
elif [ -f "/lib/firmware/$FW_NAME" ]; then
	cp "/lib/firmware/$FW_NAME" "$PREFIX/firmware/"
else
	echo "note: no firmware installed - only needed for blank-EEPROM units; most units work without it"
	echo "      (if dmesg shows a firmware request failing, rerun with --firmware <OnAirGt64.sys|onairgt_fx2.bin>)"
fi

# rc.d hook (DSM runs /usr/local/etc/rc.d/*.sh start at boot on many
# versions; the Task Scheduler task below is the documented way on DSM 7)
if [ -d /usr/local/etc/rc.d ] || mkdir -p /usr/local/etc/rc.d 2>/dev/null; then
	cat > /usr/local/etc/rc.d/onairgt-dvb.sh <<EOF
#!/bin/sh
case "\$1" in
start|stop) exec $PREFIX/onairgt-dsm.sh "\$1" ;;
esac
EOF
	chmod 755 /usr/local/etc/rc.d/onairgt-dvb.sh
fi

if [ "$START" = 1 ]; then
	"$PREFIX/onairgt-dsm.sh" start
fi

cat <<EOF

Installed to $PREFIX.
Boot-time loading (DSM 7): Control Panel > Task Scheduler > Create >
  Triggered Task > User-defined script, User: root, Event: Boot-up,
  Run command:  $PREFIX/onairgt-dsm.sh start
Status: $PREFIX/onairgt-dsm.sh status      Remove: $PREFIX/uninstall-dsm.sh
EOF
