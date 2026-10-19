#!/usr/bin/env bash
# Remove the dvb-usb-onairgt driver and, optionally, the TVHeadend set up by install.sh.
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tools/lib.sh
. "$SCRIPT_DIR/lib.sh"

ASSUME_YES=0
PURGE_TVH=0
PURGE_DATA=0
KEEP_FW=0

usage() {
	cat <<EOF
Usage: sudo $0 [options]

Removes the dvb-usb-onairgt driver (all DKMS versions, old non-DKMS copies)
and the FX2 firmware file.

  --purge-tvh     also remove TVHeadend if install.sh installed it
                  (package + apt repo, docker container, or the source build)
  --purge-data    with --purge-tvh: also delete TVHeadend's configuration and
                  recordings directory (channels, users, EPG). Irreversible.
  --keep-firmware keep /lib/firmware/$FW_NAME
  -y, --yes       do not ask
  -h, --help      this help
EOF
}

while [ $# -gt 0 ]; do
	case $1 in
	--purge-tvh) PURGE_TVH=1 ;;
	--purge-data) PURGE_DATA=1 ;;
	--keep-firmware) KEEP_FW=1 ;;
	-y|--yes) ASSUME_YES=1 ;;
	-h|--help) usage; exit 0 ;;
	*) usage >&2; die "unknown option: $1" ;;
	esac
	shift
done
export ASSUME_YES
need_root "$@"
detect_distro
TVH_PORT=$(state_get tvh_port | grep . || echo 9981)
tvh_load_creds

what="the OnAir GT driver"
[ $PURGE_TVH = 0 ] || what="$what and TVHeadend"
ask "Remove $what?" y || exit 1

step "Unloading the driver"
if [ -d "/sys/module/$MOD_KNAME" ]; then
	tvh_wait_idle 0 || die "TVHeadend is streaming right now; stop watching and run again"
	was_running=0
	if tvh_is_running; then was_running=1; tvh_stop; fi
	modprobe -r "$MOD_NAME" 2>/dev/null || rmmod "$MOD_KNAME" || warn "could not unload $MOD_KNAME (in use?)"
	# attached with dvb_attach(), so modprobe -r does not take them along
	modprobe -r lgdt330x tuner_simple 2>/dev/null || true
	if [ $was_running = 1 ] && [ $PURGE_TVH = 0 ]; then tvh_start || true; fi
	ok "driver unloaded"
else
	ok "driver not loaded"
fi

step "Removing the driver"
names="$DKMS_NAME $DKMS_OLD_NAME"
copies="/lib/modules/*/updates/$MOD_NAME.ko* /lib/modules/*/updates/dkms/$MOD_NAME.ko* /lib/modules/*/extra/$MOD_NAME.ko*"
if dkms_pkg_installed; then
	# leave the package's files alone; only clean up what install.sh may have left
	warn "the $PKG_NAME package is installed; remove it with your package manager (apt remove / dnf remove $PKG_NAME)"
	names=$DKMS_OLD_NAME
	copies="/lib/modules/*/updates/$MOD_NAME.ko* /lib/modules/*/extra/$MOD_NAME.ko*"
fi
if have dkms; then
	for n in $names; do
		for v in $(dkms_versions "$n"); do
			dkms remove -m "$n" -v "$v" --all >/dev/null 2>&1 || true
			info "dkms remove $n/$v"
		done
	done
fi
for n in $names; do
	rm -rf /usr/src/"$n"-[0-9]*
done
# kernel-private headers cached by DKMS builds (dkms.conf)
dkms_pkg_installed || rm -rf /var/cache/onairgt
for f in $copies; do
	[ -e "$f" ] || continue
	rm -f "$f"
	info "removed $f"
done
for k in /lib/modules/*; do
	[ -d "$k/kernel" ] && depmod -a "${k##*/}" 2>/dev/null || true
done
if [ $KEEP_FW = 0 ] && [ -e "/lib/firmware/$FW_NAME" ]; then
	rm -f "/lib/firmware/$FW_NAME"
	info "removed /lib/firmware/$FW_NAME"
fi
ok "driver removed"

if [ $PURGE_TVH = 1 ]; then
	method=$(state_get tvh_method)
	step "Removing TVHeadend (${method:-not installed by install.sh})"
	case $method in
	package|repo)
		if [ $PURGE_DATA = 1 ]; then apt-get purge -y -qq tvheadend || true
		else apt-get remove -y -qq tvheadend || true
		fi
		rm -f /etc/apt/sources.list.d/tvheadend-tvheadend.list /usr/share/keyrings/tvheadend-tvheadend-archive-keyring.gpg
		[ $PURGE_DATA = 0 ] || rm -rf /var/lib/tvheadend /home/hts/.hts
		;;
	docker)
		docker rm -f "$TVH_CONTAINER" >/dev/null 2>&1 || true
		info "removed container $TVH_CONTAINER (image kept: docker rmi lscr.io/linuxserver/tvheadend)"
		cfg=$(state_get docker_config)
		if [ $PURGE_DATA = 1 ] && [ -n "$cfg" ]; then
			case $cfg in
			/?*/*) rm -rf "$cfg"; info "removed $cfg" ;;
			*) warn "refusing to remove unsafe docker config path: $cfg" ;;
			esac
		fi
		;;
	source)
		systemctl disable --now tvheadend.service >/dev/null 2>&1 || true
		unit=$(state_get tvh_unit)
		if [ -n "$unit" ] && grep -q 'Managed by OnAirHDTV_Linux_Driver' "$unit" 2>/dev/null; then
			rm -f "$unit"
			systemctl daemon-reload
		fi
		rm -f /usr/local/bin/tvheadend
		rm -rf /usr/local/share/tvheadend /usr/local/src/tvheadend
		[ $PURGE_DATA = 0 ] || rm -rf /var/lib/tvheadend
		;;
	*)
		warn "TVHeadend was not installed by install.sh; leaving it alone"
		;;
	esac
	if [ -n "$method" ]; then
		rm -f "$CRED_FILE"
		for k in tvh_method tvh_kind tvh_unit tvh_repo tvh_port tvh_preset docker_config; do
			[ -f "$STATE_FILE" ] && sed -i "/^$k=/d" "$STATE_FILE"
		done
		[ $PURGE_DATA = 1 ] || info "TVHeadend configuration was kept (use --purge-data to delete it)"
		ok "TVHeadend removed"
	fi
fi

for k in driver_method driver_version; do
	[ -f "$STATE_FILE" ] && sed -i "/^$k=/d" "$STATE_FILE"
done
if [ -f "$STATE_FILE" ] && ! grep -q . "$STATE_FILE"; then rm -f "$STATE_FILE"; fi
if [ -f "$STATE_FILE" ] && [ "$(grep -cv '^repo_dir=' "$STATE_FILE")" = 0 ] && [ ! -f "$CRED_FILE" ]; then
	rm -rf "$STATE_DIR"
fi
step "Done"
