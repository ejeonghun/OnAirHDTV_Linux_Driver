#!/usr/bin/env bash
# One-command installer for the OnAir GT USB HDTV (11ba:1101) Linux driver,
# with optional TVHeadend installation and automatic channel setup.
# Run as: sudo tools/install.sh [options]      (see --help)
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=tools/lib.sh
. "$SCRIPT_DIR/lib.sh"

ASSUME_YES=0
USE_DKMS=1
SKIP_DRIVER=0
FIRMWARE=
TVH_METHOD=
TVH_ADMIN_USER=
TVH_ADMIN_PASS=${TVH_ADMIN_PASS:-}
PRESET=
DO_SCAN=1
MAP_ENCRYPTED=0
SCAN_TIMEOUT=1800
DOCKER_CFG=/var/lib/tvheadend-docker
TVH_REBUILD=0
PW_GENERATED=0


usage() {
	cat <<EOF
Usage: sudo $0 [options]

Installs the dvb-usb-onairgt driver (DKMS) for the OnAir GT USB HDTV and,
optionally, TVHeadend with the tuner, an ATSC network and channels configured.

Driver:
  --no-dkms             build and install once with make (no automatic rebuild
                        after kernel updates)
  --skip-driver         do not build/install the driver (TVHeadend only)
  --firmware FILE       also install the FX2 firmware extracted from FILE
                        (OnAirGt64.sys, OnAirGt.sys or a raw image). Only needed
                        for units that enumerate "cold"; most do not.

TVHeadend:
  --tvh METHOD          auto | package | repo | docker | source | existing | none
                          package   distro package (apt only, if available)
                          repo      official tvheadend apt repo (cloudsmith)
                          docker    lscr.io/linuxserver/tvheadend, host network
                          source    build from git into /usr/local
                          existing  only configure the TVHeadend already installed
                          none      skip TVHeadend
                        default: existing if TVHeadend is found, otherwise auto
  --no-tvh              same as --tvh none
  --tvh-user USER       admin account to create (default: admin)
  --tvh-pass PASS       its password (or env TVH_ADMIN_PASS); prompted when
                        interactive, generated with --yes
  --tvh-port PORT       HTTP port (default 9981; HTSP is PORT+1)
  --docker-config DIR   config dir for the docker method (default $DOCKER_CFG)
  --tvh-rebuild         with --tvh source: rebuild even if already installed
  --preset NAME         frequency preset (default kr-cable-8vsb), see --list-presets
  --no-scan             create network and muxes but do not scan / map channels
  --scan-timeout SEC    max. time to wait for the scan (default $SCAN_TIMEOUT)
  --map-encrypted       also map services flagged as encrypted
  --list-presets        show the presets and exit

General:
  -y, --yes             non-interactive; accept the defaults
  -h, --help            this help

Re-running is safe: finished steps are detected and skipped.
EOF
}

list_presets() {
	cat <<EOF
kr-cable-8vsb        Korean cable, 8VSB, standard (STD) channel plan  [verified]
kr-cable-8vsb-hrc    Korean cable, 8VSB, HRC plan
kr-cable-8vsb-irc    Korean cable, 8VSB, IRC plan
kr-atsc-terrestrial  Korean over-the-air ATSC 1.0, UHF 14-51
us-atsc-terrestrial  US over-the-air ATSC 1.0, VHF 2-13 + UHF 14-36
us-cable-8vsb        US cable 8VSB, STD plan (same table as kr-cable-8vsb)
us-cable-8vsb-hrc    US cable 8VSB, HRC plan
us-cable-8vsb-irc    US cable 8VSB, IRC plan
<path>               any dvbv5 scan file with ATSC 8VSB channels
EOF
}

while [ $# -gt 0 ]; do
	case $1 in
	-y|--yes) ASSUME_YES=1 ;;
	--no-dkms) USE_DKMS=0 ;;
	--skip-driver) SKIP_DRIVER=1 ;;
	--firmware) FIRMWARE=${2:?--firmware needs a file}; shift ;;
	--tvh) TVH_METHOD=${2:?--tvh needs a method}; shift ;;
	--no-tvh) TVH_METHOD=none ;;
	--tvh-user) TVH_ADMIN_USER=${2:?}; shift ;;
	--tvh-pass) TVH_ADMIN_PASS=${2:?}; shift ;;
	--tvh-port) TVH_PORT=${2:?}; shift ;;
	--docker-config) DOCKER_CFG=${2:?}; shift ;;
	--tvh-rebuild) TVH_REBUILD=1 ;;
	--preset) PRESET=${2:?}; shift ;;
	--no-scan) DO_SCAN=0 ;;
	--scan-timeout) SCAN_TIMEOUT=${2:?}; shift ;;
	--map-encrypted) MAP_ENCRYPTED=1 ;;
	--list-presets) list_presets; exit 0 ;;
	-h|--help) usage; exit 0 ;;
	*) usage >&2; die "unknown option: $1" ;;
	esac
	shift
