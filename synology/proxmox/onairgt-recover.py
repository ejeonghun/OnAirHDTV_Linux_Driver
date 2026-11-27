#!/usr/bin/env python3
"""Recover one OnAir GT passed through to a running DSM VM (run on PVE)."""
import argparse
import fcntl
import json
import os
import pathlib
import re
import subprocess
import sys
import time

USB = pathlib.Path("/sys/bus/usb/devices")
LOADER = "/usr/local/onairgt/onairgt-dsm.sh"
PATH = "PATH=/usr/local/bin:/usr/syno/bin:/usr/syno/sbin:/usr/bin:/usr/sbin:/bin:/sbin; "
VID_PID = ("11ba", "1101")


class RecoveryError(RuntimeError):
    pass


def run(*args, timeout=90):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE,
                          timeout=timeout).stdout.strip()


def log(message):
    print(message, flush=True)


def guest(vmid, *args, allow_not_ready=False):
    raw = run("qm", "guest", "exec", str(vmid), "--timeout", "70", "--", *args)
    result = json.loads(raw)
    if result.get("err-data"):
        print(result["err-data"], file=sys.stderr)
    if result.get("exited") != 1 or "exitcode" not in result:
        raise RecoveryError("guest command did not finish; do not retry while it may be running")
    code = result["exitcode"]
    if allow_not_ready and code == 1:
        return None
    if code != 0:
        raise RecoveryError(f"guest command failed ({code}): {args!r}")
    return result.get("out-data", "").strip()


def shell(vmid, script, *args, **kwargs):
    return guest(vmid, "/bin/sh", "-c", PATH + script, "sh", *args, **kwargs)


def slot_config(vmid, slot, current=False):
    args = ["qm", "config", str(vmid)]
    if current:
        args += ["--current", "1"]
    return next((line.split(": ", 1)[1] for line in run(*args).splitlines()
                 if line.startswith(slot + ": ")), "")


def find_usb():
    hits = []
    for dev in USB.iterdir():
        try:
            if tuple((dev / attr).read_text().strip()
                     for attr in ("idVendor", "idProduct")) == VID_PID:
                hits.append(dev)
        except (FileNotFoundError, NotADirectoryError):
            continue
    if len(hits) != 1:
        raise RecoveryError("expected exactly one 11ba:1101 on this host")
    return hits[0]


def reset_usb(dev):
    # Run USBDEVFS_RESET in a separate process with a bounded wait.
    # USB bus reset does NOT imply a VBUS power cut.
    run(sys.executable, "-c", """
import fcntl, os, pathlib, sys
p = pathlib.Path(sys.argv[1])
if ((p/'idVendor').read_text().strip(), (p/'idProduct').read_text().strip()) != ('11ba','1101'):
    raise RuntimeError('USB identity changed')
bus = int((p/'busnum').read_text())
dev = int((p/'devnum').read_text())
fd = os.open(f'/dev/bus/usb/{bus:03}/{dev:03}', os.O_WRONLY)
try:
    fcntl.ioctl(fd, 0x5514, 0)  # USBDEVFS_RESET
finally:
    os.close(fd)
""", str(dev), timeout=20)


def hub_port(location):
    if "." in location:
        return tuple(location.rsplit(".", 1))
    return tuple(location.split("-", 1))


def wait_host(location):
    for _ in range(30):
        try:
            dev = find_usb()
            if dev.name == location:
                return dev
        except RecoveryError:
            pass
        time.sleep(1)
    raise RecoveryError("tuner did not re-enumerate at original physical port")


def start_tv(vmid, container):
    shell(vmid, '''
        /usr/local/onairgt/onairgt-dsm.sh ready || exit 1
        if [ "$(docker inspect -f "{{.State.Running}}" "$1")" != true ]; then
            docker start "$1" || exit 1
        fi
        docker exec "$1" sh -c "test -c /dev/dvb/adapter0/frontend0"
    ''', container)


