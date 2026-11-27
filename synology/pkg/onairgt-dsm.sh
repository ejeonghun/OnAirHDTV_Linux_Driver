#!/bin/sh
# OnAir GT DVB driver loader for Synology DSM / Xpenology (EXPERIMENTAL).
#
# usage: onairgt-dsm.sh start|stop|restart|status|nodes|ready
#   start    load DSM-provided dependencies, then the bundled modules in
#            modules.load order, and make sure /dev/dvb nodes exist
#   stop     unload the bundled modules (reverse order)
#   nodes    (re)create /dev/dvb/adapterN/* from sysfs if udev/devtmpfs did not
#
# Run as root. Settings: onairgt.conf next to this script (ONAIRGT_OPTS,
# DVB_MODE). Idempotent: modules that are already loaded are skipped.
PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin
DIR=$(cd "$(dirname "$0")" && pwd)
FW_NAME=dvb-usb-onairgt-01.fw
TAG=onairgt-dsm

ONAIRGT_OPTS=""
DVB_MODE=0666
[ -f "$DIR/onairgt.conf" ] && . "$DIR/onairgt.conf"

say() { echo "$TAG: $*"; logger -t "$TAG" "$*" 2>/dev/null; }
loaded() { [ -d "/sys/module/$(echo "$1" | tr - _)" ]; }
buildinfo() { sed -n "s/^$1=//p" "$DIR/BUILDINFO"; }

check_kernel() {
	want=$(buildinfo kernel_release)
	plat=$(buildinfo platform)
	have=$(sed -n 's/^unique="synology_\([^_]*\)_.*/\1/p' /etc.defaults/synoinfo.conf 2>/dev/null)
	if { [ "$(uname -r)" != "$want" ] || [ "$have" != "$plat" ]; } && [ "${FORCE:-0}" != 1 ]; then
		say "system ${have:-unknown}/$(uname -r) != bundle $plat/$want; refusing (FORCE=1 overrides)"
		exit 1
	fi
}

firmware() {
	# DSM updates can reset /lib/firmware; restore our copy
	if [ ! -f "/lib/firmware/$FW_NAME" ] && [ -f "$DIR/firmware/$FW_NAME" ]; then
		cp "$DIR/firmware/$FW_NAME" "/lib/firmware/$FW_NAME" && say "restored /lib/firmware/$FW_NAME"
	fi
	# optional: only blank-EEPROM units need the host to upload the FX2 firmware
	return 0
}

udev_rule() {
	for d in /usr/lib/udev/rules.d /lib/udev/rules.d /etc/udev/rules.d; do
		[ -d "$d" ] || continue
		rule="$d/99-onairgt-dvb.rules"
		line="SUBSYSTEM==\"dvb\", MODE=\"$DVB_MODE\""
		if [ "$(cat "$rule" 2>/dev/null)" != "$line" ]; then
			echo "$line" > "$rule" && udevadm control --reload-rules 2>/dev/null
		fi
		return
	done
}

# Match the USB ancestry, not stale nodes or an unrelated DVB tuner.
onair_frontend() {
	for f in /sys/class/dvb/*frontend*; do
		[ -e "$f" ] || continue
		p=$(readlink -f "$f") || continue
		while [ "$p" != / ] && [ -n "$p" ]; do
			if [ -r "$p/idVendor" ] && [ -r "$p/idProduct" ] &&
			   [ "$(cat "$p/idVendor")" = 11ba ] &&
			   [ "$(cat "$p/idProduct")" = 1101 ]; then
				printf '%s\n' "$f"
				return 0
			fi
			p=$(dirname "$p")
		done
	done
	return 1
}

have_frontend() { onair_frontend >/dev/null; }

ready() {
	f=$(onair_frontend) || return 1
	node=$(sed -n 's/^DEVNAME=//p' "$f/uevent")
	case "$node" in dvb/adapter*/frontend*) ;; *) return 1 ;; esac
	dir="/dev/$(dirname "$node")"
	[ -c "/dev/$node" ] && [ -c "$dir/demux0" ] &&
	[ -c "$dir/dvr0" ] && [ -c "$dir/net0" ]
}

nodes() {
	n=0
	for u in /sys/class/dvb/*/uevent; do
		[ -f "$u" ] || continue
		MAJOR=$(sed -n 's/^MAJOR=//p' "$u")
		MINOR=$(sed -n 's/^MINOR=//p' "$u")
		DEVNAME=$(sed -n 's/^DEVNAME=//p' "$u")
		[ -n "$DEVNAME" ] && [ -n "$MAJOR" ] || continue
		if [ ! -c "/dev/$DEVNAME" ]; then
			mkdir -p "/dev/$(dirname "$DEVNAME")"
			mknod "/dev/$DEVNAME" c "$MAJOR" "$MINOR"
		fi
		chmod "$DVB_MODE" "/dev/$DEVNAME"
		n=$((n + 1))
	done
	say "$n DVB device node(s) under /dev/dvb"
}

start() {
	check_kernel
	firmware
	while read -r kind name extra; do
		case $kind in
		dsm)
			loaded "$name" && continue
			if modprobe "$name" 2>/dev/null; then
				say "modprobe $name"
			elif [ -n "$extra" ] && [ -f "$DIR/$extra" ]; then
				insmod "$DIR/$extra" && say "insmod $extra (DSM has no $name)"
			else
				say "WARNING: DSM module $name not available"
			fi
			;;
		ko)
			loaded "$name" && continue
			opts=""
			[ "$name" = dvb-usb-onairgt ] && opts=$ONAIRGT_OPTS
			# shellcheck disable=SC2086
			insmod "$DIR/modules/$name.ko" $opts || { say "insmod $name failed, see dmesg"; exit 1; }
			say "insmod $name $opts"
			;;
		esac
	done < "$DIR/modules.load"
	udev_rule
	# the adapter appears after the firmware upload and USB re-enumeration
	i=0
	while [ $i -lt 20 ] && ! have_frontend; do
		sleep 1; i=$((i + 1))
	done
	nodes
	dmesg | grep -iE 'onairgt|dvb-usb|lgdt330x|dvb_usb_v2' | tail -n 15
	ready || { say "ERROR: OnAir GT frontend not ready; reset/reconnect USB before retrying"; return 1; }
}

stop() {
	for m in $(awk '$1 == "ko" { print $2 }' "$DIR/modules.load" | sed '1!G;h;$!d'); do
		if loaded "$m"; then
			rmmod "$m" || { say "ERROR: cannot unload $m; stop DVB users first"; return 1; }
			say "rmmod $m"
		fi
	done
	return 0
}

status() {
	echo "bundle: $(buildinfo platform) $(buildinfo kernel_release) / running: $(uname -r)"
	for m in $(awk '$1 == "dsm" || $1 == "ko" { print $2 }' "$DIR/modules.load"); do
		if loaded "$m"; then echo "  loaded   $m"; else echo "  missing  $m"; fi
	done
	ls -l /dev/dvb/*/ 2>/dev/null || echo "  no /dev/dvb nodes"
	dmesg | grep -iE 'onairgt|dvb' | tail -n 10
}

case ${1:-} in
start) start ;;
stop) stop ;;
restart) stop && start ;;
status) status ;;
nodes) nodes ;;
ready) ready ;;
*) echo "usage: $0 start|stop|restart|status|nodes|ready" >&2; exit 1 ;;
esac