done
case ${TVH_METHOD:-auto} in
auto|package|repo|docker|source|existing|none) ;;
*) die "unknown --tvh method: $TVH_METHOD" ;;
esac
case $TVH_PORT in ''|*[!0-9]*) die "--tvh-port must be a number" ;; esac
export ASSUME_YES TVH_PORT

need_root "$@"
detect_distro

# ===================================================================== driver

preset_file() {
	case $1 in
	kr-cable-8vsb|kr-cable-8vsb-std|us-cable-8vsb|us-cable-8vsb-std) echo "$SCRIPT_DIR/scan-tables/kr-cable-8vsb-std" ;;
	us-cable-8vsb-hrc) echo "$SCRIPT_DIR/scan-tables/kr-cable-8vsb-hrc" ;;
	us-cable-8vsb-irc) echo "$SCRIPT_DIR/scan-tables/kr-cable-8vsb-irc" ;;
	*)
		if [ -f "$SCRIPT_DIR/scan-tables/$1" ]; then echo "$SCRIPT_DIR/scan-tables/$1"
		elif [ -f "$1" ]; then readlink -f "$1"
		else return 1
		fi ;;
	esac
}

el_no_dvb_help() {
	err "this kernel ($KVER) has no DVB support (missing: $1)"
	cat >&2 <<EOF

  RHEL / Rocky / AlmaLinux / Oracle Linux kernels are built without the DVB
  subsystem (dvb-core, dvb-usb-v2, lgdt330x, tuner-simple), so no out-of-tree
  driver can work on them. Options:
    * Install a mainline kernel from ELRepo (kernel-ml), which has DVB enabled:
        sudo dnf install https://www.elrepo.org/elrepo-release-\$(rpm -E %rhel).el\$(rpm -E %rhel).elrepo.noarch.rpm
        sudo dnf --enablerepo=elrepo-kernel install kernel-ml kernel-ml-devel
      reboot into it, then run this installer again.
    * Or use Fedora, Debian or Ubuntu for the TV server.
EOF
	exit 1
}

install_build_deps() {
	step "Installing build dependencies ($DISTRO_NAME, kernel $KVER)"
	case $PKG in
	apt)
		pkg_install build-essential kmod curl ca-certificates python3 usbutils \
			|| die "could not install the build tools"
		if pkg_available "linux-headers-$KVER"; then
			pkg_install "linux-headers-$KVER"
		elif pkg_available raspberrypi-kernel-headers; then
			pkg_install raspberrypi-kernel-headers
		elif [ ! -d "/lib/modules/$KVER/build" ]; then
			die "no headers package for kernel $KVER. Run 'sudo apt full-upgrade', reboot, and try again."
		fi
		# Ubuntu ships most DVB drivers in linux-modules-extra
		if [ -n "$(missing_kernel_dvb)" ] && pkg_available "linux-modules-extra-$KVER"; then
			pkg_install "linux-modules-extra-$KVER"
		fi
		[ $USE_DKMS = 0 ] || pkg_install dkms
		pkg_install_optional dvb-tools
		;;
	dnf|dnf-el)
		[ "$PKG" = dnf-el ] && pkg_install_optional epel-release
		pkg_install gcc make kmod curl python3 usbutils elfutils-libelf-devel \
			|| die "could not install the build tools"
		pkg_install "kernel-devel-$KVER" || pkg_install "kernel-ml-devel-$KVER" || [ -d "/lib/modules/$KVER/build" ] \
			|| die "no kernel-devel for $KVER. Run 'sudo dnf upgrade', reboot, and try again."
		if [ -n "$(missing_kernel_dvb)" ]; then
			pkg_install_optional "kernel-modules-extra-$KVER"
		fi
		[ $USE_DKMS = 0 ] || pkg_install dkms || { warn "dkms not available; using --no-dkms"; USE_DKMS=0; }
		pkg_install_optional v4l-utils
		;;
	pacman)
		kpkg=$(pacman -Qqo "/usr/lib/modules/$KVER/vmlinuz" 2>/dev/null || echo linux)
		pkg_install base-devel kmod curl python usbutils "$kpkg-headers" \
			|| die "could not install base-devel/$kpkg-headers (is the system up to date? 'pacman -Syu' and reboot)"
		[ $USE_DKMS = 0 ] || pkg_install dkms
		pkg_install_optional v4l-utils
		;;
	zypper)
		flavor=${KVER##*-}
		pkg_install gcc make kmod curl python3 usbutils kernel-devel "kernel-$flavor-devel" \
			|| die "could not install compiler/kernel-devel"
		[ $USE_DKMS = 0 ] || pkg_install dkms || { warn "dkms not available; using --no-dkms"; USE_DKMS=0; }
		pkg_install_optional v4l-utils dvb
		;;
	*)
		warn "unknown distribution ($DISTRO_NAME); assuming gcc, make, kernel headers and dkms are installed"
		have dkms || USE_DKMS=0
		;;
	esac
	[ -d "/lib/modules/$KVER/build" ] || die "kernel headers for $KVER not found in /lib/modules/$KVER/build"
	missing=$(missing_kernel_dvb)
	if [ -n "$missing" ]; then
		[ "$PKG" = dnf-el ] && el_no_dvb_help "$missing"
		die "kernel $KVER lacks required DVB modules: $missing (CONFIG_DVB_CORE, CONFIG_DVB_USB_V2, CONFIG_DVB_LGDT330X, CONFIG_MEDIA_TUNER_SIMPLE)"
	fi
	ok "build dependencies present"
}

