# shellcheck shell=bash disable=SC2034
# Shared helpers for install.sh, uninstall.sh and onairgt-doctor.sh.
# Sourced, not executed.

ONAIR_USB_VID=11ba
ONAIR_USB_PID=1101
MOD_NAME=dvb-usb-onairgt          # .ko file name
MOD_KNAME=dvb_usb_onairgt         # name in lsmod and /sys/module
DKMS_NAME=onairgt                 # DKMS module name (dkms.conf PACKAGE_NAME)
DKMS_OLD_NAME=dvb-usb-onairgt     # DKMS name up to 0.2
PKG_NAME=onairgt-dkms             # .deb / .rpm package
FW_NAME=dvb-usb-onairgt-01.fw
STATE_DIR=/etc/onairgt
STATE_FILE=$STATE_DIR/install.conf
CRED_FILE=$STATE_DIR/tvheadend.cred
KVER=${KVER:-$(uname -r)}

# ---------------------------------------------------------------- output
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_RED=$(printf '\033[31m'); C_GRN=$(printf '\033[32m'); C_YEL=$(printf '\033[33m')
	C_BLU=$(printf '\033[34m'); C_BLD=$(printf '\033[1m'); C_OFF=$(printf '\033[0m')
else
	C_RED=; C_GRN=; C_YEL=; C_BLU=; C_BLD=; C_OFF=
fi

step() { printf '\n%s==> %s%s\n' "$C_BLD$C_BLU" "$*" "$C_OFF"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s  warning:%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
err()  { printf '%s  error:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die()  { err "$*"; exit 1; }

need_root() {
	[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ask "question" default(y|n) -> 0 for yes. Honors ASSUME_YES=1 (returns the default).
ask() {
	_q=$1 _def=${2:-y}
	if [ "${ASSUME_YES:-0}" = 1 ] || ! [ -r /dev/tty ]; then
		[ "$_def" = y ]
		return
	fi
	if [ "$_def" = y ]; then _p='[Y/n]'; else _p='[y/N]'; fi
	printf '%s %s ' "$_q" "$_p" >/dev/tty
	read -r _a </dev/tty || _a=
	case ${_a:-$_def} in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# prompt "question" default -> echoes answer
prompt() {
	if [ "${ASSUME_YES:-0}" = 1 ] || ! [ -r /dev/tty ]; then
		printf '%s\n' "$2"
		return
	fi
	printf '%s [%s]: ' "$1" "$2" >/dev/tty
	read -r _a </dev/tty || _a=
	printf '%s\n' "${_a:-$2}"
}

randpw() {
	tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "${1:-16}"
}

# ---------------------------------------------------------------- distro
# Sets DISTRO_ID, DISTRO_LIKE, DISTRO_NAME, DISTRO_VERSION, DISTRO_CODENAME, PKG.
detect_distro() {
	DISTRO_ID=unknown DISTRO_LIKE='' DISTRO_NAME=unknown DISTRO_VERSION='' DISTRO_CODENAME=''
	if [ -r /etc/os-release ]; then
		# shellcheck disable=SC1091
		DISTRO_ID=$(. /etc/os-release; printf '%s' "${ID:-unknown}")
		DISTRO_LIKE=$(. /etc/os-release; printf '%s' "${ID_LIKE:-}")
		DISTRO_NAME=$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-$ID}")
		DISTRO_VERSION=$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")
		DISTRO_CODENAME=$(. /etc/os-release; printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")
	fi
	PKG=unknown
	case " $DISTRO_ID $DISTRO_LIKE " in
	*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*|*" ol "*) PKG=dnf-el ;;
	*" debian "*|*" ubuntu "*|*" raspbian "*|*" linuxmint "*) PKG=apt ;;
	*" fedora "*) PKG=dnf ;;
	*" arch "*|*" manjaro "*|*" endeavouros "*) PKG=pacman ;;
	*" suse "*|*" opensuse "*|*" opensuse-leap "*|*" opensuse-tumbleweed "*|*" sles "*) PKG=zypper ;;
	esac
	if [ "$PKG" = unknown ]; then
		if have apt-get; then PKG=apt
		elif have dnf; then PKG=dnf
		elif have pacman; then PKG=pacman
		elif have zypper; then PKG=zypper
		fi
	fi
}

