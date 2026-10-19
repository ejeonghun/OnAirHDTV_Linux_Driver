# dvb-usb-onairgt: driver internals

Code: [onairgt.c](../onairgt.c). Protocol: [protocol.md](protocol.md). Measured hardware
behaviour: [hardware.md](hardware.md).

## Structure
`onairgt.c` is a dvb-usb-v2 bridge driver (about 550 lines). Everything else is in-kernel:

| piece | provided by |
|---|---|
| USB probe/disconnect, firmware loading, URB streaming, demux, `/dev/dvb` nodes | `dvb_usb_v2` (`dvb_usbv2_probe` & co.) |
| LGDT3303 demodulator | `lgdt330x` via `dvb_attach(lgdt330x_attach, …)` |
| TDVS-H062F tuner | `tuner-simple` via `dvb_attach(simple_tuner_attach, …, TUNER_LG_TDVS_H06XF)` |

Callbacks implemented by the driver:

| callback | does |
|---|---|
| `identify_state` | **cold** if config bMaxPower == 0x32 (Windows rule), else **warm** |
| `download_firmware` | CPUCS=1, 512-byte 0xA0 writes, CPUCS=0 → `RECONNECTS_USB`. Not hardware-verified. |
| `power_ctrl(on)`, first time only | `usb_set_interface(0, 6 or 0)` + `usb_clear_halt` on EP 0x01/0x81, then `DE 00` and `0B` (high-speed check). Never powers off; see below. |
| `i2c_algo` | cxusb-style: `08 addr len data` → status; `09 wlen rlen addr wdata` → status + data. Write+read pairs become one combined transfer. Status 0x08 = ACK, anything else → `-EREMOTEIO`. |
| `frontend_attach` | `51` (digital mode; the firmware pulses the demod reset), then `lgdt330x_attach`. `set_ts_params` applies the Windows reg 0x87/0x47 tweak on 8VSB. |
| `tuner_attach` | `simple_tuner_attach(…, 0x61, TUNER_LG_TDVS_H06XF)` |
| `streaming_ctrl` | on: `38 03 00`, off: `37` |
| `get_stream_config` | `xfer=1` switches the default isochronous stream (EP 0x82, 8 URBs × 32 × 940 B) to bulk (8 × 16 KiB) |
| `exit` | after an unplug, sets `fe->exit = DVB_FE_DEVICE_REMOVED` so the frontend thread stops polling a dead device (same as em28xx/cx231xx) |

All commands go through `onairgt_ctrl_msg()` with one DMA-safe buffer in the private state, under
`d->usb_mutex`, using `dvb_usbv2_generic_rw_locked()`.

### Why the board is never powered off
`DE` (power on) runs the firmware's analog-mode GPIO sequence, which holds the demod in reset. `DC` cuts the
demod. In both cases the LGDT3303 loses its registers. `lgdt330x` caches the current modulation and would not
reprogram the 8VSB setup on the next tune. So the driver powers on once at probe and never sends `DC`. cxusb's
Bluebird devices make the same choice.

### Unplug handling
- **Before:** after a physical unplug, every frontend status poll (10 per second) logged
  `dvb_usb_v2: usb_bulk_msg() failed=-19` plus an `lgdt330x … error (ret == -19)` line. This lasted until
  the last user closed the adapter (about 7 s with dvbv5-scan running).
- **Now:** `onairgt_ctrl_msg()` returns `-ENODEV` without touching USB once `udev->state` is
  `USB_STATE_NOTATTACHED`, and the `exit` hook stops the frontend thread.

## Kernel compatibility (4.4 to 7.0)
The bridge uses a small, stable part of the API. Differences found by diffing the headers of every release
from v4.4.302 to v7.0 (git.kernel.org stable tags):