remove_legacy_modules() {
	# copies installed by the old install.sh / 'make install' shadow the DKMS module
	for f in /lib/modules/*/updates/"$MOD_NAME".ko* /lib/modules/*/extra/"$MOD_NAME".ko*; do
		[ -e "$f" ] || continue
		rm -f "$f"
		info "removed old non-DKMS module $f"
	done
}

install_driver_dkms() {
	ver=$(dkms_version "$REPO_DIR")
	[ -n "$ver" ] || die "cannot read PACKAGE_VERSION from $REPO_DIR/dkms.conf"
	src=/usr/src/$DKMS_NAME-$ver
	# build from a scratch copy so no root-owned files end up in the user's clone
	stage=$(mktemp -d)
	make -s -C "$REPO_DIR" dkms-src DEST="$stage" >/dev/null || { rm -rf "$stage"; die "cannot copy the driver source"; }
	# up to date if every file DKMS got is unchanged in the clone
	if [ -f "$src/dkms.conf" ] && (cd "$src" && find . -type f -print) \
		| while read -r f; do cmp -s "$src/$f" "$stage/$f" || exit 1; done \
		&& dkms status -m "$DKMS_NAME" -v "$ver" -k "$KVER" 2>/dev/null | grep -q installed; then
		rm -rf "$stage"
		ok "DKMS module $DKMS_NAME/$ver already installed for $KVER"
		return
	fi
	# remove every registered version, also stale ones from older checkouts
	# and the pre-0.3 name
	for n in "$DKMS_NAME" "$DKMS_OLD_NAME"; do
		for v in $(dkms_versions "$n"); do
			dkms remove -m "$n" -v "$v" --all >/dev/null 2>&1 || true
			rm -rf "/usr/src/$n-$v"
		done
	done
	# Makefile: copies the source to /usr/src, then dkms add/build/install
	# (the build fetches the kernel-private headers with kheaders.sh)
	if ! make -C "$stage" KVER="$KVER" dkms-install; then
		log=/var/lib/dkms/$DKMS_NAME/$ver/build/make.log
		[ -r "$log" ] && tail -n 40 "$log" >&2
		rm -rf "$stage"
		die "DKMS build failed (log: $log). Please report it with the output of tools/onairgt-doctor.sh"
	fi
	rm -rf "$stage"
	ok "DKMS module $DKMS_NAME/$ver built and installed for $KVER"
}

install_driver_make() {
	ver=$(dkms_version "$REPO_DIR")
	stage=$(mktemp -d)
	make -s -C "$REPO_DIR" dkms-src DEST="$stage" >/dev/null || { rm -rf "$stage"; die "cannot copy the driver source"; }
	make -C "$stage" KVER="$KVER" install || { rm -rf "$stage"; die "driver build failed"; }
	rm -rf "$stage"
	warn "installed without DKMS: re-run this installer after every kernel update"
	ok "driver $ver built and installed for $KVER"
}

sb_hint() {
	if have mokutil && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
		pub=
		for k in /var/lib/shim-signed/mok/MOK.der /var/lib/dkms/mok.pub; do
			[ -r "$k" ] && { pub=$k; break; }
		done
		warn "Secure Boot is enabled: the kernel only loads modules signed with an enrolled key."
		info "Enroll the DKMS signing key once, then reboot and choose 'Enroll MOK':"
		info "    sudo mokutil --import ${pub:-/var/lib/dkms/mok.pub}"
	fi
}

