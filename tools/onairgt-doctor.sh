#!/usr/bin/env bash
# Diagnostics for the OnAir GT USB HDTV driver. Paste the output into GitHub issues.
# Run with sudo for complete output (dmesg, DKMS logs, TVHeadend credentials).
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tools/lib.sh
. "$SCRIPT_DIR/lib.sh"

FREQ=
ADAPTER=
CHECK_TVH=1

usage() {
	cat <<EOF
Usage: sudo $0 [--freq MHZ] [--adapter N] [--no-tvh]

  --freq MHZ     also tune this ATSC 8VSB center frequency (e.g. 195) for
                 10 seconds and report lock, signal, C/N and errors.
                 Skipped while TVHeadend is using the tuner.
  --adapter N    DVB adapter number (default: the one of the OnAir GT)
  --no-tvh       skip the TVHeadend checks
EOF
}

while [ $# -gt 0 ]; do
	case $1 in
	--freq) FREQ=${2:?}; shift ;;
	--adapter) ADAPTER=${2:?}; shift ;;
	--no-tvh) CHECK_TVH=0 ;;
	-h|--help) usage; exit 0 ;;
	*) usage >&2; exit 1 ;;
	esac
	shift
done

section() { printf '\n### %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@" 2>&1 || printf '(exit %s)\n' "$?"; }
detect_distro

echo "onairgt-doctor $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
[ "$(id -u)" = 0 ] || echo "NOTE: not running as root; some checks are incomplete (use sudo)."

section "System"
echo "distro:  $DISTRO_NAME ($DISTRO_ID, pkg=$PKG)"
echo "kernel:  $(uname -srm)"
if have mokutil; then echo "secure boot: $(mokutil --sb-state 2>&1 | head -n 1)"; else echo "secure boot: unknown (no mokutil)"; fi
echo "headers: $([ -d "/lib/modules/$KVER/build" ] && echo "present" || echo "MISSING (/lib/modules/$KVER/build)")"
m=$(missing_kernel_dvb)
echo "kernel DVB modules: ${m:+MISSING: }${m:-dvb_core dvb_usb_v2 lgdt330x tuner_simple present}"
if [ -r "$STATE_FILE" ]; then echo "install state ($STATE_FILE):"; sed 's/^/  /' "$STATE_FILE"; fi

section "USB"
if have lsusb; then
	run lsusb -d "$ONAIR_USB_VID:"
else
	echo "lsusb not installed"
fi
found=0
for d in /sys/bus/usb/devices/*; do
	[ -r "$d/idVendor" ] || continue
	[ "$(cat "$d/idVendor")" = "$ONAIR_USB_VID" ] || continue
	found=1
	printf '%s: %s:%s bcdDevice=%s speed=%sMbit/s maxpower=%s product="%s"\n' "${d##*/}" \
		"$(cat "$d/idVendor")" "$(cat "$d/idProduct")" "$(cat "$d/bcdDevice" 2>/dev/null)" \
		"$(cat "$d/speed" 2>/dev/null)" "$(cat "$d/bMaxPower" 2>/dev/null)" "$(cat "$d/product" 2>/dev/null)"
	[ "$(cat "$d/speed" 2>/dev/null)" = 480 ] || echo "  WARNING: not a USB 2.0 high-speed link; the TS needs 480 Mbit/s"
	drv=$(readlink -f "$d/${d##*/}:1.0/driver" 2>/dev/null || true)
	echo "  interface driver: ${drv##*/}"
done
[ $found = 1 ] || echo "OnAir GT ($ONAIR_USB_VID:$ONAIR_USB_PID) NOT FOUND on USB"

section "Driver"
if have dkms; then run dkms status -m "$DKMS_NAME"; run dkms status -m "$DKMS_OLD_NAME"; else echo "dkms not installed"; fi
dkms_pkg_installed && echo "package: $PKG_NAME installed"
run modinfo -F filename "$MOD_NAME"
echo "module version: $(modinfo -F version "$MOD_NAME" 2>/dev/null | grep . || echo -) srcversion: $(modinfo -F srcversion "$MOD_NAME" 2>/dev/null | grep . || echo -)"
if [ -d "/sys/module/$MOD_KNAME" ]; then
	echo "loaded: yes (srcversion $(cat "/sys/module/$MOD_KNAME/srcversion" 2>/dev/null), refcnt $(cat "/sys/module/$MOD_KNAME/refcnt" 2>/dev/null))"
	for p in /sys/module/"$MOD_KNAME"/parameters/*; do
		[ -r "$p" ] && echo "  param ${p##*/}=$(cat "$p")"
	done
else
	echo "loaded: NO"
fi
lsmod | grep -E '^(dvb_usb_onairgt|dvb_usb_v2|dvb_core|lgdt330x|tuner_simple) ' || true
for f in /lib/modules/"$KVER"/updates/"$MOD_NAME".ko* /lib/modules/"$KVER"/extra/"$MOD_NAME".ko*; do
	[ -e "$f" ] && echo "old non-DKMS copy (may shadow DKMS): $f"
