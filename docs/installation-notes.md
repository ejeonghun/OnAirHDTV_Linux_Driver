# Installation notes (technical)

Reference for the scripts in `tools/`: `install.sh`, `uninstall.sh`,
`onairgt-doctor.sh`, `tvh-setup.py` and the presets in `tools/scan-tables/`.
Driver-only installation (packages, DKMS, make) is in the README.

## Quick start

```sh
git clone https://github.com/ejeonghun/OnAirHDTV_Linux_Driver.git
cd OnAirHDTV_Linux_Driver
sudo tools/install.sh             # interactive: asks TVHeadend method, preset, admin password
sudo tools/install.sh --yes       # non-interactive defaults (see below)
```

If the executable bit was lost (e.g. a ZIP download), run them with `sudo bash tools/install.sh`.

No `curl | sudo bash` one-liner is provided on purpose: the installer runs as
root, compiles a kernel module and changes system services, so users should
have the clone in front of them. A one-liner would only save the `git clone`.

## What `tools/install.sh` does

1. **Distro detection** (`/etc/os-release`, `ID` + `ID_LIKE`) → package manager
   `apt`, `dnf`, `pacman`, `zypper`, or `dnf-el` for RHEL clones.
2. **Build dependencies** for the running kernel (`uname -r`):

   | family | packages |
   |---|---|
   | Debian/Ubuntu/Mint/Raspberry Pi OS | `build-essential dkms linux-headers-$(uname -r)` (fallback `raspberrypi-kernel-headers`), `linux-modules-extra-$(uname -r)` if the DVB modules are missing (Ubuntu), `dvb-tools` (optional) |
   | Fedora | `gcc make dkms kernel-devel-$(uname -r) elfutils-libelf-devel`, `kernel-modules-extra-$(uname -r)` if needed, `v4l-utils` (optional) |
   | Arch/Manjaro/EndeavourOS | `base-devel dkms <kernel pkg>-headers` (kernel package found with `pacman -Qqo /usr/lib/modules/$(uname -r)/vmlinuz`, so `linux-lts`, `linux-zen` work), `v4l-utils` |
   | openSUSE | `gcc make kernel-devel kernel-<flavor>-devel`, `dkms` if available (otherwise falls back to `--no-dkms`) |
   | RHEL/Rocky/Alma/Oracle | checks first that the kernel has `dvb_core`, `dvb_usb_v2`, `lgdt330x`, `tuner_simple`. Stock EL kernels do not: the installer stops and points to ELRepo `kernel-ml`. With kernel-ml booted it continues like Fedora (dkms from EPEL). |

   After the packages, `modinfo -k $KVER` (or `modules.builtin`) must find
   `dvb_core dvb_usb_v2 lgdt330x tuner_simple`; otherwise it stops with the
   missing `CONFIG_*` names.
3. **Firmware** only with `--firmware FILE` (`tools/extract-firmware.sh`,
   SHA-256 checked; accepts `OnAirGt64.sys`, `OnAirGt.sys` or a raw 7168-byte
   image). Units that enumerate warm (EEPROM boot, like the test unit) do not need it.
4. **Driver via DKMS**: if the `onairgt-dkms` .deb/.rpm is installed, the
   driver build is skipped (the package owns the DKMS registration). Otherwise
   it removes old non-DKMS copies (`/lib/modules/*/{updates,extra}/dvb-usb-onairgt.ko*`)
   and every registered DKMS version, also under the pre-0.3 DKMS name
   `dvb-usb-onairgt`, then copies the driver files (`make dkms-src`) to a temp
   dir and runs `make dkms-install` there (copies them to `/usr/src/onairgt-<ver>`,
   `dkms add/build/install`; the build fetches the kernel-private headers via
   `kheaders.sh` into `/var/cache/onairgt/kheaders`). Skipped if
   `/usr/src/onairgt-<ver>` already matches the checkout and DKMS reports
   `installed` for the running kernel. The clone never gets root-owned files.
   `--no-dkms` uses `make install` instead (into `/lib/modules/$KVER/updates`,
   no rebuild on kernel updates).
5. **Load**: `modprobe dvb-usb-onairgt`. If an older build is loaded (different
   `srcversion`), it is reloaded, but only when TVHeadend has no viewer
   subscriptions (`/api/status/subscriptions`, entries other than
   `scan`/`epggrab`/`keep`); TVHeadend is stopped around the reload. If the
   device is plugged in, waits up to 20 s for `/dev/dvb/adapterN` whose sysfs
   parent is USB `11ba:1101`. Secure Boot: prints the `mokutil --import` command
   for the DKMS key if `modprobe` fails.
6. **TVHeadend** (optional), then **configuration through the JSON API**
   (`tools/tvh-setup.py`, Python 3 standard library only).