load_module() {
	step "Loading the driver"
	if [ -d "/sys/module/$MOD_KNAME" ]; then
		cur=$(cat "/sys/module/$MOD_KNAME/srcversion" 2>/dev/null || true)
		new=$(modinfo -k "$KVER" -F srcversion "$MOD_NAME" 2>/dev/null || true)
		if [ -n "$cur" ] && [ "$cur" = "$new" ]; then
			ok "$MOD_NAME already loaded (current build)"
		elif ! tvh_wait_idle 0; then
			warn "a newer driver was installed, but TVHeadend is streaming right now; not reloading."
			info "It is used after a reboot, or re-run this installer when nobody is watching."
		else
			was_running=0
			if tvh_is_running; then was_running=1; tvh_stop; fi
			modprobe -r "$MOD_NAME" || warn "could not unload the old driver (still in use?)"
			modprobe "$MOD_NAME" || { sb_hint; die "modprobe $MOD_NAME failed (see dmesg)"; }
			[ $was_running = 0 ] || tvh_start
			ok "$MOD_NAME reloaded"
		fi
	else
		modprobe "$MOD_NAME" || { sb_hint; die "modprobe $MOD_NAME failed (see 'dmesg | tail')"; }
		ok "$MOD_NAME loaded"
	fi

	if usb_device_present; then
		i=0
		while [ -z "$(onair_adapters)" ] && [ $i -lt 20 ]; do sleep 1; i=$((i + 1)); done
		ad=$(onair_adapters | head -n 1)
		if [ -n "$ad" ]; then
			ok "OnAir GT is /dev/dvb/adapter$ad"
		else
			warn "the device is plugged in but no /dev/dvb adapter appeared. Last kernel messages:"
			dmesg 2>/dev/null | grep -iE 'onair|dvb|lgdt|11ba' | tail -n 10 >&2 || true
			if dmesg 2>/dev/null | grep -q "$FW_NAME"; then
				info "This unit needs firmware: re-run with --firmware /path/to/OnAirGt64.sys"
			fi
			info "Try unplugging and re-plugging the device, then run tools/onairgt-doctor.sh"
		fi
	else
		info "OnAir GT (USB $ONAIR_USB_VID:$ONAIR_USB_PID) is not plugged in; plug it in to use it."
	fi
}

install_driver() {
	install_build_deps
	if [ -n "$FIRMWARE" ]; then
		step "Installing firmware"
		sh "$SCRIPT_DIR/extract-firmware.sh" "$FIRMWARE"
	fi
	step "Building and installing the driver"
	if dkms_pkg_installed; then
		# the package owns /usr/src/onairgt-<ver> and its DKMS registration
		ok "driver provided by the $PKG_NAME package; not rebuilding it (remove the package to use this checkout)"
		state_set driver_method package
		load_module
		return
	fi
	remove_legacy_modules
	if [ $USE_DKMS = 1 ]; then
		install_driver_dkms
		state_set driver_method dkms
	else
		install_driver_make
		state_set driver_method make
	fi
	state_set driver_version "$(dkms_version "$REPO_DIR")"
	depmod -a "$KVER"
	load_module
}

# ===================================================================== tvheadend

cloudsmith_dist() {
	# echo "<distro> <codename>" if the official repo has packages for this system
	base=https://dl.cloudsmith.io/public/tvheadend/tvheadend/deb
	cn=$DISTRO_CODENAME
	[ -n "$cn" ] || return 1
	for d in "$DISTRO_ID" $DISTRO_LIKE; do
		case $d in ubuntu|debian|raspbian) ;; *) continue ;; esac
		if curl -fsSL --max-time 15 -o /dev/null "$base/$d/dists/$cn/Release" 2>/dev/null; then
			echo "$d $cn"
			return 0
		fi
	done
	return 1
}

pick_tvh_method() {
	if [ "${TVH_METHOD:-auto}" = auto ] && [ "$(tvh_kind)" != none ]; then
		TVH_METHOD=existing
		info "TVHeadend is already installed ($(tvh_kind)); it will be configured, not reinstalled."
		return
	fi
	[ -n "$TVH_METHOD" ] && [ "$TVH_METHOD" != auto ] && return
	def=source
	case $PKG in
	apt)
		if pkg_available tvheadend; then def=package
		elif cloudsmith_dist >/dev/null; then def=repo
		fi ;;
	*) have docker && def=docker ;;
	esac
	if [ "$ASSUME_YES" = 1 ] || ! [ -r /dev/tty ]; then
		TVH_METHOD=$def
		return
	fi
	cat >/dev/tty <<EOF

TVHeadend (TV server with web UI, recording, Kodi/Jellyfin/Plex clients):
  1) package   distro package
  2) repo      official tvheadend apt repository (Debian/Ubuntu)
  3) docker    linuxserver/tvheadend container
  4) source    build from source (takes a few minutes)
  5) none      driver only
EOF
	while :; do
		a=$(prompt "Choose" "$def")
		case $a in
		1|package) TVH_METHOD=package ;; 2|repo) TVH_METHOD=repo ;; 3|docker) TVH_METHOD=docker ;;
		4|source) TVH_METHOD=source ;; 5|none) TVH_METHOD=none ;; *) continue ;;
		esac
		break
	done
}

tvh_fix_dvb_group() {
	id hts >/dev/null 2>&1 && getent group video >/dev/null && usermod -a -G video hts 2>/dev/null || true
}

