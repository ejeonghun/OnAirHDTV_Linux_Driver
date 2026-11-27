#!/usr/bin/env bash
# Build the DVB stack + dvb-usb-onairgt for a Synology DSM kernel (Xpenology).
#
# usage: synology/build-dsm.sh <platform> [dsm_version]
#   platform     epyc7002 geminilakenk r1000nk v1000nk           (Linux 5.10.55)
#                r1000 v1000 geminilake apollolake broadwellnk denverton (Linux 4.4.302)
#   dsm_version  7.2 (default; the only one with a table below)
#
# What it does:
#   1. downloads (cached in $DL_DIR) the Synology cross toolchain, the toolkit
#      "dev" tarball (holds the real DSM kernel .config, Module.symvers and
#      kernel.release) and the Synology GPL kernel source
#   2. configures the GPL source with the DSM .config plus the DVB options,
#      refusing to continue if anything outside drivers/media changes
#   3. builds drivers/media (dvb-core, dvb_usb_v2, lgdt330x, tuner-simple,
#      tuner-types, rc-core fallback) and the driver against it
#   4. checks vermagic and that every undefined symbol resolves inside the
#      bundle or the DSM kernel's Module.symvers
#   5. packages synology/dist/onairgt-dsm-<platform>-<dsm>-<kver>.tgz
#
# Environment: WORK_DIR, DL_DIR, DIST_DIR, JOBS, TOOLCHAIN_VER, GPL_VER,
#              STRICT_CHECKSUMS=1 (fail on downloads without a pinned hash),
#              KEEP_WORK=1 (do not delete the extracted trees afterwards).
set -euo pipefail
trap 'echo "error: build-dsm.sh failed at line $LINENO" >&2' ERR

PLATFORM=${1:-}
DSM=${2:-7.2}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
WORK_DIR=${WORK_DIR:-$HERE/work}
DL_DIR=${DL_DIR:-$HERE/work/dl}
DIST_DIR=${DIST_DIR:-$HERE/dist}
JOBS=${JOBS:-$(nproc)}
SITE=https://global.synologydownload.com/download/ToolChain

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

[ -n "$PLATFORM" ] || { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ "$DSM" = 7.2 ] || die "only DSM 7.2 is described in the platform table"

# ---------------------------------------------------------------- platforms
# TC_DIR is Synology's directory name on the download site (inconsistent
# spelling is theirs). KSRC_PLAT is the GPL tarball directory that carries the
# kernel source: the 5.10.55 tree is only published under epyc7002 but its
# synology/synoconfigs covers the other *nk platforms, and the per-platform
# .config is taken from that platform's own dev tarball anyway.
TOOLCHAIN_VER=${TOOLCHAIN_VER:-7.2-72806}
GPL_VER=${GPL_VER:-7.2-72806}
case $PLATFORM in
epyc7002)     KVER=5.10.55; TC_DIR="AMD x86 Linux Linux 5.10.55 (epyc7002)" ;;
geminilakenk) KVER=5.10.55; TC_DIR="Intel x86 Linux 5.10.55 (geminilakenk)" ;;
r1000nk)      KVER=5.10.55; TC_DIR="AMD x86 Linux 5.10.55 (r1000nk)" ;;
v1000nk)      KVER=5.10.55; TC_DIR="AMD x86 Linux 5.10.55 (v1000nk)" ;;
r1000)        KVER=4.4.302; TC_DIR="AMD x86 Linux 4.4.302 (r1000)" ;;
v1000)        KVER=4.4.302; TC_DIR="Intel x86 Linux 4.4.302 (V1000)" ;;
geminilake)   KVER=4.4.302; TC_DIR="Intel x86 Linux 4.4.302 (GeminiLake)" ;;
apollolake)   KVER=4.4.302; TC_DIR="Intel x86 Linux 4.4.180 (Apollolake)" ;;
broadwellnk)  KVER=4.4.302; TC_DIR="Intel x86 Linux 4.4.302 (Broadwellnk)" ;;
denverton)    KVER=4.4.302; TC_DIR="Intel x86 Linux 4.4.302 (Denverton)" ;;
*) die "unknown platform '$PLATFORM'" ;;
esac
case $KVER in
5.10.*) KSRC_PLAT=epyc7002;   KSRC_TXZ=linux-5.10.x.txz ;;
4.4.*)  KSRC_PLAT=$PLATFORM;  KSRC_TXZ=linux-4.4.x.txz ;;
esac