| item | change | handling |
|---|---|---|
| `lgdt330x_attach` | (cfg, i2c) with `cfg.demod_address` up to **4.17**; (cfg, addr, i2c) from **4.18** | `LINUX_VERSION_CODE` guard |
| `dvb_usb_device_properties.i2c_algo` | non-const pointer before **6.15**, const after | `onairgt_i2c_algo` is not const (valid either way) |
| `i2c_algorithm.master_xfer` | `.xfer` added in **6.11** as a union with `.master_xfer`; both still exist in 7.0 | uses `.master_xfer` |
| `dvb_usb.h` includes | `"dvb_frontend.h"` etc. from `drivers/media/dvb-core` before **4.16**, `<media/…>` after | `kheaders.sh` also fetches the dvb-core headers for < 4.16; in-tree builds add `-I…/dvb-core` |
| `struct dvb_usb_device_properties` | `probe`/`disconnect` added in **4.17** (layout change) | headers must match the kernel; see below |
| `struct dvb_usb_rc` | `rc_type` → `rc_proto` rename (4.14); `timeout` added in **5.5** (layout change of `dvb_usb_device`) | headers must match the kernel |
| `dvb_usbv2_generic_rw_locked`, `DVB_USB_STREAM_ISOC`, `DVB_USB_DEVICE`, `get_stream_config`, `exit` | unchanged 4.4-7.0 | none |

So `dvb_usb.h` has three structure-layout epochs: **4.4-4.16**, **4.17-5.4**, **5.5-7.0**. A module built with
another epoch's header would read the wrong fields of `struct dvb_usb_device`.

## Kernel-private headers
`dvb_usb.h`, `lgdt330x.h` and `tuner-simple.h` (and, before 4.16, the dvb-core headers) are not in distro
header packages. `kheaders.sh` resolves them for the target kernel:

1. **`KDIR` is a full source tree** (it has `drivers/media/usb/dvb-usb-v2/dvb_usb.h`): use that tree's own
   headers. This covers vanilla, in-tree and Synology builds.
2. **Find the upstream version.** `make kernelversion` in `KDIR` gives it. When building for the running
   Ubuntu kernel, the stable base in `/proc/version_signature` is preferred. Ubuntu 22.04+, Debian and Fedora
   carry the real `X.Y.Z` in their Makefile anyway: Ubuntu `6.8.0-147` → 6.8.12, `5.15.0-198` → 5.15.216;
   Debian `6.1.0-54` → 6.1.190.
3. **Cached copy** in `$KHEADERS_CACHE/<tag>/` (`./kheaders` for `make`, `/var/cache/onairgt/kheaders` for
   DKMS builds). It is used only if every file still matches the SHA-256 recorded in its `MANIFEST`.
4. **Download** `…/stable/linux.git/plain/<path>?h=vX.Y.Z`, falling back to `vX.Y`. Each file must download
   without error, must not be an HTML error page, and must contain an expected symbol. The tag, source URL and
   SHA-256 of every file are written to `MANIFEST`.
5. **Offline fallback:** `fallback-kheaders/` (Linux 7.0 copies, identical to Ubuntu 7.0.0-38). It is
   used with a loud warning, and only for kernels ≥ 5.5, the epoch whose layout matches 7.0. Older kernels
   fail with an error instead of risking memory corruption.

Distro kernels are upstream plus patches. Their `drivers/media` structures have matched upstream in every
case checked: the fetched v7.0.14 headers are byte-identical to the Ubuntu 7.0.0-38 source package. Still,
this check is per release, not a guarantee.

DKMS builds (`dkms.conf`) keep the cache in `/var/cache/onairgt/kheaders`, outside the per-build directory, so
a rebuild for a kernel whose headers were fetched before works offline. Builds for a new kernel version need
network access, or fall back as in step 5. Removing (deb: purging) the `onairgt-dkms` package deletes the cache.

## Build targets
The kbuild rules live in `Kbuild`. `Makefile` is only a wrapper, because DKMS passes
`KERNELRELEASE` on its make command line, which breaks the usual single-Makefile `ifneq ($(KERNELRELEASE),)` split.

| target | does |
|---|---|
| `make` | build for `KVER` (default `uname -r`) against `KDIR` (default `/lib/modules/KVER/build`) |
| `make install` / `uninstall` | `modules_install` into `updates/` / remove it; then `depmod` |
| `make dkms-install` / `dkms-remove` | copy the driver files to `/usr/src/onairgt-<PACKAGE_VERSION>`, `dkms add/build/install` / `dkms remove --all` and delete that copy |
| `make dkms-src DEST=dir` | copy only the files DKMS needs (used by the packages, the compile matrix and `tools/install.sh`) |
| `make clean` / `distclean` | build output / also the header cache |

