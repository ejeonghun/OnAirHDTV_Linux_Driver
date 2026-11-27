#!/usr/bin/env bash
# Offline test of resume, checksum and strict-mode behavior.
set -euo pipefail
HERE=$(mktemp -d)
trap 'rm -rf "$HERE"' EXIT
DL_DIR=$HERE/cache
mkdir -p "$DL_DIR"
printf '0123456789abcdef' > "$HERE/original"
sum=$(sha256sum "$HERE/original" | cut -d' ' -f1)
printf '%s  archive.txz\n' "$sum" > "$HERE/SHA256SUMS"
source "$(dirname "$0")/download.sh"
log() { printf '%s\n' "$*"; }
die() { echo "$*" >&2; exit 1; }
sleep() { :; }
calls=0
curl() {
	local dest="" resume=0
	while (($#)); do
		case "$1" in
		-o) dest=$2; shift ;;
		--continue-at) resume=1; shift ;;
		esac
		shift
	done
	[ "$resume" = 1 ]
	calls=$((calls + 1))
	case "$calls" in
	1) head -c 8 "$HERE/original" > "$dest"; return 56 ;;
	2) [ "$(wc -c < "$dest")" -eq 8 ]; tail -c 8 "$HERE/original" >> "$dest" ;;
	*) echo "unexpected network call" >&2; return 1 ;;
	esac
}
fetch https://invalid.example/archive archive.txz
[ "$calls" -eq 2 ]
cmp "$HERE/original" "$DL_DIR/archive.txz"
[ ! -e "$DL_DIR/archive.txz.part" ]
# Cache hit must not use curl again.
fetch https://invalid.example/archive archive.txz
[ "$calls" -eq 2 ]
# A corrupt completed transfer must be retried from zero.
rm "$DL_DIR/archive.txz"
calls=0
curl() {
	local dest=""
	while (($#)); do
		case "$1" in -o) dest=$2; shift ;; esac
		shift
	done
	calls=$((calls + 1))
	if [ "$calls" = 1 ]; then
		printf 'corrupt' > "$dest"
	else
		[ ! -e "$dest" ]
		cp "$HERE/original" "$dest"
	fi
}
fetch https://invalid.example/archive archive.txz
[ "$calls" -eq 2 ]
cmp "$HERE/original" "$DL_DIR/archive.txz"
if (STRICT_CHECKSUMS=1; fetch https://invalid.example/unpinned unpinned.txz); then
	echo "strict checksum check failed" >&2
	exit 1
fi
[ ! -e "$DL_DIR/unpinned.txz" ]
echo "DSM download tests passed"