urlenc() { sed -e 's/ /%20/g' -e 's/(/%28/g' -e 's/)/%29/g' <<<"$1"; }
TC_TXZ=$PLATFORM-gcc1220_glibc236_x86_64-GPL.txz
TC_URL="$SITE/toolchain/$TOOLCHAIN_VER/$(urlenc "$TC_DIR")/$TC_TXZ"
DEV_TXZ=ds.$PLATFORM-$DSM.dev.txz
DEV_URL="$SITE/toolkit/$DSM/$PLATFORM/$DEV_TXZ"
KSRC_URL="$SITE/Synology%20NAS%20GPL%20Source/$GPL_VER/$KSRC_PLAT/$KSRC_TXZ"

for t in make gcc bison flex bc perl xz curl tar sha256sum; do
	command -v $t >/dev/null || die "missing host tool: $t (apt-get install build-essential bison flex bc libelf-dev libssl-dev xz-utils curl)"
done

# ---------------------------------------------------------------- download
mkdir -p "$DL_DIR" "$DIST_DIR"
# shellcheck source=synology/download.sh
source "$HERE/download.sh"
fetch "$TC_URL"   "$TC_TXZ"
fetch "$DEV_URL"  "$DEV_TXZ"
fetch "$KSRC_URL" "$KSRC_PLAT-$GPL_VER-$KSRC_TXZ"

# ---------------------------------------------------------------- extract
W=$WORK_DIR/$PLATFORM-$DSM
# the toolchain tarball contains read-only directories
wipe() { [ -d "$1" ] && chmod -R u+w "$1" && rm -rf "$1"; return 0; }
wipe "$W"
mkdir -p "$W/tc" "$W/dev" "$W/src"
log "extracting toolchain"
tar -xJf "$DL_DIR/$TC_TXZ" -C "$W/tc"
CROSS=$W/tc/x86_64-pc-linux-gnu/bin/x86_64-pc-linux-gnu-
[ -x "${CROSS}gcc" ] || die "toolchain layout changed: ${CROSS}gcc missing"
log "extracting DSM kernel build tree from $DEV_TXZ"
tar -xJf "$DL_DIR/$DEV_TXZ" -C "$W/dev" --wildcards '*/sys-root/usr/lib/modules/*'
KB=$(find "$W/dev" -path '*/lib/modules/*/build' -type d | head -1)
[ -f "$KB/.config" ] && [ -f "$KB/Module.symvers" ] || die "no build tree with .config/Module.symvers in $DEV_TXZ"
log "extracting kernel source $KSRC_TXZ"
tar -xJf "$DL_DIR/$KSRC_PLAT-$GPL_VER-$KSRC_TXZ" -C "$W/src"
KS=$(find "$W/src" -mindepth 1 -maxdepth 1 -type d | head -1)
[ -f "$KS/Makefile" ] || die "kernel source not found"

DSM_RELEASE=$(cat "$KB/include/config/kernel.release")
log "DSM kernel release: $DSM_RELEASE ($(grep -o '"#[^"]*"' "$KB/include/generated/compile.h" 2>/dev/null || true))"

# ---------------------------------------------------------------- configure
KMAKE=(make -C "$KS" ARCH=x86 CROSS_COMPILE="$CROSS" -j"$JOBS")
# DSM's release is "<ver>+"; without git the source tree would not add the "+".
sed -i -e "s/^EXTRAVERSION *=.*/EXTRAVERSION = ${DSM_RELEASE#${KVER}}/" "$KS/Makefile"
cp "$KB/.config" "$KS/.config"
cp "$KS/.config" "$W/config.dsm"
cfg() { "$KS/scripts/config" --file "$KS/.config" "$@"; }
# Some DSM kernels (the 4.4 ones) were configured with the DVB stack already:
# keep their media config untouched so the modules match DSM's own build.
if grep -q '^CONFIG_MEDIA_SUPPORT=[ym]' "$KS/.config"; then
	cfg --module DVB_CORE --module DVB_USB_V2 --module DVB_LGDT330X --module MEDIA_TUNER_SIMPLE
else
cfg --module MEDIA_SUPPORT \
    --enable MEDIA_SUPPORT_FILTER \
    --enable MEDIA_DIGITAL_TV_SUPPORT \
    --disable MEDIA_CAMERA_SUPPORT --disable MEDIA_ANALOG_TV_SUPPORT \
    --disable MEDIA_RADIO_SUPPORT --disable MEDIA_SDR_SUPPORT \
    --disable MEDIA_PLATFORM_SUPPORT --disable MEDIA_TEST_SUPPORT \
    --disable MEDIA_CONTROLLER_DVB \
    --enable MEDIA_USB_SUPPORT --disable MEDIA_PCI_SUPPORT \
    --enable MEDIA_SUBDRV_AUTOSELECT \
    --module DVB_CORE \
    --module DVB_USB_V2 \
    --module DVB_LGDT330X \
    --module MEDIA_TUNER_SIMPLE