APT_UPDATED=0
pkg_refresh() {
	case $PKG in
	apt) [ "$APT_UPDATED" = 1 ] || { DEBIAN_FRONTEND=noninteractive apt-get update -qq && APT_UPDATED=1; } ;;
	esac
}

# pkg_install pkg... : install all, fail if any is missing
pkg_install() {
	[ $# -gt 0 ] || return 0
	case $PKG in
	apt)    pkg_refresh; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" ;;
	dnf|dnf-el) dnf install -y -q "$@" ;;
	pacman) pacman -S --needed --noconfirm "$@" ;;
	zypper) zypper --non-interactive install --no-recommends "$@" ;;
	*) return 1 ;;
	esac
}

# pkg_install_optional pkg... : install each one that is available, warn about the rest
pkg_install_optional() {
	for _p in "$@"; do
		pkg_install "$_p" >/dev/null 2>&1 || warn "optional package $_p not installed"
	done
}

pkg_available() {
	case $PKG in
	apt)    pkg_refresh; apt-cache policy "$1" 2>/dev/null | sed -n 's/^ *Candidate: *//p' | grep -qv '(none)' ;;
	dnf|dnf-el) dnf list -q "$1" >/dev/null 2>&1 ;;
	pacman) pacman -Si "$1" >/dev/null 2>&1 ;;
	zypper) zypper --non-interactive info "$1" 2>/dev/null | grep -q '^Name' ;;
	*) return 1 ;;
	esac
}

# ---------------------------------------------------------------- kernel / device
# kmod_exists name : module exists for $KVER (loadable or built in)
kmod_exists() {
	modinfo -k "$KVER" "$1" >/dev/null 2>&1 && return 0
	_f=$(printf '%s' "$1" | tr _ -)
	_u=$(printf '%s' "$1" | tr - _)
	grep -qE "/($_f|$_u)\.ko" "/lib/modules/$KVER/modules.builtin" 2>/dev/null
}

# Kernel modules the driver depends on.
missing_kernel_dvb() {
	for _m in dvb_core dvb_usb_v2 lgdt330x tuner_simple; do
		kmod_exists "$_m" || printf '%s ' "$_m"
	done
}

usb_device_present() {
	for _d in /sys/bus/usb/devices/*; do
		[ -r "$_d/idVendor" ] || continue
		[ "$(cat "$_d/idVendor")" = "$ONAIR_USB_VID" ] && [ "$(cat "$_d/idProduct")" = "$ONAIR_USB_PID" ] && return 0
	done
	return 1
}

# Echo the adapter numbers whose frontend belongs to the OnAir GT.
onair_adapters() {
	for _fe in /sys/class/dvb/dvb*.frontend0; do
		[ -e "$_fe" ] || continue
		_dev=$(readlink -f "$_fe/device")
		while [ -n "$_dev" ] && [ "$_dev" != / ] && [ ! -r "$_dev/idVendor" ]; do
			_dev=${_dev%/*}
		done
		[ -r "$_dev/idVendor" ] || continue
		if [ "$(cat "$_dev/idVendor")" = "$ONAIR_USB_VID" ] && [ "$(cat "$_dev/idProduct")" = "$ONAIR_USB_PID" ]; then
			_n=${_fe##*/dvb}
			printf '%s\n' "${_n%%.*}"
		fi
	done
}

dkms_version() {
	sed -n 's/^PACKAGE_VERSION="*\([^"]*\)"*$/\1/p' "$1/dkms.conf"
}

# dkms_versions name : versions of DKMS module <name> that DKMS knows about
dkms_versions() {
	dkms status -m "$1" 2>/dev/null | sed -n "s|^$1[/,] *\([^,:]*\).*|\1|p" | sort -u
}

# The onairgt-dkms .deb/.rpm is installed (it owns the DKMS registration).
dkms_pkg_installed() {
	if have dpkg-query; then
		# shellcheck disable=SC2016
		dpkg-query -W -f '${Status}' "$PKG_NAME" 2>/dev/null | grep -q ' installed$' && return 0
	fi
	have rpm && rpm -q "$PKG_NAME" >/dev/null 2>&1
}

# ---------------------------------------------------------------- state
state_get() {
	[ -r "$STATE_FILE" ] || return 0
	sed -n "s/^$1=//p" "$STATE_FILE" | tail -n 1
}

