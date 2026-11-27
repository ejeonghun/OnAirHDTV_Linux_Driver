#!/usr/bin/env bash
# Shared download helper for build-dsm.sh. Called with DL_DIR/HERE and
# log/die defined by the caller. Keep incomplete downloads out of the cache
# of finished archives; never promote a partial or bad-checksum file.

fetch() { # url local-name
	local out="$DL_DIR/$2" part="$DL_DIR/$2.part" pinned sum attempt rc
	pinned=$(awk -v f="$2" '$2 == f { print $1 }' "$HERE/SHA256SUMS")
	if [ -z "$pinned" ] && [ "${STRICT_CHECKSUMS:-0}" = 1 ]; then
		die "$2 has no pinned sha256 in synology/SHA256SUMS"
	fi

	if [ -s "$out" ]; then
		sum=$(sha256sum "$out" | cut -d' ' -f1)
		if [ -z "$pinned" ] || [ "$sum" = "$pinned" ]; then
			[ -n "$pinned" ] || echo "warning: $2 not pinned in synology/SHA256SUMS: $sum" >&2
			return 0
		fi
		log "$2: cached checksum mismatch; fetching again"
		rm -f "$out" "$part"
	fi

	for attempt in 1 2 3 4 5 6; do
		# A complete pinned partial may already exist after an interruption.
		if [ -n "$pinned" ] && [ -s "$part" ]; then
			sum=$(sha256sum "$part" | cut -d' ' -f1)
			if [ "$sum" = "$pinned" ]; then
				mv "$part" "$out"
				return 0
			fi
		fi
		log "downloading $2 (attempt $attempt/6)"
		# Resume only when a pinned digest can detect changed remote content.
		local -a resume=()
		if [ -n "$pinned" ]; then
			resume=(--continue-at -)
		else
			rm -f "$part"
		fi
		rc=0
		curl -fL --connect-timeout 20 --max-time 1800 \
			--speed-limit 1024 --speed-time 90 "${resume[@]}" \
			-o "$part" "$1" || rc=$?
		if [ "$rc" = 0 ] && [ -s "$part" ]; then
			sum=$(sha256sum "$part" | cut -d' ' -f1)
			if [ -z "$pinned" ] || [ "$sum" = "$pinned" ]; then
				[ -n "$pinned" ] || echo "warning: $2 not pinned in synology/SHA256SUMS: $sum" >&2
				mv "$part" "$out"
				return 0
			fi
			log "$2: checksum mismatch; restarting download"
			rm -f "$part"
		else
			log "$2: download failed (curl exit $rc)"
			# A server may reject a Range request or the partial may be
			# larger than the resource. Retry from zero in that case.
			case "$rc" in
				22|33|36) rm -f "$part" ;;
			esac
		fi
		[ "$attempt" = 6 ] || sleep "$((attempt * 5))"
	done
	die "$2: download/checksum verification failed after 6 attempts"
}