fi
# rc-core: keep DSM's setting when its kernel was built with it (all checked
# 7.2 platforms are), otherwise build it so dvb_usb_v2 has its RC symbols.
grep -q '^CONFIG_RC_CORE=[ym]' "$KS/.config" || cfg --module RC_CORE --disable LIRC --disable RC_MAP --disable RC_DEVICES
"${KMAKE[@]}" olddefconfig >/dev/null

# Every changed symbol must be defined by a Kconfig under drivers/media,
# otherwise core structures could differ from the running DSM kernel.
export LC_ALL=C
media_syms=$(grep -rhoE '^(menu)?config [A-Za-z0-9_]+' "$KS/drivers/media" --include='Kconfig*' | awk '{print $2}' | sort -u)
# symbols whose value differs (a symbol missing from a .config counts as n)
config_changes() {
	awk 'function v(l) { if (l ~ /^# CONFIG_.* is not set$/) { sub(/^# CONFIG_/, "", l); sub(/ is not set$/, "=n", l) }
	                     else sub(/^CONFIG_/, "", l); return l }
	     /^(# )?CONFIG_/ { l = v($0); k = l; sub(/=.*/, "", k); val = substr(l, length(k) + 2)
	                       if (FILENAME == ARGV[1]) a[k] = val; else b[k] = val }
	     END { for (k in a) if (!(k in b)) b[k] = "n"; for (k in b) if (!(k in a)) a[k] = "n"
	           for (k in a) if (a[k] != b[k]) print k }' "$W/config.dsm" "$KS/.config" | sort
}
# SND_USB_AUDIO_USE_MEDIA_CONTROLLER follows MEDIA_CONTROLLER (which the
# media Kconfig forces on with digital TV) and only changes snd-usb-audio,
# which is not rebuilt here.
allowed=$(printf '%s\n' $media_syms SND_USB_AUDIO_USE_MEDIA_CONTROLLER | sort -u)
outside_media() { comm -23 <(config_changes) <(echo "$allowed") | grep . || true; }
# The GPL source can be a newer 7.2 build than the dev tree's kernel and add
# Synology options that the shipped kernel did not have: force those off.
for s in $(outside_media); do
	grep -qE "^(# )?CONFIG_${s}[= ]" "$W/config.dsm" || { log "unknown to DSM kernel, disabling: $s"; cfg --disable "$s"; }
done
"${KMAKE[@]}" olddefconfig >/dev/null
# Options of a newer DSM kernel that this source's Kconfig does not know are
# dropped by olddefconfig. They are harmless here only if no header and no
# drivers/media file of the source tests them.
bad=""
for s in $(outside_media); do
	if grep -rqw "CONFIG_$s" "$KS/include" "$KS/arch/x86/include" "$KS/drivers/media" \
		--exclude-dir=config --exclude-dir=generated; then
		bad="$bad $s"
	else
		log "tolerated: $s (DSM option not used by any header or drivers/media)"
	fi
done
[ -z "$bad" ] || die "config change outside drivers/media:$bad"
log "config delta (media only): $(config_changes | wc -l) symbols"
diff "$W/config.dsm" "$KS/.config" > "$W/config.delta" || true

# objtool is only needed for the stack validation pass and resolve_btfids
# only for linking vmlinux; both fail to build with recent host compilers.
# Stub them like SynoCommunity's spksrc does (OBJECT_FILES_NON_STANDARD=y below).
for t in objtool bpf/resolve_btfids; do
	[ -f "$KS/tools/$t/Makefile" ] && printf 'all:\nclean:\n' > "$KS/tools/$t/Makefile"
done
log "modules_prepare"
"${KMAKE[@]}" HOSTCFLAGS="-fcommon -Wno-error" modules_prepare >"$W/prepare.log" 2>&1 ||
	{ tail -40 "$W/prepare.log"; die "modules_prepare failed (log: $W/prepare.log)"; }
[ "$("${KMAKE[@]}" -s kernelrelease)" = "$DSM_RELEASE" ] || die "kernelrelease mismatch"
# modpost resolves against the shipped kernel's exports
cp "$KB/Module.symvers" "$KS/Module.symvers"