State is kept in `/etc/onairgt/install.conf` (method, port, preset); the admin
credentials in `/etc/onairgt/tvheadend.cred` (mode 0600, root). Re-running the
installer reuses them.

## Options

```
Driver:     --no-dkms  --skip-driver  --firmware FILE
TVHeadend:  --tvh auto|package|repo|docker|source|existing|none   (--no-tvh = none)
            --tvh-user USER (default admin)  --tvh-pass PASS (or env TVH_ADMIN_PASS)
            --tvh-port PORT (default 9981, HTSP = PORT+1)
            --docker-config DIR (default /var/lib/tvheadend-docker)
            --tvh-rebuild  --preset NAME  --no-scan  --scan-timeout SEC (1800)
            --map-encrypted  --list-presets
General:    -y/--yes  -h/--help
```

`--yes` defaults: TVHeadend `existing` if one is found (systemd unit
`tvheadend.service`, a `tvheadend` binary or a docker container named
`tvheadend`), else `auto`; preset `kr-cable-8vsb`; user `admin`; a random
16-character password, printed at the end and stored in the cred file.

`--tvh auto` picks: apt → distro package if `apt-cache policy tvheadend` has a
candidate, else the official repo if it has the release, else `source`;
other distros → `docker` if docker is installed, else `source`.

## TVHeadend install methods

| method | what it does | config dir |
|---|---|---|
| `package` | `apt-get install tvheadend` from the distro; debconf preseeded with the admin user/password (the package stores it as the tvheadend *superuser*) | `/var/lib/tvheadend` |
| `repo` | adds `deb [signed-by=/usr/share/keyrings/tvheadend-tvheadend-archive-keyring.gpg] https://dl.cloudsmith.io/public/tvheadend/tvheadend/deb/<ubuntu\|debian\|raspbian> <codename> main` (only if `dists/<codename>/Release` exists), then as `package`. Ubuntu 26.04 "resolute" is available (4.3-2897 on 2026-10-18). | `/var/lib/tvheadend` |
| `docker` | installs Docker if missing (`docker.io`/`moby-engine`/`docker`), runs `lscr.io/linuxserver/tvheadend:latest` as container `tvheadend`, `--network host`, `--device /dev/dvb:/dev/dvb`, `PUID=911`, `PGID=<host video gid>`, `RUN_OPTS=--http_port/--htsp_port`, volumes `<dir>/config:/config`, `<dir>/recordings:/recordings`, restart `unless-stopped` | `<dir>/config` |
| `source` | build deps, `git clone --depth 1` into `/usr/local/src/tvheadend`, `./configure --prefix=/usr/local ... --enable-dvbscan` (adds `--disable-libav` / `--disable-dvbcsa` when ffmpeg/libdvbcsa dev files are missing), `make install`; system user `hts` (+ group `video`); unit `/etc/systemd/system/tvheadend.service` marked "Managed by OnAirHDTV_Linux_Driver" | `/var/lib/tvheadend` |
| `existing` | configure only | detected |

The linuxserver image always starts `tvheadend -C -c /config`. `-C` only creates
the wide-open entry when no access entry exists, so it has no effect once the
installer has created the admin account and removed that entry.

Docker caveat: `--device /dev/dvb` is resolved when the container is created.
If the tuner is unplugged/replugged, `docker restart tvheadend`. If `/dev/dvb`
did not exist at creation time, re-running `tools/install.sh` re-creates the
container with the device (the config volume is kept).

## TVHeadend configuration (tvh-setup.py)

Getting admin access to the API, in this order:
1. saved credentials (`/etc/onairgt/tvheadend.cred`), 2. the requested
`--tvh-user/--tvh-pass`, 3. anonymous admin (fresh `-C` first-run install),
4. otherwise a **temporary superuser**: writes `<config>/superuser`
(`{"username": "onairgt-setup", "password": <random>}`, 0600, owner of the
config dir), restarts TVHeadend, configures, deletes the file (restoring a
pre-existing one) and restarts again. The config dir is taken from `-c` on the
running process, else the same order as tvheadend's `config_get_dir()`.

Credential check: Tvheadend answers API calls with the anonymous access entry's
rights and does not reject wrong credentials there, so `tvh-setup.py` primes the
digest challenge from `/login` (401 for anonymous, 403 for wrong credentials)
and verifies the login before trusting it. Digest MD5 and SHA-256 are supported.

Then:
1. Admin account: access entry (`admin`, web UI, all streaming and DVR rights,
   `change_rights`) and password entry; updated if they exist.
2. Lock-down: every access entry with username `*`/empty **and** admin rights is
   deleted (that is the wide-open entry `-C` creates); `api/wizard/cancel`.
   `-C/--firstrun` is removed from `/etc/systemd/system/tvheadend.service(.d)`
   and `/etc/default/tvheadend` if present.