done
if [ -e "/lib/firmware/$FW_NAME" ]; then
	echo "firmware: /lib/firmware/$FW_NAME sha256 $(sha256sum "/lib/firmware/$FW_NAME" | cut -c1-16)..."
else
	echo "firmware: not installed (only needed by units that enumerate cold)"
fi
if [ "$(id -u)" = 0 ]; then
	for l in /var/lib/dkms/"$DKMS_NAME"/*/build/make.log /var/lib/dkms/"$DKMS_OLD_NAME"/*/build/make.log; do
		[ -r "$l" ] && grep -qiE ' error|Error [0-9]' "$l" && { echo "DKMS build errors in $l:"; grep -iE 'error' "$l" | tail -n 15; }
	done
fi

section "Kernel log"
if dmesg >/dev/null 2>&1; then
	dmesg | grep -iE 'onair|dvb|lgdt|tuner-simple|tuner_simple|11ba|Key was rejected|module verification' | tail -n 40 || echo "(no matching messages)"
else
	echo "dmesg not readable (run with sudo)"
fi

section "/dev/dvb"
if [ -d /dev/dvb ]; then
	ls -l /dev/dvb/* 2>&1
else
	echo "/dev/dvb does not exist"
fi
ads=$(onair_adapters | tr '\n' ' ')
echo "OnAir GT adapter(s): ${ads:-none}"
[ -n "$ADAPTER" ] || ADAPTER=${ads%% *}
if [ -n "$ADAPTER" ]; then
	fe=/dev/dvb/adapter$ADAPTER/frontend0
	if have fuser; then
		users=$(fuser "$fe" "/dev/dvb/adapter$ADAPTER/dvr0" 2>/dev/null | tr -s ' ' '\n' | grep . | sort -u | tr '\n' ' ' || true)
		echo "processes using adapter$ADAPTER: ${users:-none}"
		for p in $users; do echo "  $p: $(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | cut -c1-120)"; done
	fi
	if have dvb-fe-tool; then
		run dvb-fe-tool -a "$ADAPTER"
	else
		echo "dvb-fe-tool not installed (package dvb-tools or v4l-utils)"
	fi
fi

if [ -n "$FREQ" ] && [ -n "$ADAPTER" ]; then
	section "Signal check at $FREQ MHz"
	if ! have dvbv5-zap; then
		echo "dvbv5-zap not installed (package dvb-tools or v4l-utils)"
	elif have fuser && fuser "/dev/dvb/adapter$ADAPTER/frontend0" >/dev/null 2>&1; then
		echo "tuner busy (TVHeadend?); stop it first or look at TVHeadend > Status > Stream"
	else
		hz=$(awk -v f="$FREQ" 'BEGIN { printf "%d", (f < 10000 ? f * 1000000 : f) }')
		conf=$(mktemp)
		printf '[onairgt-test]\n\tDELIVERY_SYSTEM = ATSC\n\tFREQUENCY = %s\n\tMODULATION = VSB/8\n\tINVERSION = AUTO\n' "$hz" >"$conf"
		timeout 15 dvbv5-zap -a "$ADAPTER" -c "$conf" -t 10 -m onairgt-test 2>&1 | tail -n 15 || true
		rm -f "$conf"
	fi
fi

if [ $CHECK_TVH = 1 ]; then
	section "TVHeadend"
	TVH_PORT=$(state_get tvh_port | grep . || echo 9981)
	echo "installed as: $(tvh_kind)  method: $(state_get tvh_method | grep . || echo unknown)"
	case $(tvh_kind) in
	native)
		systemctl --no-pager -n 0 status tvheadend.service 2>&1 | sed -n '1,5p' || true
		echo "ExecStart: $(systemctl show -p ExecStart --value tvheadend.service 2>/dev/null | sed -n 's/.*argv\[\]=\([^;]*\);.*/\1/p')"
		;;
	docker)
		docker ps -a --filter "name=^$TVH_CONTAINER\$" --format '{{.Names}} {{.Image}} {{.Status}}' 2>&1 || true
		echo "devices: $(docker inspect -f '{{range .HostConfig.Devices}}{{.PathOnHost}} {{end}}' "$TVH_CONTAINER" 2>/dev/null)"
		;;
	esac
	if tvh_reachable; then
		echo "web UI: $(tvh_url)/ reachable"
		tvh_load_creds
		if have python3; then
			TVH_USER=${TVH_USER:-} TVH_PASS=${TVH_PASS:-} python3 "$SCRIPT_DIR/tvh-setup.py" --url "$(tvh_url)" status || true
		fi
	else
		echo "web UI: $(tvh_url)/ NOT reachable"
	fi
fi
echo
echo "(end of report)"