install_tvh_package() {
	[ "$PKG" = apt ] || die "--tvh package is only supported on Debian/Ubuntu (try --tvh docker or --tvh source)"
	pkg_available tvheadend || die "no tvheadend package for $DISTRO_NAME (try --tvh repo, docker or source)"
	# Answer the package's debconf questions: it writes the account as the
	# tvheadend "superuser" (<config>/superuser), which also lets us in.
	printf 'tvheadend tvheadend/admin_username string %s\ntvheadend tvheadend/admin_password password %s\n' \
		"$TVH_ADMIN_USER" "$TVH_ADMIN_PASS" | debconf-set-selections
	pkg_install tvheadend || die "apt could not install tvheadend"
	if [ "$TVH_PORT" != 9981 ] && ! grep -q -- '--http_port' /etc/default/tvheadend; then
		sed -i "s/^OPTIONS=\"\(.*\)\"/OPTIONS=\"\1 --http_port $TVH_PORT --htsp_port $((TVH_PORT + 1))\"/" /etc/default/tvheadend
	fi
	tvh_fix_dvb_group
	systemctl enable tvheadend.service >/dev/null 2>&1 || true
	systemctl restart tvheadend.service
	state_set tvh_kind native
	ok "tvheadend package installed"
}

install_tvh_repo() {
	[ "$PKG" = apt ] || die "--tvh repo is only supported on Debian/Ubuntu"
	dist=$(cloudsmith_dist) || die "the official tvheadend repo has no packages for $DISTRO_NAME (try --tvh source or docker)"
	pkg_install ca-certificates curl gnupg
	key=/usr/share/keyrings/tvheadend-tvheadend-archive-keyring.gpg
	curl -fsSL https://dl.cloudsmith.io/public/tvheadend/tvheadend/gpg.C6CC06BD69B430C6.key | gpg --dearmor --yes -o "$key"
	chmod 0644 "$key"
	echo "deb [signed-by=$key] https://dl.cloudsmith.io/public/tvheadend/tvheadend/deb/${dist% *} ${dist#* } main" \
		>/etc/apt/sources.list.d/tvheadend-tvheadend.list
	APT_UPDATED=0
	install_tvh_package
	state_set tvh_repo "/etc/apt/sources.list.d/tvheadend-tvheadend.list"
}

ensure_docker() {
	if ! have docker; then
		info "installing Docker"
		case $PKG in
		apt) pkg_install docker.io ;;
		dnf) pkg_install moby-engine || pkg_install docker ;;
		pacman) pkg_install docker ;;
		zypper) pkg_install docker ;;
		*) die "install Docker first (https://docs.docker.com/engine/install/)" ;;
		esac
	fi
	systemctl enable --now docker >/dev/null 2>&1 || true
	docker info >/dev/null 2>&1 || die "docker is installed but not running"
}