3. Finds the OnAir GT adapter in `api/hardware/tree`: frontend `sysfs_device`
   resolved under `/sys` up to the USB device with `idVendor/idProduct =
   11ba/1101` (fallback: the only adapter named LGDT3303).
4. Network `dvb_network_atsc_t` named after the preset (`# name:` line),
   `skipinitscan=true`, `autodiscovery=0`, `idlescan=false`.
5. Muxes from the dvbv5 scan file (`mpegts/network/mux_create`, `ATSC-T`,
   `VSB/8`); existing ones within ±100 kHz are skipped.
6. Frontends: **ATSC-T enabled** and attached to the network; **ATSC-C disabled**.
   The LGDT3303 is exposed by TVHeadend as two frontends; with both enabled,
   scans fail with `type does not match 4 != 5`.
7. `mpegts/network/scan`, polls `mpegts/mux/grid` (`scan_state != 0` = pending)
   every 5 s until done or `--scan-timeout`.
8. Maps all unmapped, named, enabled services of that network
   (`service/mapper/save`; encrypted services skipped unless `--map-encrypted`)
   and waits for `service/mapper/status`.

Exit codes: 0 ok, 1 error, 2 authentication, 3 tuner not visible in TVHeadend.

## Frequency presets (`tools/scan-tables/`)

dvbv5 format (usable with `dvbv5-scan` too); the `# name:` comment is the
TVHeadend network name.

| preset | file | muxes | range | status |
|---|---|---|---|---|
| `kr-cable-8vsb` (= `us-cable-8vsb`) | `kr-cable-8vsb-std` | 133 | 57–855 MHz, CEA-542 STD centers incl. +12.5/+25 kHz offsets | verified (see below) |
| `kr-cable-8vsb-hrc` (= `us-cable-8vsb-hrc`) | `kr-cable-8vsb-hrc` | 125 | HRC | untested |
| `kr-cable-8vsb-irc` (= `us-cable-8vsb-irc`) | `kr-cable-8vsb-irc` | 125 | IRC | untested |
| `kr-atsc-terrestrial` | `kr-atsc-terrestrial` | 38 | UHF 14–51, 473–695 MHz | untested (no antenna) |
| `us-atsc-terrestrial` | `us-atsc-terrestrial` | 35 | VHF 2–13 + UHF 14–36 (post-2020 repack) | untested |

The tuner's range is 54–858 MHz (`dvb-fe-tool`), so the cable tables stop at 855 MHz.
A path to any other dvbv5 ATSC file also works as `--preset`.

## Module parameters

The installer does not set any. If needed, put them in
`/etc/modprobe.d/dvb-usb-onairgt.conf`:

| parameter | default | meaning |
|---|---|---|
| `xfer` | 0 | 0 = isochronous (alt 6, like Windows), 1 = bulk (alt 0). Both verified clean; try `options dvb-usb-onairgt xfer=1` on USB controllers/VMs with poor isochronous support. |
| `win_ts` | 1 | Windows LGDT3303 TS register setup. Must stay 1: with 0 the TS is corrupt on this board. |
| `clock_flip` | 0 | debug only |

## uninstall.sh

```
sudo tools/uninstall.sh [--purge-tvh] [--purge-data] [--keep-firmware] [-y]
```
Unloads the module (refuses while a viewer is streaming; stops TVHeadend around
the unload), `dkms remove` for every version (`onairgt` and the pre-0.3 name
`dvb-usb-onairgt`), deletes `/usr/src/onairgt-*`, `/usr/src/dvb-usb-onairgt-*`,
`/var/cache/onairgt`, non-DKMS copies and the firmware file. If the
`onairgt-dkms` package is installed, its files are left alone and the script
says to remove the package with apt/dnf. `--purge-tvh` removes TVHeadend only if
`install.sh` installed it (package + repo list + key, docker container, or the
source build and its unit); `--purge-data` also deletes its config/recordings.

## onairgt-doctor.sh

```
sudo tools/onairgt-doctor.sh [--freq MHZ] [--adapter N] [--no-tvh]
```
Read-only report for bug reports: distro/kernel/Secure Boot/headers, presence of
the kernel DVB modules, install state, USB device (bcdDevice, link speed,
MaxPower, bound driver), DKMS status and build errors, module srcversion and
parameters, old non-DKMS copies, firmware, filtered `dmesg`, `/dev/dvb`, which
processes hold the tuner, `dvb-fe-tool`, optional `dvbv5-zap -m` signal check
(skipped while the tuner is busy), TVHeadend service/container, reachability,
anonymous-admin check, frontends, networks, locked muxes, channels,
subscriptions and input stats. It never prints the password.

## Supported distributions