state_set() {
	mkdir -p "$STATE_DIR"
	touch "$STATE_FILE"
	chmod 0644 "$STATE_FILE"
	_tmp=$(mktemp)
	grep -v "^$1=" "$STATE_FILE" >"$_tmp" || true
	printf '%s=%s\n' "$1" "$2" >>"$_tmp"
	cat "$_tmp" >"$STATE_FILE"
	rm -f "$_tmp"
}

# ---------------------------------------------------------------- tvheadend
TVH_PORT=${TVH_PORT:-9981}
TVH_CONTAINER=${TVH_CONTAINER:-tvheadend}

tvh_url() { printf 'http://127.0.0.1:%s' "${TVH_PORT}"; }

# Load saved admin credentials into TVH_USER/TVH_PASS if not already set.
tvh_load_creds() {
	[ -r "$CRED_FILE" ] || return 0
	[ -n "${TVH_USER:-}" ] || TVH_USER=$(sed -n 's/^user=//p' "$CRED_FILE")
	[ -n "${TVH_PASS:-}" ] || TVH_PASS=$(sed -n 's/^pass=//p' "$CRED_FILE")
}

tvh_save_creds() {
	mkdir -p "$STATE_DIR"
	( umask 077; printf 'user=%s\npass=%s\n' "$1" "$2" >"$CRED_FILE" )
}

# tvh_api path [curl args...] : POST to the JSON API with the saved credentials
tvh_api() {
	_path=$1; shift
	if [ -n "${TVH_USER:-}" ]; then
		curl -fsS --max-time 10 --digest -u "$TVH_USER:$TVH_PASS" "$@" "$(tvh_url)/api/$_path" 2>/dev/null
	else
		curl -fsS --max-time 10 "$@" "$(tvh_url)/api/$_path" 2>/dev/null
	fi
}

tvh_reachable() {
	curl -s -o /dev/null --max-time 5 "$(tvh_url)/" 2>/dev/null
}

# Number of active viewer subscriptions (anything except scan/epggrab/keep).
# Prints "?" when the API is not accessible.
tvh_viewer_count() {
	_j=$(tvh_api status/subscriptions) || { echo '?'; return; }
	printf '%s' "$_j" | python3 -c '
import json, sys
e = json.load(sys.stdin).get("entries", [])
print(sum(1 for s in e if str(s.get("title", "")).lower() not in ("scan", "epggrab", "keep")))
' 2>/dev/null || echo '?'
}

# How tvheadend is installed: native | docker | none
tvh_kind() {
	_k=$(state_get tvh_kind)
	if [ -n "$_k" ]; then printf '%s\n' "$_k"; return; fi
	if have docker && docker inspect "$TVH_CONTAINER" >/dev/null 2>&1; then echo docker; return; fi
	if systemctl cat tvheadend.service >/dev/null 2>&1 || have tvheadend; then echo native; return; fi
	echo none
}

tvh_stop() {
	case $(tvh_kind) in
	docker) docker stop "$TVH_CONTAINER" >/dev/null 2>&1 || true ;;
	native) systemctl stop tvheadend.service 2>/dev/null || true ;;
	esac
}

tvh_start() {
	case $(tvh_kind) in
	docker) docker start "$TVH_CONTAINER" >/dev/null ;;
	native) systemctl start tvheadend.service ;;
	esac
}

tvh_is_running() {
	case $(tvh_kind) in
	docker) [ "$(docker inspect -f '{{.State.Running}}' "$TVH_CONTAINER" 2>/dev/null)" = true ] ;;
	native) systemctl is-active --quiet tvheadend.service ;;
	*) return 1 ;;
	esac
}

tvh_wait_up() {
	_i=0
	while [ $_i -lt "${1:-60}" ]; do
		tvh_reachable && return 0
		sleep 1
		_i=$((_i + 1))
	done
	return 1
}

# Wait until no viewer is watching, so tvheadend/module can be restarted.
# Returns 1 if somebody is still watching after the timeout.
tvh_wait_idle() {
	_t=${1:-0}
	tvh_reachable || return 0
	while :; do
		_n=$(tvh_viewer_count)
		case $_n in
		0) return 0 ;;
		'?')
			warn "cannot check TVHeadend for active viewers (no admin credentials)"
			ask "Restart TVHeadend / reload the driver anyway?" y
			return ;;
		esac
		[ "$_t" -gt 0 ] || return 1
		info "tvheadend has $_n active viewer subscription(s); waiting..."
		sleep 30
		_t=$((_t - 30))
	done
}
