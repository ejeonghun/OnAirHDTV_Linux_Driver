#!/bin/sh
# Remove the OnAir GT DVB bundle from DSM.
# usage: uninstall-dsm.sh [--prefix /usr/local/onairgt] [--purge-firmware]
PATH=/sbin:/usr/sbin:/bin:/usr/bin
DIR=$(cd "$(dirname "$0")" && pwd)
PREFIX=$DIR
PURGE=0
while [ $# -gt 0 ]; do
	case $1 in
	--prefix) PREFIX=$2; shift ;;
	--purge-firmware) PURGE=1 ;;
	*) echo "usage: $0 [--prefix DIR] [--purge-firmware]" >&2; exit 1 ;;
	esac
	shift
done
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -f "$PREFIX/modules.load" ] || { echo "$PREFIX is not an onairgt install" >&2; exit 1; }

"$PREFIX/onairgt-dsm.sh" stop
rm -f /usr/local/etc/rc.d/onairgt-dvb.sh
rm -f /usr/lib/udev/rules.d/99-onairgt-dvb.rules /lib/udev/rules.d/99-onairgt-dvb.rules \
      /etc/udev/rules.d/99-onairgt-dvb.rules
[ $PURGE = 1 ] && rm -f /lib/firmware/dvb-usb-onairgt-01.fw
rm -rf "$PREFIX"
echo "removed $PREFIX; delete the Task Scheduler boot-up task by hand"