## DKMS packages
`packaging/` builds `onairgt-dkms_<ver>_all.deb` (`build-deb.sh`, `dpkg-deb`) and
`onairgt-dkms-<ver>-1.noarch.rpm` (`build-rpm.sh`, `onairgt-dkms.spec`). The version is `PACKAGE_VERSION` from
`dkms.conf`; file times come from `SOURCE_DATE_EPOCH` (default: the last commit). Both packages install
`make dkms-src` output to `/usr/src/onairgt-<ver>`. The install script removes other registered `onairgt`
versions, runs `dkms add`, then `dkms install -k <kver>` for every `/lib/modules/<kver>/build` that has a
`Makefile`. A failed build prints the `make.log` path but does not fail the package installation. Removal runs
`dkms remove --all` and deletes `/var/cache/onairgt`. Dependencies: `dkms`, `curl` or `wget` (deb also
`ca-certificates`).

`packaging/smoke-test.sh <pkg>` installs a package with the distro's generic kernel headers inside a throwaway
container, checks `dkms status` and the installed `.ko` for each kernel, then removes the package and checks
that nothing is left. `.github/workflows/package.yml` runs both builds and smoke tests on tags `v*` (and on
manual dispatch), checks that the tag matches `dkms.conf`, and attaches the packages to the GitHub Release.

Results (2026-10-18, test VM, docker):

| container | kernel headers | dkms | result |
|---|---|---|---|
| ubuntu:24.04 | 6.8.0-147-generic (fetched v6.8.12) | 3.0.11 | installed to `updates/dkms/`, removal clean |
| fedora:latest (44), `kernel-core` + `kernel-devel` | 7.2.11-200.fc44 (fetched v7.2.11) | 3.4.4 | installed to `extra/` (`.ko.xz`), removal clean |

In the minimal Fedora container `dkms status` adds "(Differences between built and installed modules)":
dkms compares the two files with `diff`, which is not installed there (diffutils).

## Compile matrix
Command: `sh ci/matrix.sh`. Each target runs in a docker container and installs the distro's
generic kernel-headers package (or configures a kernel.org tree with `DVB_USB_V2=m`, `DVB_LGDT330X=m`,
`MEDIA_TUNER_SIMPLE=m` and runs `modules_prepare`). It then builds the module. A target fails on any build
error, a missing `.ko`, or any compiler warning in `onairgt.c`. CI runs the same matrix
(`.github/workflows/build.yml`).

Results (2026-10-18, run on the test VM):

| target | kernel | compiler | headers | result |
|---|---|---|---|---|
| ubuntu-18.04 (GA) | 4.15.0-213-generic | gcc 7 | fetched v4.15.18 (+ dvb-core) | PASS |
| ubuntu-18.04 (HWE) | 5.4.0-150-generic | gcc 7 | fetched v5.4.233 | PASS |
| ubuntu-20.04 | 5.4.0-216-generic | gcc 9 | fetched v5.4.291 | PASS |
| ubuntu-22.04 | 5.15.0-198-generic | gcc 11 | fetched v5.15.216 | PASS |
| ubuntu-24.04 | 6.8.0-147-generic | gcc-13 | fetched v6.8.12 | PASS |
| debian-11 (archive.debian.org) | 5.10.0-46-amd64 (5.10.262) | gcc-10 | fetched v5.10.262 | PASS |
| debian-12 | 6.1.0-54-amd64 (6.1.190) | gcc-12 | fetched v6.1.190 | PASS |
| debian-13 | 6.12.113+deb13-amd64 | gcc-14 | fetched v6.12.113 | PASS |
| fedora:latest (44) | 7.2.11-200.fc44 | gcc | fetched v7.2.11 | PASS |
| vanilla 4.4.302 (DSM 7.x "4.4" platforms) | 4.4.302 | gcc 7 | own tree | PASS |
| vanilla 5.10.55 (DSM 7.x "5.10" platforms) | 5.10.55 | gcc 9 | own tree | PASS |
| test VM: Ubuntu 26.04 | 7.0.0-38-generic | gcc 15 | fetched v7.0.14 | PASS, **loaded and tested on hardware** |

Only the 7.0 build has run on hardware. The others are compile tests: they show that the module builds and
links against each kernel's API and header layout. Loading them would also need the matching
`dvb_usb_v2`/`lgdt330x`/`tuner-simple` modules (`CONFIG_DVB_USB_V2`, `CONFIG_DVB_LGDT330X` and
`CONFIG_MEDIA_TUNER_SIMPLE` are `=m` in all the distro kernels above). Synology DSM kernels ship none of
them; `synology/` builds those modules from the GPL kernel source.