| distro | driver | TVHeadend methods | tested |
|---|---|---|---|
| Ubuntu 26.04 (kernel 7.0) | DKMS | repo, docker, source | driver (DKMS and --no-dkms) and docker verified end to end; source partial (channels unlinked by the restart race, fix not re-run); repo not run |
| Debian 12/13, Ubuntu 22.04/24.04, Mint 21/22 | DKMS | repo, docker, source (package where available) | not tested |
| Raspberry Pi OS (bookworm) | DKMS | repo, docker, source | not tested |
| Fedora | DKMS | docker, source | not tested |
| Arch / Manjaro / EndeavourOS | DKMS | docker, source | not tested |
| openSUSE Tumbleweed/Leap | DKMS or `--no-dkms` | docker, source | not tested (best effort) |
| RHEL/Rocky/Alma 8–10 | stock kernel: refused with ELRepo guidance | – | not tested |

## Troubleshooting

**Channels are listed but nothing plays** (channels have no services / are named
`{name-not-set}`). Seen on the source path: the restart that removes the
temporary setup account came before tvheadend had saved the service↔channel
links. tools/install.sh now waits 20 s before that restart. Repair an affected install
without restarting tvheadend:

```sh
sudo tools/install.sh --yes --tvh existing --preset kr-cable-8vsb   # use your preset
```

It uses the saved credentials, rescans (~12 min for the cable table), deletes
the channels without services and maps the services again.

Other cases: `--tvh existing --preset NAME` to switch presets; exit code 3 =
tvheadend does not see the tuner (run `tools/onairgt-doctor.sh`); exit code 2
= no admin access (pass `--tvh-user/--tvh-pass` of an existing admin).

## Test log

Ubuntu 26.04.1, kernel 7.0.0-38-generic, VMware VM with the OnAir GT passed
through, Korean cable 8VSB, preset `kr-cable-8vsb`, 2026-10-18. Only the Docker
path is verified end to end (install, scan, mapping, live stream). Details and
numbers are in [test-report.md](test-report.md) ("TVHeadend end-to-end").
These runs used version 0.2, when the scripts lived in `scripts/` and the DKMS
module was named `dvb-usb-onairgt`.

| test | result |
|---|---|
| `shellcheck -x` on all scripts (Ubuntu 26.04 package) | clean |
| `uninstall.sh --yes` (driver) | DKMS versions, `/usr/src` copies and firmware removed, module unloaded; TVHeadend stopped and restarted around the unload |
| `install.sh --yes --no-tvh --no-dkms` | pass |
| `install.sh --yes --no-tvh` (DKMS) and its re-run | pass; the re-run skips the build and the reload |
| `install.sh --yes --tvh docker` | pass: 224 services, 109 channels, 10 s KTV stream clean, anonymous API 401 (two bugs found and fixed: mapper polling, unexported credentials) |
| `uninstall.sh --yes --purge-tvh --purge-data` (docker) | container and `/var/lib/tvheadend-docker` removed, state cleared |
| `install.sh --yes --tvh source` | **partial**: build, persistent config, scan (226 services) and mapping (109 channels) worked, and a stream played before the final restart; after it the 109 channels were unlinked. Two bugs: (1) superuser bootstrap rejected by the `/login` check (fixed, re-tested); (2) the restart after the bootstrap lost the channel↔service links (fixed in the scripts, **not re-tested**) |
| `install.sh --tvh repo` | not run (Ubuntu 26.04 "resolute" exists in the cloudsmith repo) |
| `tvh-setup.py` against a throwaway `tvheadend -C` | admin created, `*` entry removed, wrong password rejected, idempotent re-run |
| Debian, Fedora, Arch, openSUSE, RHEL clones, Raspberry Pi | not tested |

Version 0.3 (`tools/`, DKMS name `onairgt`) was re-tested in an ubuntu:24.04
container against the 6.8.0-147-generic headers, with `modprobe`/`rmmod`
stubbed (no hardware, no TVHeadend):

| test | result |
|---|---|
| `install.sh --yes --no-tvh` and its re-run | `onairgt/0.3 ... installed`; the re-run prints `already installed` |
| same, with a stale `dvb-usb-onairgt/0.2` DKMS registration | the old registration is removed, `onairgt/0.3` installed |
| `uninstall.sh --yes` | no DKMS entry, no `/usr/src/onairgt-*`, no `/var/cache/onairgt` |
| `install.sh` / `uninstall.sh` with the `onairgt-dkms` .deb installed | install skips the build ("driver provided by the onairgt-dkms package"); uninstall warns and leaves the package |

Known gaps:
- the 20 s save delay before the post-bootstrap restart is an estimate;
- Docker was already installed when the docker path ran, so `ensure_docker`'s
  package install was not exercised;
- `--firmware` (cold units) is untested: the test unit boots warm from EEPROM.