install_tvh_docker() {
	ensure_docker
	img=lscr.io/linuxserver/tvheadend:latest
	mkdir -p "$DOCKER_CFG/config" "$DOCKER_CFG/recordings"
	vgid=$(getent group video | cut -d: -f3)
	dev_args=()
	if [ -d /dev/dvb ]; then
		dev_args=(--device /dev/dvb:/dev/dvb)
	else
		warn "/dev/dvb does not exist yet (device unplugged?); the container gets no tuner. Re-run after plugging in."
	fi
	if docker inspect "$TVH_CONTAINER" >/dev/null 2>&1; then
		ndev=$(docker inspect -f '{{len .HostConfig.Devices}}' "$TVH_CONTAINER")
		if [ "$ndev" = 0 ] && [ ${#dev_args[@]} -gt 0 ]; then
			info "re-creating the container to pass /dev/dvb"
			docker rm -f "$TVH_CONTAINER" >/dev/null
		else
			docker start "$TVH_CONTAINER" >/dev/null
			state_set tvh_kind docker
			state_set docker_config "$DOCKER_CFG"
			ok "container $TVH_CONTAINER exists"
			return
		fi
	fi
	docker pull -q "$img" >/dev/null
	tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)
	docker run -d --name "$TVH_CONTAINER" --network host --restart unless-stopped \
		-e PUID=911 -e PGID="${vgid:-44}" -e TZ="$tz" \
		-e RUN_OPTS="--http_port $TVH_PORT --htsp_port $((TVH_PORT + 1))" \
		-v "$DOCKER_CFG/config:/config" -v "$DOCKER_CFG/recordings:/recordings" \
		"${dev_args[@]}" "$img" >/dev/null
	state_set tvh_kind docker
	state_set docker_config "$DOCKER_CFG"
	ok "container $TVH_CONTAINER started ($img)"
}

install_tvh_source() {
	if [ -x /usr/local/bin/tvheadend ] && [ $TVH_REBUILD = 0 ]; then
		ok "/usr/local/bin/tvheadend already built (use --tvh-rebuild to rebuild)"
	else
		info "installing build dependencies"
		case $PKG in
		apt)
			pkg_install build-essential git cmake gettext libssl-dev zlib1g-dev liburiparser-dev libpcre2-dev \
				libavahi-client-dev python3 bzip2 wget ca-certificates libsystemd-dev \
				|| die "could not install the tvheadend build dependencies"
			pkg_install pkgconf || pkg_install pkg-config
			pkg_install_optional python-is-python3 libdvbcsa-dev libavcodec-dev libavformat-dev libavutil-dev \
				libswscale-dev libavfilter-dev libswresample-dev libva-dev libopus-dev libvpx-dev libx264-dev libx265-dev ;;
		dnf|dnf-el)
			pkg_install gcc gcc-c++ make git cmake gettext openssl-devel zlib-devel uriparser-devel pcre2-devel \
				avahi-devel python3 bzip2 wget systemd-devel pkgconf-pkg-config \
				|| die "could not install the tvheadend build dependencies"
			pkg_install_optional libdvbcsa-devel ffmpeg-devel libva-devel ;;
		pacman)
			pkg_install base-devel git cmake gettext openssl zlib uriparser pcre2 avahi python bzip2 wget systemd \
				|| die "could not install the tvheadend build dependencies"
			pkg_install_optional ffmpeg libdvbcsa libva ;;
		zypper)
			pkg_install gcc gcc-c++ make git cmake gettext-tools libopenssl-devel zlib-devel uriparser-devel \
				pcre2-devel avahi-devel python3 bzip2 wget systemd-devel pkgconf \
				|| die "could not install the tvheadend build dependencies"
			pkg_install_optional libdvbcsa-devel ffmpeg-devel ;;
		*) die "--tvh source: unknown distribution, install the tvheadend build dependencies yourself" ;;
		esac
		srcdir=/usr/local/src/tvheadend
		if [ -d "$srcdir/.git" ]; then
			git -C "$srcdir" pull -q --ff-only || warn "git pull failed; building the existing checkout"
		else
			rm -rf "$srcdir"
			git clone -q --depth 1 https://github.com/tvheadend/tvheadend.git "$srcdir"
		fi
		flags=(--prefix=/usr/local --disable-ffmpeg_static --disable-hdhomerun_static --disable-hdhomerun_client
			--disable-libfdkaac_static --disable-libtheora_static --disable-libvorbis_static --disable-libvpx_static
			--disable-libx264_static --disable-libx265_static --disable-libopus_static --disable-bintray_cache
			--enable-dvbscan)
		pkg-config --exists libavcodec libavformat libswscale 2>/dev/null || flags+=(--disable-libav)
		pkg-config --exists libdvbcsa 2>/dev/null || [ -e /usr/include/dvbcsa/dvbcsa.h ] || flags+=(--disable-dvbcsa)
		info "building tvheadend (this takes a few minutes; log: $srcdir/build.log)"
		( cd "$srcdir" && ./configure "${flags[@]}" && make -j"$(nproc)" && make install ) >"$srcdir/build.log" 2>&1 \
			|| { tail -n 30 "$srcdir/build.log" >&2; die "tvheadend build failed (log: $srcdir/build.log)"; }
		ok "tvheadend built and installed to /usr/local"
	fi
	id hts >/dev/null 2>&1 || useradd --system --home-dir /var/lib/tvheadend --shell /usr/sbin/nologin --user-group hts
	tvh_fix_dvb_group
	cfgdir=/var/lib/tvheadend
	mkdir -p "$cfgdir/recordings"
	chown -R hts:hts "$cfgdir"
	unit=/etc/systemd/system/tvheadend.service
	cat >"$unit.new" <<EOF
# Managed by OnAirHDTV_Linux_Driver install.sh
[Unit]
Description=Tvheadend TV streaming server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=hts
Group=hts
SupplementaryGroups=video
ExecStart=/usr/local/bin/tvheadend -c $cfgdir --http_port $TVH_PORT --htsp_port $((TVH_PORT + 1))
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
	if ! cmp -s "$unit.new" "$unit"; then
		mv "$unit.new" "$unit"
		systemctl daemon-reload
		systemctl enable tvheadend.service >/dev/null 2>&1
		systemctl restart tvheadend.service
	else
		rm -f "$unit.new"
		systemctl enable --now tvheadend.service >/dev/null 2>&1
	fi
	state_set tvh_kind native
	state_set tvh_unit "$unit"
	ok "tvheadend service running (config in $cfgdir)"
}

# Config directory of the running tvheadend (needed for the superuser bootstrap).
tvh_config_dir() {
	if [ "$(tvh_kind)" = docker ]; then
		d=$(state_get docker_config)
		echo "${d:-$DOCKER_CFG}/config"
		return
	fi
	pid=$(systemctl show -p MainPID --value tvheadend.service 2>/dev/null || echo 0)
	[ "${pid:-0}" != 0 ] || pid=$(pgrep -x tvheadend | head -n 1 || true)
	[ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] || return 1
	mapfile -d '' -t argv <"/proc/$pid/cmdline"
	set -- "${argv[@]}"
	dir=
	while [ $# -gt 0 ]; do
		case $1 in -c|--config) dir=${2:-}; shift ;; --config=*) dir=${1#*=} ;; esac
		shift
	done
	if [ -n "$dir" ] && [ -d "$dir" ]; then echo "$dir"; return; fi
	# same order as config_get_dir() in tvheadend's src/config.c
	uid=$(stat -c %u "/proc/$pid")
	home=$(getent passwd "$uid" | cut -d: -f6)
	for d in /var/lib/tvheadend /etc/tvheadend; do
		if [ -d "$d" ] && [ "$(stat -L -c %u "$d")" = "$uid" ]; then echo "$d"; return; fi
	done
	if [ -d "$home/.hts/tvheadend" ]; then echo "$home/.hts/tvheadend"; else echo "$home/.config/hts"; fi
}

