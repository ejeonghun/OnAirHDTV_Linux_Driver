#!/bin/sh
# Run the compile matrix locally with docker.
# usage: sh ci/matrix.sh [target ...]    (default: all targets)
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

image() {
	case $1 in
	ubuntu-18.04*)    echo ubuntu:18.04 ;;
	ubuntu-*)         echo "ubuntu:${1#ubuntu-}" ;;
	debian-*)         echo "debian:${1#debian-}" ;;
	fedora)           echo fedora:latest ;;
	vanilla-4.4.302)  echo ubuntu:18.04 ;;	# gcc 7
	vanilla-5.10.55)  echo ubuntu:20.04 ;;	# gcc 9
	esac
}

targets=${*:-"ubuntu-18.04 ubuntu-18.04-hwe ubuntu-20.04 ubuntu-22.04 ubuntu-24.04 debian-11 debian-12 debian-13 fedora vanilla-4.4.302 vanilla-5.10.55"}
mkdir -p "$HERE/logs"
fail=0
for t in $targets; do
	docker run --rm -v "$REPO:/src:ro" -e SRC=/src "$(image "$t")" \
		sh /src/ci/compile.sh "$t" > "$HERE/logs/$t.log" 2>&1
	grep '^RESULT' "$HERE/logs/$t.log" || echo "RESULT $t ? FAIL (see ci/logs/$t.log)"
	grep -q "^RESULT .* PASS" "$HERE/logs/$t.log" && ! grep -q "^RESULT .* FAIL" "$HERE/logs/$t.log" || fail=1
	[ -n "${CI:-}" ] && cat "$HERE/logs/$t.log"
done
exit $fail