def recover(args):
    vmid, slot, container = args.vmid, args.slot, args.container
    if run("qm", "status", str(vmid)) != "status: running":
        raise RecoveryError("VM must be running on this node")
    original = slot_config(vmid, slot, current=True)
    if not re.fullmatch(r"(?:host=)?11ba:1101(?:,usb3=[01])?", original):
        raise RecoveryError(f"expected VID:PID passthrough in {slot}, got {original!r}")
    if slot_config(vmid, slot) != original:
        raise RecoveryError("pending USB config; resolve it first")
    log(f"Original mapping: {slot}: {original}")
    shell(vmid, 'test "$(id -u)" = 0 && test -x ' + LOADER +
          ' && grep -q "^ready)" ' + LOADER)
    boot = guest(vmid, "/bin/cat", "/proc/sys/kernel/random/boot_id")
    if not re.fullmatch(r"[0-9a-fA-F-]{36}", boot):
        raise RecoveryError("invalid guest boot ID")
    stamp = pathlib.Path(f"/run/onairgt-{vmid}-{slot}-{boot}")
    shell(vmid, 'docker info >/dev/null 2>&1 && docker inspect "$1" >/dev/null',
          container)
    if not args.recover:
        if guest(vmid, LOADER, "ready", allow_not_ready=True) is not None:
            start_tv(vmid, container)
            log("DVB and container ready; no reset")
            return
        if stamp.exists():
            raise RecoveryError("one automatic attempt already made this guest boot; diagnose then use --recover")
    dev = find_usb()
    location = dev.name
    if args.power_cycle and tuple(args.power_cycle) != hub_port(location):
        raise RecoveryError(f"hub/port does not match tuner location {location}")
    if args.power_cycle:
        # User must verify independent physical VBUS switching before opting in.
        run("uhubctl", "--version")
    # Stop DVB consumers before unloading. Never detach an unresponsive guest.
    shell(vmid, '''
        if [ "$(docker inspect -f "{{.State.Running}}" "$1")" = true ]; then
            docker stop -t 20 "$1" || exit 1
        fi
        /usr/local/onairgt/onairgt-dsm.sh stop || exit 1
        test ! -d /sys/module/dvb_usb_onairgt
    ''', container)
    stamp.touch()
    detached = False
    try:
        log("Hot-unplugging only " + slot)
        run("qm", "set", str(vmid), "--delete", slot)
        if slot_config(vmid, slot, current=True) or slot_config(vmid, slot):
            raise RecoveryError("USB unplug not applied live; check PVE hotplug support and pending config")
        detached = True
        # Wait for guest USB removal, not just the PVE config update.
        shell(vmid, '''
            i=0
            while [ "$i" -lt 20 ]; do
                found=0
                for d in /sys/bus/usb/devices/*; do
                    [ -r "$d/idVendor" ] && [ -r "$d/idProduct" ] || continue
                    if [ "$(cat "$d/idVendor")" = 11ba ] && [ "$(cat "$d/idProduct")" = 1101 ]; then found=1; fi
                done
                [ "$found" = 0 ] && exit 0
                sleep 1
                i=$((i+1))
            done
            exit 1
        ''')
        dev = wait_host(location)
        # Host DVB modules can bind once QEMU releases the interface.
        # Refuse rather than silently unbinding a host driver.
        for interface in USB.glob(location + ":*"):
            if (interface / "driver").is_symlink():
                raise RecoveryError(f"host interface still claimed: {interface}; inspect lsusb -t")
        if args.power_cycle:
            hub, port = args.power_cycle
            log(f"Explicit per-port power cycle {hub} port {port}")
            run("uhubctl", "-e", "-l", hub, "-p", port, "-a", "cycle", "-d", "5", timeout=30)
        else:
            log("Host USBDEVFS_RESET")
            reset_usb(dev)
        wait_host(location)
        log("Restoring original PVE mapping")
        run("qm", "set", str(vmid), "--" + slot, original)
        if slot_config(vmid, slot, current=True) != original or slot_config(vmid, slot) != original:
            raise RecoveryError("USB reattach pending; inspect qm pending")
        detached = False
    except subprocess.TimeoutExpired:
        # A PVE task could still be running. Do not race it with rollback.
        log(f"Timeout; inspect qm config/pending before restoring {slot}: {original}")
        raise
    except BaseException:
        if detached:
            try:
                if not slot_config(vmid, slot, True) and not slot_config(vmid, slot):
                    log("Restoring original USB configuration after failure")
                    run("qm", "set", str(vmid), "--" + slot, original)
            except Exception as exc:
                print(f"Rollback failed: {exc}", file=sys.stderr)
        log(f"Inspect qm config {vmid} --current 1 and qm pending {vmid}; original {slot}: {original}")
        raise
    time.sleep(3)
    guest(vmid, LOADER, "start")
    start_tv(vmid, container)
    log("Recovery complete (nodes and container verified; tune a channel to verify reception)")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--vmid", type=int, default=100)
    p.add_argument("--slot", default="usb0")
    p.add_argument("--container", default="wiserain-tvheadend-1")
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--recover", action="store_true", help="interrupt viewing to reset/reconnect")
    mode.add_argument("--ensure", action="store_true", help="only recover if frontend missing (default)")
    p.add_argument("--power-cycle", nargs=2, metavar=("HUB", "PORT"),
                   help="explicit uhubctl cycle on verified independent port; requires --recover")
    args = p.parse_args()
    if os.geteuid() != 0:
        p.error("run as root on the PVE node")
    if not 100 <= args.vmid <= 999999999 or not re.fullmatch(r"usb(?:[0-9]|1[0-3])", args.slot):
        p.error("invalid VM ID or USB slot")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", args.container):
        p.error("invalid container name")
    if args.power_cycle and not args.recover:
        p.error("--power-cycle requires --recover")
    try:
        with open(f"/run/lock/onairgt-{args.vmid}-{args.slot}.lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            recover(args)
    except (OSError, ValueError, subprocess.SubprocessError, RecoveryError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