tvh_restart() {
	case $(tvh_kind) in
	docker) docker restart "$TVH_CONTAINER" >/dev/null ;;
	native) systemctl restart tvheadend.service ;;
	esac
	sleep 2
	tvh_wait_up 90 || die "tvheadend did not come back after restart"
}

# Remove -C/--firstrun from a native unit (it would re-create a wide-open
# admin entry if all accounts were ever deleted).
tvh_drop_firstrun() {
	[ "$(tvh_kind)" = native ] || return 0
	changed=0
	for f in /etc/systemd/system/tvheadend.service /etc/systemd/system/tvheadend.service.d/*.conf; do
		[ -f "$f" ] || continue
		if grep -qE '^ExecStart=.*[[:space:]](-C|--firstrun)([[:space:]]|$)' "$f"; then
			sed -i -E '/^ExecStart=/{s/[[:space:]](-C|--firstrun)([[:space:]]|$)/\2/g}' "$f"
			info "removed -C (first-run mode) from $f"
			changed=1
		fi
	done
	if [ -f /etc/default/tvheadend ] && grep -qE '(^|[" ])(-C|--firstrun)([" ]|$)' /etc/default/tvheadend; then
		sed -i -E 's/(^|[" ])(-C|--firstrun)([" ]|$)/\1\3/g' /etc/default/tvheadend
		changed=1
	fi
	if [ $changed = 1 ]; then
		systemctl daemon-reload
		NEED_RESTART=1
	fi
}

run_setup() {
	python3 "$SCRIPT_DIR/tvh-setup.py" --url "$(tvh_url)" "$@"
}

resolve_admin_creds() {
	tvh_load_creds
	saved_user=${TVH_USER:-} saved_pass=${TVH_PASS:-}
	[ -n "$TVH_ADMIN_USER" ] || TVH_ADMIN_USER=${saved_user:-admin}
	if [ -z "$TVH_ADMIN_PASS" ] && [ "$TVH_ADMIN_USER" = "$saved_user" ]; then
		TVH_ADMIN_PASS=$saved_pass
	fi
	if [ -z "$TVH_ADMIN_PASS" ]; then
		if [ "$ASSUME_YES" = 1 ] || ! [ -r /dev/tty ]; then
			TVH_ADMIN_PASS=$(randpw 16)
			PW_GENERATED=1
		else
			while :; do
				printf 'Password for the TVHeadend admin account "%s": ' "$TVH_ADMIN_USER" >/dev/tty
				read -rs p1 </dev/tty; echo >/dev/tty
				printf 'Repeat: ' >/dev/tty
				read -rs p2 </dev/tty; echo >/dev/tty
				[ -n "$p1" ] && [ "$p1" = "$p2" ] && break
				echo "Empty or not matching, try again." >/dev/tty
			done
			TVH_ADMIN_PASS=$p1
		fi
	fi
}

configure_tvh() {
	step "Configuring TVHeadend"
	tvh_is_running || tvh_start || true
	tvh_wait_up 120 || die "TVHeadend is not reachable at $(tvh_url)"

	# Find a way into the admin API: saved creds, the requested account, or anonymous (-C first run).
	auth=$(TVH_USER=$saved_user TVH_PASS=$saved_pass run_setup check-auth)
	if [ "$auth" = none ]; then
		auth=$(TVH_USER=$TVH_ADMIN_USER TVH_PASS=$TVH_ADMIN_PASS run_setup check-auth)
		[ "$auth" = user ] && { saved_user=$TVH_ADMIN_USER; saved_pass=$TVH_ADMIN_PASS; }
	fi
	bootstrap=
	if [ "$auth" = none ]; then
		# Temporary superuser: tvheadend reads <config>/superuser at start-up.
		cfg=$(tvh_config_dir) || die "cannot find the tvheadend config directory; pass --tvh-user/--tvh-pass of an existing admin"
		[ -d "$cfg" ] || die "tvheadend config directory $cfg does not exist"
		if ! tvh_wait_idle 0; then
			die "TVHeadend is streaming; re-run when nobody is watching"
		fi
		ask "TVHeadend needs a restart to create the admin account. Continue?" y || die "aborted"
		bootstrap=$cfg/superuser
		[ -f "$bootstrap" ] && cp -p "$bootstrap" "$bootstrap.onairgt-bak"
		saved_user=onairgt-setup saved_pass=$(randpw 24)
		( umask 077; printf '{\n  "username": "%s",\n  "password": "%s"\n}\n' "$saved_user" "$saved_pass" >"$bootstrap" )
		chown --reference="$cfg" "$bootstrap"
		info "restarting tvheadend with a temporary setup account"
		tvh_restart
	fi

	pf=
	if [ "$DO_SCAN" = 1 ] || [ -n "$PRESET" ]; then
		[ -n "$PRESET" ] || PRESET=kr-cable-8vsb
		pf=$(preset_file "$PRESET") || die "unknown preset '$PRESET' (see --list-presets)"
	fi
	args=(configure)
	if [ -n "$pf" ]; then
		args+=(--preset-file "$pf" --scan-timeout "$SCAN_TIMEOUT")
		[ "$DO_SCAN" = 1 ] || args+=(--no-scan)
		[ "$MAP_ENCRYPTED" = 0 ] || args+=(--map-encrypted)
		if ! usb_device_present || [ -z "$(onair_adapters)" ]; then
			warn "the OnAir GT is not available; only the admin account is configured now."
			info "Plug it in and run: sudo $0 --tvh existing --preset $PRESET"
			args=(configure)
		fi
	fi
	set +e
	TVH_USER=$saved_user TVH_PASS=$saved_pass TVH_NEW_USER=$TVH_ADMIN_USER TVH_NEW_PASS=$TVH_ADMIN_PASS \
		run_setup "${args[@]}"
	rc=$?
	set -e
	[ $rc = 2 ] || tvh_save_creds "$TVH_ADMIN_USER" "$TVH_ADMIN_PASS"
	state_set tvh_preset "${PRESET:-}"

	NEED_RESTART=0
	if [ -n "$bootstrap" ]; then
		rm -f "$bootstrap"
		[ -f "$bootstrap.onairgt-bak" ] && mv "$bootstrap.onairgt-bak" "$bootstrap"
		NEED_RESTART=1
	fi
	tvh_drop_firstrun
	if [ $NEED_RESTART = 1 ]; then
		# tvheadend writes changed settings to disk with a delay; restarting right
		# after the mapper lost the service<->channel links in testing
		info "restarting tvheadend (after letting it save its configuration)"
		sleep 20
		tvh_restart
	fi
	TVH_USER=$TVH_ADMIN_USER TVH_PASS=$TVH_ADMIN_PASS
	export TVH_USER TVH_PASS
	[ "$(run_setup check-auth)" = user ] || warn "could not verify the admin login after configuration"
	case $rc in
	0) ok "TVHeadend configured" ;;
	3) warn "TVHeadend does not see the tuner; check tools/onairgt-doctor.sh" ;;
	*) die "TVHeadend configuration failed (exit $rc)" ;;
	esac
}

install_tvh() {
	pick_tvh_method
	[ "$TVH_METHOD" = none ] && return 0
	resolve_admin_creds
	if [ "$TVH_METHOD" != existing ]; then
		step "Installing TVHeadend ($TVH_METHOD)"
		state_set tvh_method "$TVH_METHOD"
		"install_tvh_$TVH_METHOD"
	elif [ "$(tvh_kind)" = none ]; then
		die "--tvh existing: no TVHeadend installation found"
	fi
	state_set tvh_port "$TVH_PORT"
	if [ -z "$PRESET" ] && [ "$ASSUME_YES" = 0 ] && [ -r /dev/tty ] && [ "$DO_SCAN" = 1 ]; then
		echo >/dev/tty
		list_presets >/dev/tty
		PRESET=$(prompt "Frequency preset" "$(state_get tvh_preset | grep . || echo kr-cable-8vsb)")
	fi
	configure_tvh
}

# ===================================================================== main

printf '%sOnAir GT USB HDTV installer%s  (%s, kernel %s)\n' "$C_BLD" "$C_OFF" "$DISTRO_NAME" "$KVER"
state_set repo_dir "$REPO_DIR"
tvh_load_creds
[ $SKIP_DRIVER = 1 ] || install_driver
install_tvh

step "Done"
ad=$(onair_adapters | head -n 1)
[ -n "$ad" ] && ok "tuner: /dev/dvb/adapter$ad"
if [ "$TVH_METHOD" != none ] && [ "$(tvh_kind)" != none ]; then
	ip=$(hostname -I 2>/dev/null | awk '{print $1}')
	ok "TVHeadend: http://${ip:-localhost}:$TVH_PORT/   user: $TVH_ADMIN_USER"
	if [ $PW_GENERATED = 1 ]; then
		info "generated password: $TVH_ADMIN_PASS"
	fi
	info "credentials are saved in $CRED_FILE (root only)"
	info "HTSP (Kodi etc.): ${ip:-localhost}:$((TVH_PORT + 1))"
fi
info "Problems? Run: sudo $SCRIPT_DIR/onairgt-doctor.sh   and attach the output to a GitHub issue."