# ---------------------------------------------------------------- build
if [[ "$KVER" == 5.10.* ]]; then
	command -v python3 >/dev/null || die "python3 required for DSM DVB fix"
	python3 "$HERE/patch-dvb-feed.py" "$KS/drivers/media/usb/dvb-usb-v2/dvb_usb_core.c"
fi
log "building drivers/media"
"${KMAKE[@]}" M=drivers/media OBJECT_FILES_NON_STANDARD=y modules >"$W/media.log" 2>&1 ||
	{ tail -40 "$W/media.log"; die "media build failed (log: $W/media.log)"; }

log "building dvb-usb-onairgt"
OD=$W/onairgt
mkdir -p "$OD"
# only the sources: dvb_usb.h, lgdt330x.h and tuner-simple.h must come from
# the target tree (fallback-kheaders/ is for distro kernels)
cp "$REPO"/*.c "$OD"/
for h in "$REPO"/*.h; do
	[ -f "$h" ] && cp "$h" "$OD"/
done
rm -f "$OD/dvb_usb.h" "$OD/lgdt330x.h" "$OD/tuner-simple.h"
cat > "$OD/Kbuild" <<'EOF'
obj-m := dvb-usb-onairgt.o
dvb-usb-onairgt-y := onairgt.o
ccflags-y += -I$(srctree)/drivers/media/usb/dvb-usb-v2 \
	     -I$(srctree)/drivers/media/dvb-frontends \
	     -I$(srctree)/drivers/media/tuners \
	     -I$(srctree)/drivers/media/dvb-core
EOF
"${KMAKE[@]}" M="$OD" OBJECT_FILES_NON_STANDARD=y \
	KBUILD_EXTRA_SYMBOLS="$KS/drivers/media/Module.symvers" modules >"$W/onairgt.log" 2>&1 ||
	{ tail -40 "$W/onairgt.log"; die "onairgt build failed (log: $W/onairgt.log)"; }
if grep -E 'WARNING: .*(undefined|not found)' "$W/media.log" "$W/onairgt.log"; then
	die "modpost reported unresolved symbols"
fi

# ---------------------------------------------------------------- collect
PKG=onairgt-dsm-$PLATFORM-$DSM-$DSM_RELEASE
P=$W/$PKG
mkdir -p "$P/modules" "$P/fallback"
want="dvb-core dvb_usb_v2 lgdt330x tuner-types tuner-simple"
for m in $want; do
	f=$(find "$KS/drivers/media" -name "$m.ko" | head -1)
	[ -n "$f" ] || die "$m.ko was not built"
	cp "$f" "$P/modules/"
done
cp "$OD/dvb-usb-onairgt.ko" "$P/modules/"
# rc-core: shipped by DSM when its config has it; ours is a fallback only
if grep -q '^CONFIG_RC_CORE=m' "$W/config.dsm"; then
	f=$(find "$KS/drivers/media/rc" -name rc-core.ko | head -1)
	[ -n "$f" ] && cp "$f" "$P/fallback/"
	DSM_HAS_RC=1
else
	f=$(find "$KS/drivers/media/rc" -name rc-core.ko | head -1)
	[ -n "$f" ] && cp "$f" "$P/modules/"
	DSM_HAS_RC=0
fi
for f in "$P"/modules/*.ko "$P"/fallback/*.ko; do
	[ -f "$f" ] && "${CROSS}strip" --strip-debug "$f"
done

# ---------------------------------------------------------------- verify
log "verifying vermagic and symbols"
expect="$DSM_RELEASE SMP"
grep -q '^CONFIG_PREEMPT=y' "$KB/.config" && expect="$expect preempt"
expect="$expect mod_unload"
grep -q '^CONFIG_MODVERSIONS=y' "$KB/.config" && expect="$expect modversions"
modinfo_f() { /sbin/modinfo -F "$2" "$1" 2>/dev/null || modinfo -F "$2" "$1"; }

# exported symbol -> owner; the last owner listed wins, so a fallback module
# loses to DSM's own copy and DSM's copy loses to a bundled module
ko_exports() {
	for f in "$@"; do
		[ -f "$f" ] || continue
		"${CROSS}nm" "$f" | awk -v m="bundle:$(basename "$f" .ko)" '$3 ~ /^__ksymtab_/ { sub(/^__ksymtab_/, "", $3); print $3, m }'
	done
}
{
	ko_exports "$P"/fallback/*.ko
	awk '{ print $2, $3 }' "$KB/Module.symvers"
	ko_exports "$P"/modules/*.ko
} > "$W/exports"

: > "$W/verify.txt"
dsm_deps=""
for f in "$P"/modules/*.ko "$P"/fallback/*.ko; do
	[ -f "$f" ] || continue
	vm=$(modinfo_f "$f" vermagic)
	[ "$(echo $vm)" = "$expect" ] || die "$(basename "$f"): vermagic '$vm' != '$expect'"
	missing=$("${CROSS}nm" -u "$f" | awk '{print $2}' | sort -u |
		  awk 'NR==FNR { have[$1]=1; next } !($1 in have)' "$W/exports" -)
	[ -z "$missing" ] || die "$(basename "$f"): unresolved: $(echo $missing)"
	owners=$("${CROSS}nm" -u "$f" | awk '{print $2}' | sort -u |
		 awk 'NR==FNR { own[$1]=$2; next } { print own[$1] }' "$W/exports" - | sort -u | tr '\n' ' ')
	printf '%-22s vermagic="%s" needs: %s\n' "$(basename "$f")" "$vm" "$owners" >> "$W/verify.txt"
	for o in $owners; do
		case $o in vmlinux|bundle:*) ;; *) dsm_deps="$dsm_deps $(basename "$o")" ;; esac
	done
done
dsm_deps=$(echo $dsm_deps | tr ' ' '\n' | sort -u | tr '\n' ' ')
cat "$W/verify.txt"
log "DSM modules the bundle relies on: ${dsm_deps:-none}"

# load order: dependencies first (from modinfo depends). The driver goes last:
# it reaches lgdt330x/tuner-simple through dvb_attach() (symbol_get), and
# those must already be loaded because they are not in /lib/modules.
order=""
pending=$(cd "$P/modules" && ls *.ko | sed 's/\.ko$//' | grep -vx dvb-usb-onairgt)
while [ -n "$pending" ]; do
	progress=0 next=""
	for m in $pending; do
		ok=1
		for d in $(modinfo_f "$P/modules/$m.ko" depends | tr ',' ' '); do
			[ -f "$P/modules/$d.ko" ] || continue
			case " $order " in *" $d "*) ;; *) ok=0 ;; esac
		done
		if [ $ok = 1 ]; then order="$order $m"; progress=1; else next="$next $m"; fi
	done
	[ $progress = 1 ] || die "dependency cycle in: $next"
	pending=$next
done
order="$order dvb-usb-onairgt"

# ---------------------------------------------------------------- package
{
	echo "# modules from DSM itself, loaded with modprobe first"
	for d in $dsm_deps; do
		case $d in rc-core) echo "dsm rc-core fallback/rc-core.ko" ;; *) echo "dsm $d" ;; esac
	done
	echo "# bundled modules, insmod in this order"
	for m in $order; do echo "ko $m"; done
} > "$P/modules.load"
cp "$HERE"/pkg/install-dsm.sh "$HERE"/pkg/uninstall-dsm.sh "$HERE"/pkg/onairgt-dsm.sh "$P/"
chmod 755 "$P"/*.sh
if COMMIT=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null); then
	git -C "$REPO" diff --quiet HEAD -- onairgt.c || COMMIT=$COMMIT-dirty
else
	COMMIT=unknown
fi
cat > "$P/BUILDINFO" <<EOF
platform=$PLATFORM
dsm=$DSM
kernel_release=$DSM_RELEASE
vermagic=$expect
dsm_kernel_build=$(sed -n 's/.*UTS_VERSION "#\([0-9]*\).*/\1/p' "$KB/include/generated/compile.h" 2>/dev/null)
toolchain=$TOOLCHAIN_VER/$TC_TXZ
kernel_source=$GPL_VER/$KSRC_PLAT/$KSRC_TXZ
dev_tree=$DSM/$DEV_TXZ
dsm_config_has_rc_core=$DSM_HAS_RC
driver_commit=$COMMIT
driver_sha256=$(cat "$REPO"/*.c | sha256sum | cut -d' ' -f1)
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
status=EXPERIMENTAL - hardware regression and long-duration testing required
EOF
cp "$W/verify.txt" "$P/VERIFY.txt"
cp "$W/config.delta" "$P/config.delta"
(cd "$P" && sha256sum modules/*.ko fallback/*.ko 2>/dev/null > SHA256SUMS)
tar -C "$W" --owner=0 --group=0 -czf "$DIST_DIR/$PKG.tgz" "$PKG"
log "wrote $DIST_DIR/$PKG.tgz ($(du -h "$DIST_DIR/$PKG.tgz" | cut -f1))"
cat "$P/modules.load"

[ "${KEEP_WORK:-0}" = 1 ] || wipe "$W"
